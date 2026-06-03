import 'product.dart';

class CartItem {
  final Product product;
  int quantity;

  CartItem({required this.product, this.quantity = 1});

  int get totalTenge => product.priceTenge * quantity;
}

/// Binary outcome of a dispense step.
///
/// * [ok] — board reported result=0 and (if curtain enabled) drop sensor
///   triggered. Customer got the product.
/// * [failed] — anything else: board reported non-zero result, no ack at
///   all, hard timeout, board went offline mid-cart. All these collapse
///   to "refund the customer" because there's nobody at the machine to
///   physically check the bin — autonomous operation has to bias toward
///   the customer when in doubt. We'd rather occasionally pay out for a
///   product that was actually delivered than leave a paying customer
///   empty-handed.
enum DispenseOutcome { ok, failed }

class DispenseStepResult {
  final Product product;
  final DispenseOutcome outcome;

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
    required this.outcome,
    required this.message,
    this.resultCode,
  });

  /// Legacy boolean shim — many call sites only care "did the customer
  /// get the product?" and don't need to enumerate the outcome enum.
  bool get success => outcome == DispenseOutcome.ok;
}
