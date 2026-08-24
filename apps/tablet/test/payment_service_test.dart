import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:micromart/services/payment_service.dart';

/// Fields a `payment_request` has always carried. The point of the O!Dengi
/// work is that a Kazakh machine keeps sending exactly this and nothing else,
/// so the set is spelled out here rather than derived from the code.
const _kaspiFields = {
  'ver',
  'orderid',
  'machid',
  'trackno',
  'name',
  'price',
  'channelid',
  'randstr',
  'timestamp',
  'sign',
};

/// Captures the form the service posts and answers with a valid gateway reply.
({PaymentService service, Map<String, String> Function() body}) _capturing() {
  Map<String, String> captured = {};
  final client = MockClient((req) async {
    captured = Uri.splitQueryString(req.body);
    return http.Response(
      jsonEncode({'code': '1', 'orderid': 'o1', 'torderid': 't1', 'twocode': 'qr'}),
      200,
    );
  });
  return (service: PaymentService(client: client), body: () => captured);
}

void main() {
  test('no terNumber: the request is exactly what Kaspi machines always sent',
      () async {
    final c = _capturing();
    await c.service.createPayment(
      machid: '12345678901',
      secret: '1234567890abcdef',
      priceTenge: 150,
      name: 'Cola',
    );
    // Absent, not blank. The gateway reads a missing field as Kaspi, and an
    // empty one is a different request than the one in production today.
    expect(c.body().containsKey('terNumber'), isFalse);
    expect(c.body().keys.toSet(), _kaspiFields);
  });

  test('terNumber=ODG rides along without touching anything else', () async {
    final c = _capturing();
    await c.service.createPayment(
      machid: '12345678901',
      secret: '1234567890abcdef',
      priceTenge: 150,
      name: 'Cola',
      terNumber: 'ODG',
    );
    final body = c.body();
    expect(body['terNumber'], 'ODG');
    expect(body.keys.toSet(), {..._kaspiFields, 'terNumber'});

    // The signature covers appkey/randstr/timestamp only (LE QR API V2.3 §7).
    // If the gateway ever starts folding terNumber in, this is the assertion
    // that has to change — and it will fail loudly rather than silently
    // sending a signature the gateway rejects for reasons nobody can see.
    final parts = ['1234567890abcdef', body['randstr']!, body['timestamp']!]
      ..sort();
    expect(body['sign'], sha1.convert(utf8.encode(parts.join())).toString());
  });

  test('blank terNumber is treated as Kaspi, not as a channel', () async {
    final c = _capturing();
    await c.service.createPayment(
      machid: '12345678901',
      secret: '1234567890abcdef',
      priceTenge: 150,
      name: 'Cola',
      terNumber: '   ',
    );
    expect(c.body().containsKey('terNumber'), isFalse);
  });
}
