/// Physical motor layout for this specific machine.
///
/// 6 rows × 6 columns = 36 motors, all 2-wire.
///
/// - Shelf labels (printed on the cabinet): 001..006, 011..016, ..., 051..056
/// - Protocol motor IDs (sent in 0x05 RUN): 99..94, 89..84, ..., 49..44
///
/// Top-left cell (row=1, col=1) → label "001" → motor 99
/// Bottom-right cell (row=6, col=6) → label "056" → motor 44
class MotorLayout {
  static const rows = 6;
  static const cols = 6;
  static const totalMotors = rows * cols;

  /// row: 1..6 (1=top), col: 1..6 (1=left) → motor id in [44..99]
  static int coordsToMotor(int row, int col) =>
      (10 - row) * 10 + (10 - col);

  /// motor id → (row 1..6, col 1..6)
  static (int, int) motorToCoords(int motorId) =>
      (10 - motorId ~/ 10, 10 - motorId % 10);

  /// shelf label "001"..."056" → motor id in [44..99]
  static int labelToMotor(String label) {
    final n = int.parse(label);
    return (9 - n ~/ 10) * 10 + (10 - n % 10);
  }

  /// motor id → shelf label "001"..."056"
  static String motorToLabel(int motorId) {
    final (row, col) = motorToCoords(motorId);
    final n = (row - 1) * 10 + col;
    return n.toString().padLeft(3, '0');
  }

  /// Iterate all valid motor IDs in display order (top-left → bottom-right).
  static Iterable<int> allMotors() sync* {
    for (var row = 1; row <= rows; row++) {
      for (var col = 1; col <= cols; col++) {
        yield coordsToMotor(row, col);
      }
    }
  }

  /// Motor IDs that live on a given shelf (1..6), top-to-bottom in the
  /// physical machine. Shelf 1 = labels 001..006 = motors 99..94, shelf 2
  /// = labels 011..016 = motors 89..84, and so on through shelf 6.
  static List<int> motorsForShelf(int shelf) {
    assert(shelf >= 1 && shelf <= rows, 'shelf out of 1..$rows range');
    return [for (var col = 1; col <= cols; col++) coordsToMotor(shelf, col)];
  }

  /// Human-readable label range for a shelf header, e.g. shelf 1 →
  /// "001 — 006". Mirrors the stickers on the cabinet door so customers
  /// can match an on-screen card to a physical slot.
  static String shelfLabelRange(int shelf) {
    final first = motorToLabel(motorsForShelf(shelf).first);
    final last = motorToLabel(motorsForShelf(shelf).last);
    return '$first — $last';
  }
}
