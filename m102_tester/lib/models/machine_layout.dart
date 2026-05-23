import 'dart:convert';

/// User-configurable physical layout of *this specific* machine.
///
/// The factory `MotorLayout` (6 × 6, motors 99..44) is fine for the
/// original kiosk but doesn't cover other M109E cabinets: they ship
/// with different shelf counts, different motor mappings, and some
/// slots are twin spirals (one product = two motors that must fire
/// together).
///
/// [MachineLayout] models all of that as data the operator edits in
/// service mode and we persist via [DeviceStorage]:
///
///   • [shelves] — ordered list, operator adds / removes them at will
///   • Each [Shelf] has its own list of [slots]
///   • Each [Slot] holds one or more `motor_id`s (1..100 channels on
///     the M102 board). One ID = normal spiral. Two+ = twin / wide
///     spiral — the dispense flow runs them sequentially and only
///     marks success if every motor reported OK.
///
/// Stored as JSON so future schema bumps stay easy.
class MachineLayout {
  MachineLayout({required this.shelves});

  /// Empty layout — caller decides whether to fall back to the
  /// hard-coded [MotorLayout] grid or prompt the operator to set one up.
  factory MachineLayout.empty() => MachineLayout(shelves: const []);

  final List<Shelf> shelves;

  bool get isEmpty => shelves.isEmpty;
  bool get isNotEmpty => shelves.isNotEmpty;

  /// All motor IDs currently mapped to some slot. Useful for the
  /// editor to grey out already-used motors in the picker.
  Set<int> get allUsedMotorIds => {
        for (final sh in shelves)
          for (final sl in sh.slots) ...sl.motorIds,
      };

  /// Find the slot a given motor id belongs to. Returns null if the
  /// motor isn't in the layout (e.g., product was assigned before the
  /// operator built the layout). Callers should fall back to a
  /// single-motor dispense in that case.
  Slot? slotForMotor(int motorId) {
    for (final sh in shelves) {
      for (final sl in sh.slots) {
        if (sl.motorIds.contains(motorId)) return sl;
      }
    }
    return null;
  }

  MachineLayout copyWith({List<Shelf>? shelves}) =>
      MachineLayout(shelves: shelves ?? this.shelves);

  Map<String, dynamic> toJson() => {
        'shelves': shelves.map((s) => s.toJson()).toList(),
      };

  static MachineLayout fromJson(Map<String, dynamic> j) => MachineLayout(
        shelves: (j['shelves'] as List)
            .map((s) => Shelf.fromJson(s as Map<String, dynamic>))
            .toList(),
      );

  String encode() => jsonEncode(toJson());

  static MachineLayout? decode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

class Shelf {
  Shelf({required this.label, required this.slots});

  /// Human label shown on the catalog header (e.g. "001 — 006", or
  /// "Напитки"). Operator decides what reads well on the cabinet.
  final String label;
  final List<Slot> slots;

  Shelf copyWith({String? label, List<Slot>? slots}) => Shelf(
        label: label ?? this.label,
        slots: slots ?? this.slots,
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        'slots': slots.map((s) => s.toJson()).toList(),
      };

  static Shelf fromJson(Map<String, dynamic> j) => Shelf(
        label: j['label'] as String,
        slots: (j['slots'] as List)
            .map((s) => Slot.fromJson(s as Map<String, dynamic>))
            .toList(),
      );
}

class Slot {
  Slot({required this.label, required this.motorIds});

  /// Label printed on the cabinet door (e.g. "001"). Used both in the
  /// customer catalog and in inventory mapping. Doesn't have to be
  /// unique globally — only readable to customers.
  final String label;

  /// One or more motor IDs (0..99) that the M102 board must run to
  /// dispense whatever's in this slot. One ID = normal single
  /// spiral. Multiple = twin / linked spirals that must all fire.
  final List<int> motorIds;

  bool get isTwin => motorIds.length > 1;
  int get primaryMotorId => motorIds.first;

  Slot copyWith({String? label, List<int>? motorIds}) => Slot(
        label: label ?? this.label,
        motorIds: motorIds ?? this.motorIds,
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        'motorIds': motorIds,
      };

  static Slot fromJson(Map<String, dynamic> j) => Slot(
        label: j['label'] as String,
        motorIds:
            (j['motorIds'] as List).map((e) => (e as num).toInt()).toList(),
      );
}
