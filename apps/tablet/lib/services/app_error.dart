import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// What went wrong, in terms a customer or an operator can act on.
///
/// Deliberately coarse. The screens only need to answer "whose problem is
/// this and what do I do now", and every extra branch is another sentence to
/// translate four times for no gain.
enum AppErrorKind {
  /// No route to the network at all — DNS failed, Wi-Fi is down, TLS could
  /// not be established. The operator can fix this.
  offline,

  /// The network is there but the far end did not answer in time.
  timeout,

  /// The far end answered with a failure of its own (5xx, malformed body).
  /// Nothing the operator can do but retry later.
  server,

  /// Rejected: the machine is not paired, the secret is wrong, or the row
  /// belongs to somebody else (401/403).
  denied,

  /// The thing asked for is not there (404).
  notFound,

  /// The request itself was refused as wrong (400/409/422) — usually input.
  invalid,

  /// Anything unclassified.
  unknown,
}

/// A failure on its way to the screen.
///
/// The point of this class is the split between [kind], which decides the
/// sentence a person reads, and [technical], which never leaves the log.
/// Before it existed the UI printed whatever it caught, and the update screen
/// showed customers lines like
///
///     ClientException with SocketException: Failed host lookup:
///     'cgvfhtvdtdjsyluhlcbq.supabase.co' (OS Error: No address associated
///     with hostname, errno = 7), uri=https://…/manifest.json?t=1782113541796
///
/// — which says "no Wi-Fi" in a way nobody can read, and hands out the
/// project's hostnames and internal paths while doing it.
@immutable
class AppError implements Exception {
  const AppError(this.kind, [this.technical]);

  final AppErrorKind kind;

  /// Raw detail for `debugPrint` and bug reports. NEVER render this.
  final String? technical;

  /// Classify a caught exception.
  factory AppError.from(Object e) {
    final t = e.toString();
    if (e is AppError) return e;
    if (e is TimeoutException) return AppError(AppErrorKind.timeout, t);
    if (e is SocketException) return AppError(AppErrorKind.offline, t);
    if (e is HandshakeException || e is TlsException) {
      return AppError(AppErrorKind.offline, t);
    }
    // http's ClientException wraps the socket failure instead of rethrowing
    // it, so the type test above misses the most common real-world case:
    // a tablet whose Wi-Fi dropped. Match on the message it carries.
    if (e is http.ClientException) {
      final lower = t.toLowerCase();
      final looksOffline = lower.contains('socketexception') ||
          lower.contains('failed host lookup') ||
          lower.contains('connection closed') ||
          lower.contains('connection refused') ||
          lower.contains('network is unreachable');
      return AppError(
          looksOffline ? AppErrorKind.offline : AppErrorKind.unknown, t);
    }
    if (e is FormatException) return AppError(AppErrorKind.server, t);
    if (e is HttpException) return AppError(AppErrorKind.server, t);
    return AppError(AppErrorKind.unknown, t);
  }

  /// Classify an HTTP response. [body] is kept for the log only.
  factory AppError.http(int status, [String body = '']) {
    final detail = 'HTTP $status: ${body.length > 300 ? body.substring(0, 300) : body}';
    if (status == 401 || status == 403) {
      return AppError(AppErrorKind.denied, detail);
    }
    if (status == 404) return AppError(AppErrorKind.notFound, detail);
    if (status == 408 || status == 429) {
      return AppError(AppErrorKind.timeout, detail);
    }
    if (status >= 500) return AppError(AppErrorKind.server, detail);
    if (status >= 400) return AppError(AppErrorKind.invalid, detail);
    return AppError(AppErrorKind.unknown, detail);
  }

  /// Key into [Strings] for the sentence shown to the user.
  String get messageKey => switch (kind) {
        AppErrorKind.offline => 'err_offline',
        AppErrorKind.timeout => 'err_timeout',
        AppErrorKind.server => 'err_server',
        AppErrorKind.denied => 'err_denied',
        AppErrorKind.notFound => 'err_not_found',
        AppErrorKind.invalid => 'err_invalid',
        AppErrorKind.unknown => 'err_unknown',
      };

  /// True when trying the same thing again could plausibly work.
  bool get retryable =>
      kind == AppErrorKind.offline ||
      kind == AppErrorKind.timeout ||
      kind == AppErrorKind.server ||
      kind == AppErrorKind.unknown;

  /// Send the detail where it belongs. [where] names the call site.
  void log(String where) => debugPrint('[$where] ${kind.name}: $technical');

  @override
  String toString() => 'AppError(${kind.name})';
}
