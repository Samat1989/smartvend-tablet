import 'dart:async';

import 'package:flutter/foundation.dart';

import '../board/board_client.dart';
import '../models/climate_config.dart';
import 'device_storage.dart';

enum CompressorPhase {
  idle,         // climate off, or in-band (between hysteresis bounds)
  warmingFan,   // fan is on, counting ticks until compressor allowed
  cooling,      // compressor energised
  resting,      // forced rest after long continuous work
  noProbe,      // temperature sensor missing
}

/// Climate / cooling / heating control loop.
///
/// Algorithm copied from the factory app (`shouhj/app/C0101App.java`,
/// `M102_StartRefrigeration` / `M102_StartHeating` / `M102_finish` and
/// `mserialport/eptonADH/ParseM102.operate()`):
///
/// Cooling cycle, evaluated each 10 s temperature tick:
///   • temp ≥ setpoint + 4 °C  → start cycle
///   • temp ≤ setpoint          → stop cycle (turn everything off)
///   • else                     → keep current state
///
/// `_StartRefrigeration` is then re-entrant per tick:
///   1. If heater module is on → turn off
///   2. If fan is off → turn fan on and bail (next tick continues)
///   3. While compressor is OFF, increment a tick counter
///   4. Once counter > 30 (≈ 5 minutes of fan running), energize compressor
///      AND glass heater (unless humidity loop owns the glass heater)
///
/// Heating mirrors this with a 12-tick (≈ 2 minute) heater spin-up.
///
/// Extra safety **on top of** the factory: after 60 minutes of continuous
/// compressor work (e.g. door left open / setpoint unreachable), force a
/// 5-minute rest. The factory has this code path declared but never
/// triggers it — we activate it because it's the right thing to do.
class ClimateController extends ChangeNotifier {
  ClimateController(this.board, this._storage) {
    // Rehydrate the last-known config so operator-set mode/setpoint
    // survive reboots. Falls back to the model defaults when the
    // operator has never opened the climate screen.
    final mode = _modeFromName(_storage.climateModeName);
    _config = ClimateConfig(
      mode: mode,
      setpointC: _storage.climateSetpoint,
      lightAlwaysOn: _storage.climateLightAlwaysOn,
    );
  }

  final BoardClient board;
  final DeviceStorage _storage;

  static ClimateMode _modeFromName(String? name) {
    if (name == null) return const ClimateConfig().mode;
    for (final m in ClimateMode.values) {
      if (m.name == name) return m;
    }
    return const ClimateConfig().mode;
  }

  // ---- factory-derived constants (do not expose in UI) ----
  static const double _hysteresisC = 4.0;
  /// Cold-start fan warmup before the **first** compressor run after
  /// app boot. Lets the condenser equalize and gives the compressor
  /// relay a slow start — protects the relay from inrush spikes when
  /// the unit has been off for hours.
  static const int _coolingSpinupTicksFirst = 30; // 5 min at 10 s tick
  /// In-session fan warmup between every subsequent compressor cycle.
  /// Compressor + refrigerant are already warm; 2 min is enough for
  /// pressure equalization. Matches the factory app's behavior on
  /// re-starts within the same session.
  static const int _coolingSpinupTicksWarm = 12; // 2 min at 10 s tick
  static const int _heatingSpinupTicks = 12;     // 2 min at 10 s tick
  static const int _tempPollSec = 10;
  static const int _humidityPollSec = 30;

  /// True once the compressor has been energised at least once since
  /// app boot. Used to pick the right fan-warmup duration:
  /// first cold start → 5 min, all subsequent cycles → 2 min.
  /// Resets implicitly on every fresh process start; not persisted
  /// to DeviceStorage because power-cycling the cabinet is also a
  /// good moment to do the long warmup again.
  bool _compressorHasRunThisSession = false;

  // ---- our extra safety: forced rest ----
  static const int _maxContinuousMin = 60;
  static const int _forcedRestMin = 5;
  static const int _humidityThresholdPercent = 60;

  // ---- live readings ----
  double? _temperatureC;
  int? _humidityPercent;
  double? get temperatureC => _temperatureC;
  int? get humidityPercent => _humidityPercent;
  bool get hasHumiditySensor => _humidityPercent != null;

