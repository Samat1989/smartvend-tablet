import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_error.dart';
import '../services/strings.dart';

/// The one way a failure is shown to a person.
///
/// Takes an [AppError] rather than a string so a screen physically cannot
/// paste an exception onto the display: the sentence comes from [Strings] by
/// way of [AppError.messageKey], and the technical detail stays in the log.
///
/// The icon carries the same meaning as the sentence — a struck-through Wi-Fi
/// glyph is read across the room, before anyone starts on the text.
class ErrorCard extends StatelessWidget {
  const ErrorCard({super.key, required AppError this.error, this.onRetry})
      : text = null;

  /// For a failure the app names itself — "no release carries an APK", "the
  /// installer stalled" — where there is no exception to classify. [text] must
  /// already be translated; pass `s.t(key)`, never a raw message.
  const ErrorCard.message({super.key, required String this.text, this.onRetry})
      : error = null;

  final AppError? error;
  final String? text;

  /// Shown only when retrying could plausibly help — see [AppError.retryable].
  /// Offering "Retry" on a rejected PIN would just waste the operator's time.
  final VoidCallback? onRetry;

  IconData get _icon => switch (error?.kind) {
        AppErrorKind.offline => Icons.wifi_off_rounded,
        AppErrorKind.timeout => Icons.schedule_rounded,
        AppErrorKind.server => Icons.cloud_off_rounded,
        AppErrorKind.denied => Icons.lock_outline_rounded,
        AppErrorKind.notFound => Icons.search_off_rounded,
        AppErrorKind.invalid => Icons.report_problem_outlined,
        AppErrorKind.unknown || null => Icons.error_outline_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final showRetry = onRetry != null && (error?.retryable ?? true);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFFDECEC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF5C6C6)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_icon, color: const Color(0xFFC0392B), size: 26),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text ?? s.t(error!.messageKey),
                  style: const TextStyle(
                    color: Color(0xFF8E2A20),
                    fontSize: 15,
                    height: 1.35,
                  ),
                ),
                if (showRetry) ...[
                  const SizedBox(height: 10),
                  TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(s.t('err_retry')),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFC0392B),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Same sentence, shown as a transient bar. For failures that interrupt an
/// action the operator started rather than something a screen is stuck on.
void showErrorSnack(BuildContext context, AppError error) {
  final s = context.read<Strings>();
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF8E2A20),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        content: Text(s.t(error.messageKey)),
      ),
    );
}
