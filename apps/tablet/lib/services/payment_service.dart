import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class SmartVendConfig {
  static const String paymentUrl = 'https://levending.smartvend.kz/payment_request';
  static const String resultUrl = 'https://levending.smartvend.kz/payment_result';
  static const String channelId = '36';
}

class PaymentRequest {
  final String twocode;
  final String orderid;
  final String torderid;
  PaymentRequest({required this.twocode, required this.orderid, required this.torderid});
}

/// Polling result codes per LE third-party QR payment API V2.3.
enum PaymentStatus {
  success(1, 'Оплата прошла'),
  waiting(2, 'Ожидание оплаты'),
  expired(3, 'Транзакция истекла'),
  closed(4, 'Транзакция закрыта'),
  completed(5, 'Транзакция завершена'),
  unknown(0, 'Неизвестный статус');

  final int code;
  final String label;
  const PaymentStatus(this.code, this.label);

  static PaymentStatus fromCode(int code) {
    for (final s in PaymentStatus.values) {
      if (s.code == code) return s;
    }
    return PaymentStatus.unknown;
  }
}

class PaymentException implements Exception {
  final String message;

  /// Optional debug payload — request fields actually sent (with secret
  /// redacted) and the verbatim gateway response. Surfaced in the UI's
  /// "Подробнее" panel so the operator can see exactly why SmartVend
  /// refused (wrong machid, bad signature, expired timestamp, etc).
  final String? details;

  PaymentException(this.message, {this.details});
  @override
  String toString() => message;
}

/// Direct client for SmartVend (LE) third-party QR API. Mirrors the logic
/// in `pos_app/QrActivity.kt`: SHA-1 of dictionary-sorted (appkey,
/// timestamp, randstr) → sign; everything goes form-urlencoded.
class PaymentService {
  PaymentService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  static final _rng = Random.secure();

  /// Request a QR code for an amount. [priceTenge] is whole tenge — multiplied
  /// by 100 internally per the API spec ("Set price*100"). [name] becomes the
  /// receipt's order name and is truncated to 50 UTF-8 chars.
  Future<PaymentRequest> createPayment({
    required String machid,
    required String secret,
    required int priceTenge,
    required String name,
  }) async {
    if (priceTenge <= 0) {
      throw PaymentException('Сумма должна быть больше нуля');
    }
    final cleanSecret = secret.trim();
    final cleanMachid = machid.trim();
    final timestamp = _timestamp();
    final randstr = _randStr();
    final sign = _sign(cleanSecret, randstr, timestamp);
    final cleanName = name.length > 50 ? name.substring(0, 50) : name;
    final orderid = (cleanMachid + timestamp + randstr.substring(0, 6));
    final clipped = orderid.length > 59 ? orderid.substring(0, 59) : orderid;

    final body = {
      'ver': 'v1',
      'orderid': clipped,
      'machid': cleanMachid,
      'trackno': '01',
      'name': cleanName,
      'price': (priceTenge * 100).toString(),
      'channelid': SmartVendConfig.channelId,
      'randstr': randstr,
      'timestamp': timestamp,
      'sign': sign,
    };

    _logRequest('createPayment', body, cleanSecret);

    final http.Response resp;
    try {
      resp = await _client
          .post(
            Uri.parse(SmartVendConfig.paymentUrl),
            headers: {
              'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
            },
            body: body,
            encoding: utf8,
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw PaymentException('Сеть: $e', details: _debugSnapshot(body, cleanSecret, null));
    }

    _logResponse('createPayment', resp);

    final detailsBlob = _debugSnapshot(body, cleanSecret, resp);

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw PaymentException(
        'HTTP ${resp.statusCode}',
        details: detailsBlob,
      );
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      throw PaymentException('Некорректный ответ сервера',
          details: detailsBlob);
    }

    final code = json['code']?.toString();
    if (code != '1') {
      final msg = json['msg']?.toString() ?? 'Ошибка';
      throw PaymentException(
        'SmartVend: $msg (code=$code)',
        details: detailsBlob,
      );
    }

    // SmartVend can return orderid/torderid as either string or number
    // depending on the gateway version, so coerce defensively.
    return PaymentRequest(
      twocode: json['twocode']?.toString() ?? '',
      orderid: json['orderid']?.toString() ?? clipped,
      torderid: json['torderid']?.toString() ?? '',
    );
  }

  /// Poll the gateway for payment status. Returns the parsed status code.
  Future<PaymentStatus> pollResult({
    required String machid,
    required String secret,
    required String orderid,
    required String torderid,
  }) async {
    final cleanSecret = secret.trim();
    final cleanMachid = machid.trim();
    final timestamp = _timestamp();
    final randstr = _randStr();
    final sign = _sign(cleanSecret, randstr, timestamp);

    final body = {
      'ver': 'v1',
      'orderid': orderid,
      'torderid': torderid,
      'machid': cleanMachid,
      'channelid': SmartVendConfig.channelId,
      'randstr': randstr,
      'timestamp': timestamp,
      'sign': sign,
    };

    final http.Response resp;
    try {
      resp = await _client
          .post(
            Uri.parse(SmartVendConfig.resultUrl),
            headers: {
              'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
            },
            body: body,
            encoding: utf8,
          )
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      return PaymentStatus.unknown;
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      return PaymentStatus.unknown;
    }
    try {
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final code = int.tryParse(json['code']?.toString() ?? '') ?? 0;
      return PaymentStatus.fromCode(code);
    } catch (_) {
      return PaymentStatus.unknown;
    }
  }

  // ---------- helpers ----------

  String _sign(String appkey, String randstr, String timestamp) {
    final parts = [appkey, randstr, timestamp]..sort();
    final input = parts.join();
    return sha1.convert(utf8.encode(input)).toString();
  }

  /// SmartVend signature uses UTC timestamp. The spec says "machine local"
  /// but accepts no more than 2 minutes drift from global standard time —
  /// using device-local time fails in any non-UTC zone (KZ is UTC+5).
  /// The proven `customer_web` Edge Function uses UTC, so we match.
  String _timestamp() {
    final now = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  String _randStr() => List.generate(
        16,
        (_) => _alphabet[_rng.nextInt(_alphabet.length)],
      ).join();

  // ---------- diagnostics ----------

  String _redact(String s) {
    if (s.length <= 4) return '***';
    return '${s.substring(0, 2)}***${s.substring(s.length - 2)} (len=${s.length})';
  }

  String _debugSnapshot(
    Map<String, String> body,
    String secret,
    http.Response? resp,
  ) {
    final buf = StringBuffer();
    buf.writeln('Request:');
    body.forEach((k, v) => buf.writeln('  $k = $v'));
    buf.writeln('Secret used: ${_redact(secret)}');
    if (resp != null) {
      buf.writeln('---');
      buf.writeln('HTTP ${resp.statusCode}');
      buf.writeln('Body: ${resp.body}');
    }
    return buf.toString();
  }

  void _logRequest(String name, Map<String, String> body, String secret) {
    if (!kDebugMode) return;
    debugPrint('[PaymentService.$name] request:');
    body.forEach((k, v) => debugPrint('  $k = $v'));
    debugPrint('  secret = ${_redact(secret)}');
  }

  void _logResponse(String name, http.Response resp) {
    if (!kDebugMode) return;
    debugPrint('[PaymentService.$name] HTTP ${resp.statusCode} ← ${resp.body}');
  }
}