  // ---- output state mirrors ----
  bool _fanOn = false;
  bool _compressorOn = false;
  bool _glassHeaterOn = false;
  bool _ledOn = false;
  bool _heaterModuleOn = false;
  bool get fanOn => _fanOn;
  bool get compressorOn => _compressorOn;
  bool get glassHeaterOn => _glassHeaterOn;
  bool get ledOn => _ledOn;
  bool get heaterModuleOn => _heaterModuleOn;

  // ---- algorithm state ----
  late ClimateConfig _config;
  ClimateConfig get config => _config;

  CompressorPhase _phase = CompressorPhase.idle;
  CompressorPhase get phase => _phase;
  int _spinupTicks = 0;
  DateTime? _compressorStartedAt;
  DateTime? _restStartedAt;

  String _statusMessage = 'Ожидание';
  String get statusMessage => _statusMessage;

  Timer? _tempTimer;
  Timer? _humidityTimer;

  bool _started = false;
  bool get isRunning => _started;

  // -------------------------------------------------------------- public API

  void updateConfig(ClimateConfig next) {
    final modeChanged = _config.mode != next.mode;
    // Clamp setpoint to the active mode's allowed range so a flip
    // from cooling (-5..18 °C) to heating (15..35 °C), or vice
    // versa, can never leave a value outside the slider's bounds
    // (the UI Slider asserts on out-of-range value and crashes the
    // climate screen). Same ranges as climate_screen.dart's slider.
    final clamped = next.copyWith(
      setpointC: _clampSetpoint(next.mode, next.setpointC),
    );
    _config = clamped;
    // Persist without awaiting — SharedPreferences writes return quickly
    // and the controller mustn't block on disk before responding.
    _storage.setClimateConfig(
      modeName: clamped.mode.name,
      setpointC: clamped.setpointC,
      lightAlwaysOn: clamped.lightAlwaysOn,
    );
    notifyListeners();
    if (modeChanged) {
      // Reset the spin-up counter when the user flips the mode so the next
      // start gets the full 5-min protection.
      _spinupTicks = 0;
      _compressorStartedAt = null;
      _restStartedAt = null;
      _phase = CompressorPhase.idle;
    }
    _evaluate();
  }

  /// Per-mode setpoint window (must match the Slider in
  /// climate_screen.dart). Cooling: -5..18 °C, heating: 15..35 °C,
  /// off: any (we still clamp into the cooling window so a later
  /// flip to heating doesn't surprise the UI).
  static double _clampSetpoint(ClimateMode mode, double v) {
    switch (mode) {
      case ClimateMode.heating:
        return v.clamp(15.0, 35.0);
      case ClimateMode.cooling:
      case ClimateMode.off:
        return v.clamp(-5.0, 18.0);
    }
  }

