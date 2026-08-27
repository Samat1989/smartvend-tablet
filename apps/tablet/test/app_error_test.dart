import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:micromart/services/app_error.dart';

void main() {
  group('AppError.http', () {
    test('403 from the claim guard reads as occupied, not denied', () {
      // The regression this file exists for. _assert_machine raises errcode
      // 42501 when a second tablet tries to take a machine another one holds,
      // and PostgREST renders that as a plain 403 — the same status as a
      // wrong secret. Classified by status alone the installer was told
      // "нет доступа, проверьте подключение" while the true answer was
      // "this cabinet is already in use".
      const body = '{"code":"42501","message":'
          '"machine 5 is claimed by another tablet"}';
      expect(AppError.http(403, body).kind, AppErrorKind.occupied);
      expect(AppError.http(403, body).messageKey, 'err_occupied');
    });

    test('a plain 403 is still denied', () {
      const body = '{"code":"28P01","message":"bad secret"}';
      expect(AppError.http(403, body).kind, AppErrorKind.denied);
    });

    test('statuses map to their kinds', () {
      expect(AppError.http(401).kind, AppErrorKind.denied);
      expect(AppError.http(404).kind, AppErrorKind.notFound);
      expect(AppError.http(429).kind, AppErrorKind.timeout);
      expect(AppError.http(422).kind, AppErrorKind.invalid);
      expect(AppError.http(500).kind, AppErrorKind.server);
      expect(AppError.http(503).kind, AppErrorKind.server);
    });

    test('the response body never reaches the message, only the log', () {
      final e = AppError.http(500, 'internal detail nobody should read');
      expect(e.messageKey, 'err_server');
      expect(e.technical, contains('internal detail'));
    });
  });

  group('AppError.from', () {
    test('a dropped connection reads as offline', () {
      expect(AppError.from(const SocketException('Failed host lookup')).kind,
          AppErrorKind.offline);
    });

    test('http wraps socket failures in ClientException — still offline', () {
      // The common real-world case on these tablets: Wi-Fi drops mid-request.
      // package:http does not rethrow the SocketException, so a type test
      // alone misses it.
      final e = http.ClientException(
          "ClientException with SocketException: Failed host lookup: "
          "'example.supabase.co', uri=https://example.supabase.co/x");
      expect(AppError.from(e).kind, AppErrorKind.offline);
    });

    test('a slow far end reads as timeout', () {
      expect(AppError.from(TimeoutException('x')).kind, AppErrorKind.timeout);
    });

    test('a malformed body reads as a server fault', () {
      expect(AppError.from(const FormatException('bad json')).kind,
          AppErrorKind.server);
    });

    test('an AppError passes through unchanged', () {
      const original = AppError(AppErrorKind.occupied, 'detail');
      expect(identical(AppError.from(original), original), isTrue);
    });

    test('retryable is true only where retrying could help', () {
      expect(const AppError(AppErrorKind.offline).retryable, isTrue);
      expect(const AppError(AppErrorKind.server).retryable, isTrue);
      expect(const AppError(AppErrorKind.occupied).retryable, isFalse);
      expect(const AppError(AppErrorKind.denied).retryable, isFalse);
    });
  });
}
