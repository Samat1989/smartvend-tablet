import 'dart:async';

import 'package:flutter/material.dart';

import '../services/idle_service.dart';

/// Сторож бездействия: пока экран открыт, раз в секунду смотрит на
/// [IdleService.lastTouchAt]. Если касаний не было [timeout], закрывает
/// весь стек до витрины (`popUntil(isFirst)`). Любое касание (его ловит
/// глобальный Listener в `main.dart`) сбрасывает отсчёт.
///
/// [builder] получает оставшееся время, чтобы при желании показать отсчёт.
class IdleReturnTimer extends StatefulWidget {
  const IdleReturnTimer({
    super.key,
    required this.builder,
    this.timeout = IdleService.returnToStorefrontAfter,
  });

  final Duration timeout;
  final Widget Function(BuildContext context, Duration remaining) builder;

  @override
  State<IdleReturnTimer> createState() => _IdleReturnTimerState();
}

class _IdleReturnTimerState extends State<IdleReturnTimer> {
  Timer? _tick;
  late Duration _remaining = widget.timeout;

  @override
  void initState() {
    super.initState();
    // Вход на экран — это тоже действие: отсчёт всегда с полного значения.
    IdleService.instance.touched();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _onTick() {
    if (!mounted) return;
    final idleFor = IdleService.instance.now().difference(IdleService.instance.lastTouchAt);
    final left = widget.timeout - idleFor;
    if (left <= Duration.zero) {
      _tick?.cancel();
      Navigator.of(context).popUntil((r) => r.isFirst);
      // Свежий отсчёт для таймеров витрины (скринсейвер, автопрокрутка).
      IdleService.instance.touched();
      return;
    }
    setState(() => _remaining = left);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _remaining);
}

/// `m:ss` для оставшегося времени.
String formatIdleRemaining(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final m = total ~/ 60;
  final sec = (total % 60).toString().padLeft(2, '0');
  return '$m:$sec';
}