  /// Start the climate loop — auto-called on app launch.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _scheduleTimers();
    notifyListeners();
    await _evaluate();
  }

  Future<void> stop() async {
    _started = false;
    _cancelTimers();
    await _allOff();
    _setPhase(CompressorPhase.idle);
    _setMessage('Климат-контроль остановлен');
    notifyListeners();
  }

  // ------------------------------------------------------------ scheduling

  void _scheduleTimers() {
    _tempTimer = Timer.periodic(Duration(seconds: _tempPollSec), (_) async {
      if (!_started) return;
      if (board.isConnected) {
        _temperatureC = await board.readTemp();
      }
      await _evaluate();
      notifyListeners();
    });
    _humidityTimer = Timer.periodic(Duration(seconds: _humidityPollSec), (_) async {
      if (!_started) return;
      if (board.isConnected) {
        _humidityPercent = await board.readHumidity();
      }
      await _runHumidityLoop();
      notifyListeners();
    });
  }

  void _cancelTimers() {
    _tempTimer?.cancel();
    _humidityTimer?.cancel();
    _tempTimer = null;
    _humidityTimer = null;
  }

  // ----------------------------------------------------------- main logic

  Future<void> _evaluate() async {
    await _applyLight();

    if (!board.isConnected) {
      _setMessage('Нет связи с платой');
      return;
    }

    if (_config.mode == ClimateMode.off) {
      await _allClimateOff();
      _setPhase(CompressorPhase.idle);
      _setMessage('Климат отключён');
      return;
    }

    if (_temperatureC == null) {
      // No probe → safety: turn cooling/heating off, fan off too.
      await _allClimateOff();
      _setPhase(CompressorPhase.noProbe);
      _setMessage('Нет данных от датчика температуры');
      return;
    }

    final temp = _temperatureC!;
    final setpoint = _config.setpointC;

    if (_config.mode == ClimateMode.cooling) {
      await _coolingTick(temp, setpoint);
    } else {
      await _heatingTick(temp, setpoint);
    }
  }

  Future<void> _coolingTick(double temp, double setpoint) async {
    // Forced-rest check (our extra safety on top of factory).
    if (_phase == CompressorPhase.resting) {
      final restElapsed =
          DateTime.now().difference(_restStartedAt!).inMinutes;
      if (restElapsed < _forcedRestMin) {
        await _allClimateOff();
        _setMessage('Принудительный отдых: ещё '
            '${_forcedRestMin - restElapsed} мин');
        return;
      }
      // Rest complete — re-arm.
      _setPhase(CompressorPhase.idle);
      _spinupTicks = 0;
      _compressorStartedAt = null;
      _restStartedAt = null;
    }

    final tooHot = temp >= setpoint + _hysteresisC;
    final coolEnough = temp <= setpoint;

    // Decide whether the cycle should be active.
    if (coolEnough) {
      // Stop everything per factory M102_finish.
      await _allClimateOff();
      _setPhase(CompressorPhase.idle);
      _setMessage('В норме: ${temp.toStringAsFixed(1)}°C '
          '(уставка ${setpoint.toStringAsFixed(1)}°C)');
      _spinupTicks = 0;
      _compressorStartedAt = null;
      return;
    }

    if (!tooHot && _phase == CompressorPhase.idle) {
      // Inside hysteresis band, no cycle running — do nothing.
      _setMessage('В пределах гистерезиса: ${temp.toStringAsFixed(1)}°C');
      return;
    }

    // We need cooling. Run the factory M102_StartRefrigeration sequence.
    if (_heaterModuleOn) {
      await _setDo(DoChannel.heaterModule, false);
    }

    if (!_fanOn) {
      // Step 1: fan first.
      await _setDo(DoChannel.fan, true);
      _setPhase(CompressorPhase.warmingFan);
      _setMessage('Запуск охлаждения: вентилятор включён');
      return;
    }

    // Compressor branch. Use 5 min spin-up only on the very first
    // start of the session (cold compressor + condenser); 2 min on
    // every subsequent cycle. Mirrors the factory app.
    final spinupTarget = _compressorHasRunThisSession
        ? _coolingSpinupTicksWarm
        : _coolingSpinupTicksFirst;
    if (!_compressorOn) {
      _spinupTicks++;
      if (_spinupTicks > spinupTarget) {
        await _setDo(DoChannel.compressor, true);
        _compressorHasRunThisSession = true;
        // Glass heater follows compressor unless humidity loop owns it.
        if (!hasHumiditySensor) {
          await _setDo(DoChannel.glassHeater, true);
        }
        _compressorStartedAt = DateTime.now();
        _setPhase(CompressorPhase.cooling);
        _setMessage('Охлаждение: ${temp.toStringAsFixed(1)}°C → '
            '${setpoint.toStringAsFixed(1)}°C');
      } else {
        final ticksLeft = spinupTarget - _spinupTicks;
        final secLeft = ticksLeft * _tempPollSec;
        _setPhase(CompressorPhase.warmingFan);
        _setMessage('Прогрев вентилятора: ещё $secLeft с');
      }
    } else {
      // Compressor already running — check forced-rest threshold.
      final workedMin =
          DateTime.now().difference(_compressorStartedAt!).inMinutes;
      if (workedMin >= _maxContinuousMin) {
        await _allClimateOff();
        _restStartedAt = DateTime.now();
        _setPhase(CompressorPhase.resting);
        _setMessage('Компрессор работал $workedMin мин — '
            'принудительный отдых $_forcedRestMin мин');
      } else {
        _setMessage('Охлаждение: ${temp.toStringAsFixed(1)}°C → '
            '${setpoint.toStringAsFixed(1)}°C');
      }
    }
  }

  Future<void> _heatingTick(double temp, double setpoint) async {
    final tooCold = temp <= setpoint - _hysteresisC;
    final warmEnough = temp >= setpoint;

    if (warmEnough) {
      await _allClimateOff();
      _setPhase(CompressorPhase.idle);
      _setMessage('Нагрев: норма ${temp.toStringAsFixed(1)}°C');
      _spinupTicks = 0;
      return;
    }

    if (!tooCold && _phase == CompressorPhase.idle) {
      _setMessage('В пределах гистерезиса: ${temp.toStringAsFixed(1)}°C');
      return;
    }

    // Factory M102_StartHeating: compressor off, fan on, then heater module.
    if (_compressorOn) {
      await _setDo(DoChannel.compressor, false);
      if (!hasHumiditySensor) await _setDo(DoChannel.glassHeater, false);
    }

    if (!_fanOn) {
      await _setDo(DoChannel.fan, true);
      _setMessage('Запуск нагрева: вентилятор включён');
      return;
    }

    if (!_heaterModuleOn) {
      _spinupTicks++;
      if (_spinupTicks > _heatingSpinupTicks) {
        await _setDo(DoChannel.heaterModule, true);
        _setMessage('Нагрев: ${temp.toStringAsFixed(1)}°C → '
            '${setpoint.toStringAsFixed(1)}°C');
      } else {
        final ticksLeft = _heatingSpinupTicks - _spinupTicks;
        _setMessage('Прогрев перед нагревателем: '
            'ещё ${ticksLeft * _tempPollSec} с');
      }
    } else {
      _setMessage('Нагрев: ${temp.toStringAsFixed(1)}°C → '
          '${setpoint.toStringAsFixed(1)}°C');
    }
  }

  Future<void> _runHumidityLoop() async {
    if (!board.isConnected) return;
    if (!hasHumiditySensor) {
      // No sensor → glass heater is owned by the cooling cycle.
      return;
    }
    final shouldBeOn = _humidityPercent! >= _humidityThresholdPercent;
    if (_glassHeaterOn != shouldBeOn) {
      await _setDo(DoChannel.glassHeater, shouldBeOn);
    }
  }

  Future<void> _applyLight() async {
    if (!board.isConnected) return;
    if (_ledOn != _config.lightAlwaysOn) {
      await _setDo(DoChannel.lightStrip, _config.lightAlwaysOn);
    }
  }

  // -------------------------------------------------------- DO helpers

  Future<void> _setDo(DoChannel ch, bool on) async {
    final ok = await board.writeDo(ch.id, on);
    if (!ok) return;
    switch (ch) {
      case DoChannel.fan:
        _fanOn = on;
        break;
      case DoChannel.compressor:
        _compressorOn = on;
        break;
      case DoChannel.glassHeater:
        _glassHeaterOn = on;
        break;
      case DoChannel.lightStrip:
        _ledOn = on;
        break;
      case DoChannel.heaterModule:
        _heaterModuleOn = on;
        break;
    }
  }

  /// Climate-only off (light untouched).
  Future<void> _allClimateOff() async {
    if (!board.isConnected) return;
    if (_compressorOn) await _setDo(DoChannel.compressor, false);
    if (_glassHeaterOn && !hasHumiditySensor) {
      await _setDo(DoChannel.glassHeater, false);
    }
    if (_heaterModuleOn) await _setDo(DoChannel.heaterModule, false);
    if (_fanOn) await _setDo(DoChannel.fan, false);
  }

  /// Total off (everything including light).
  Future<void> _allOff() async {
    await _allClimateOff();
    if (_ledOn) await _setDo(DoChannel.lightStrip, false);
  }

  void _setPhase(CompressorPhase next) {
    if (_phase == next) return;
    _phase = next;
  }

  void _setMessage(String s) {
    if (_statusMessage != s) _statusMessage = s;
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }
}
