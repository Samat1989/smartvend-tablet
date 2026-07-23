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

/// Pre-baked starter layouts the operator can pick in the editor as a
/// one-tap reset. After applying, every label and motor mapping is
/// still freely editable per slot — the template only seeds the grid.
class LayoutTemplate {
  const LayoutTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.builder,
  });

  final String id;
  final String name;
  final String description;
  final MachineLayout Function() builder;

  MachineLayout build() => builder();

  /// Original kiosk wiring: 6 shelves × 6 slots, motor ids 99..44
  /// (top-left to bottom-right). Door labels follow the factory's
  /// row*10+col scheme (001..006, 011..016, ..., 051..056) — *not*
  /// a contiguous 1..36. Documented in `/c/m109e/docs/04_MOTOR_LAYOUT.md`.
  static const LayoutTemplate factory6x6 = LayoutTemplate(
    id: 'factory_6x6',
    name: 'Заводская 6×6',
    description: '6 полок × 6 слотов, моторы 99..44, ярлыки 001..006 / 011..016 / … / 051..056',
    builder: _buildFactory6x6,
  );

  /// MP2404 board kiosk: 1 short top shelf with 5 twin-spiral slots
  /// (motors 99..95) followed by 5 regular shelves of 10 slots each
  /// (motors 89..40, ярлыки 11..60).
  static const LayoutTemplate mp2404_5_50 = LayoutTemplate(
    id: 'mp2404_5_50',
    name: 'MP2404 (5 + 5×10)',
    description: '1×5 сдвоенных слотов сверху + 5×10 обычных снизу',
    builder: _buildMp2404,
  );

  /// BarysVend V27.2 (LiYuTai): dispense is addressed by (ряд, колонка),
  /// stored as motor id = ряд×100 + колонка (canonical encoding, см.
  /// BoardClient.lytRowColFromMotorId). 6 rows × 10 columns; the door
  /// label keeps the usual ряд×10+колонка numbering (11..70) the
  /// cabinets are stickered with. Trim extra slots/shelves after
  /// applying if the machine is narrower.
  static const LayoutTemplate barysvend6x10 = LayoutTemplate(
    id: 'barysvend_6x10',
    name: 'BarysVend V27.2 (6×10)',
    description: '6 рядов × 10 колонок, позиции ряд·колонка, двери 11..70',
    builder: _buildBarysvend6x10,
  );

  static const List<LayoutTemplate> all = [factory6x6, mp2404_5_50, barysvend6x10];
}

MachineLayout _buildFactory6x6() {
  // Door labels follow row*10+col, not 1..36 dense numbering.
  // Row 1 → 001..006, row 2 → 011..016, …, row 6 → 051..056.
  // Motor ids run 99..44 (top-left to bottom-right) with the
  // decade per row matching the row index. Full mapping in
  // `/c/m109e/docs/04_MOTOR_LAYOUT.md`.
  final shelves = <Shelf>[];
  for (var s = 1; s <= 6; s++) {
    final slots = <Slot>[];
    for (var j = 1; j <= 6; j++) {
      final motor = (10 - s) * 10 + (10 - j);
      final num = (s - 1) * 10 + j;
      slots.add(Slot(
        label: num.toString().padLeft(3, '0'),
        motorIds: [motor],
      ));
    }
    final first = (s - 1) * 10 + 1;
    final last = (s - 1) * 10 + 6;
    shelves.add(Shelf(
      label: '${first.toString().padLeft(3, '0')} — '
          '${last.toString().padLeft(3, '0')}',
      slots: slots,
    ));
  }
  return MachineLayout(shelves: shelves);
}

MachineLayout _buildMp2404() {
  final shelves = <Shelf>[];

  // Top shelf: 5 twin-spiral slots. Each "logical" slot drives one
  // double spiral; on this cabinet the operator wires the pair into a
  // single channel so we seed it as a single-motor slot. Easy to flip
  // to TWIN later via the slot picker.
  final topSlots = <Slot>[
    for (var j = 1; j <= 5; j++)
      Slot(
        label: j.toString().padLeft(2, '0'),
        motorIds: [100 - j],
      ),
  ];
  shelves.add(Shelf(label: '01 — 05', slots: topSlots));

  // Shelves 2..6 — 10 slots each, decade-per-shelf.
  for (var s = 2; s <= 6; s++) {
    final slots = <Slot>[
      for (var j = 1; j <= 10; j++)
        Slot(
          label: ((s - 1) * 10 + j).toString(),
          motorIds: [(11 - s) * 10 - j],
        ),
    ];
    final first = (s - 1) * 10 + 1;
    final last = s * 10;
    shelves.add(Shelf(label: '$first — $last', slots: slots));
  }

  return MachineLayout(shelves: shelves);
}

MachineLayout _buildBarysvend6x10() {
  // Row r (1..6) × column c (1..10); the position is stored as
  // id = r*100 + c and decoded back by BoardClient.lytRowColFromMotorId.
  // Door labels keep the familiar r*10+c numbering (11..70).
  final shelves = <Shelf>[
    for (var r = 1; r <= 6; r++)
      Shelf(
        label: '${r * 10 + 1} — ${r * 10 + 10}',
        slots: [
          for (var c = 1; c <= 10; c++)
            Slot(
              label: '${r * 10 + c}',
              motorIds: [r * 100 + c],
            ),
        ],
      ),
  ];
  return MachineLayout(shelves: shelves);
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
