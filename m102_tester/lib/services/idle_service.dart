/// App-wide "when did the customer last touch the screen?" tracker.
///
/// Was tied to [HomeScreen]'s own Listener, which only saw events on
/// the catalog. The moment the customer pushed the cart or payment
/// screen, the home screen stopped receiving pointer events and its
/// idle counter raced ahead even though the customer was actively
/// using the kiosk. With this singleton, a single Listener in
/// `MaterialApp.builder` records every touch app-wide and any screen
/// can read [lastTouchAt] for its own idle logic.
class IdleService {
  IdleService._();
  static final IdleService instance = IdleService._();

  DateTime lastTouchAt = DateTime.now();

  /// Bump the timestamp. Called from the top-level Listener on every
  /// `onPointerDown` / `onPointerMove` so any flick or tap counts as
  /// activity regardless of which screen handled it.
  void touched() => lastTouchAt = DateTime.now();
}
