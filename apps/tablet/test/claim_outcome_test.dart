import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:micromart/services/supabase_api.dart';

/// The three verdicts `claim_machine` can return, and the one thing that
/// matters about each: whether the tablet keeps its pairing.
///
/// Written because the difference is invisible in the response — all three
/// arrive as HTTP 200 with a `reason` in the body — and because two of them
/// wipe the tablet's credentials. Getting `released` wrong in either
/// direction is a machine that either will not come back or unpairs itself
/// on a bad network day.
SupabaseApi _answering(Object body, {int status = 200}) => SupabaseApi(
      client: MockClient((_) async => http.Response(jsonEncode(body), status)),
    );

Future<ClaimOutcome> _claim(SupabaseApi api) => api.claimMachine(
      machid: '100000000',
      secret: 's',
      deviceId: 'tablet-a',
    );

void main() {
  test('claimed: no message, nothing to unpair', () async {
    final r = await _claim(_answering({'ok': true}));
    expect(r.ok, isTrue);
    expect(r.refused, isFalse);
  });

  test('occupied: another tablet holds it', () async {
    final r = await _claim(_answering(
        {'ok': false, 'reason': 'occupied', 'last_seen_at': '2026-08-28'}));
    expect(r.occupied, isTrue);
    expect(r.released, isFalse);
    expect(r.refused, isTrue);
    expect(r.message, 'err_occupied');
  });

  test('released: the owner unbound this tablet from the panel', () async {
    final r = await _claim(_answering(
        {'ok': false, 'reason': 'released', 'released_at': '2026-08-28'}));
    expect(r.released, isTrue);
    expect(r.occupied, isFalse,
        reason: 'a released machine is free — nobody else is on it');
    expect(r.refused, isTrue);
    expect(r.message, 'err_released');
  });

  test('a project without the migration still answers occupied', () async {
    // accept_admin_release and the released verdict ship together; a server
    // that predates them can only ever say occupied, and must keep working.
    final r = await _claim(_answering({'ok': false, 'reason': 'occupied'}));
    expect(r.occupied, isTrue);
    expect(r.released, isFalse);
  });

  test('transport failure never costs the pairing', () async {
    // The distinction the whole `refused` flag exists for: a tablet that
    // boots before its GSM link comes up must not unpair itself.
    final api = SupabaseApi(
      client: MockClient((_) async =>
          throw http.ClientException('SocketException: Failed host lookup')),
    );
    final r = await _claim(api);
    expect(r.ok, isFalse);
    expect(r.refused, isFalse);
  });

  test('an HTTP error is a failure, not a refusal', () async {
    final r = await _claim(_answering({'message': 'boom'}, status: 500));
    expect(r.ok, isFalse);
    expect(r.refused, isFalse);
    expect(r.message, 'err_server');
  });
}
