import 'product.dart';

class CartItem {
  final Product product;
  int quantity;

  CartItem({required this.product, this.quantity = 1});

  int get totalTenge => product.priceTenge * quantity;
}

class DispenseStepResult {
  final Product product;
  final bool success;

  /// Free-form fallback message (factory-derived English/Russian text from
  /// [BoardClient.dispense]). Used when [resultCode] is null — i.e. the
  /// failure happened *before* the M102 returned a poll result (e.g. RUN
  /// rejected by the board, or no port at all).
  final String message;

  /// Raw M102 result byte from the final POLL response when the motor
  /// reached state=Done. Null for transport-level failures. UI prefers
  /// this over [message] so the label can be localized via
  /// `Strings.pollResult(code)`.
  final int? resultCode;

  DispenseStepResult({
    required this.product,
    required this.success,
    required this.message,
    this.resultCode,
  });
}
