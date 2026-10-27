import 'package:flutter_test/flutter_test.dart';
import 'package:micromart/board/board_client.dart';

void main() {
  climateTests();
  test('STATUS: замок заперт, дверь закрыта', () {
    final r = BoardClient.parseLockStatus('LOCK=0 DOOR=0')!;
    expect(r.locked, true);
    expect(r.doorOpen, false);
  });
  test('STATUS: замок открыт, дверь открыта', () {
    final r = BoardClient.parseLockStatus('lock=1 door=1')!;
    expect(r.locked, false);
    expect(r.doorOpen, true);
  });
  test('ERR и мусор не разбираются', () {
    expect(BoardClient.parseLockStatus('ERR: unknown'), isNull);
    expect(BoardClient.parseLockStatus('LOCK= DOOR=x')!.locked, isNull);
  });
}

void climateTests() {
  test('TEMP: число, знак, регистр', () {
    expect(BoardClient.parseClimateTemp('TEMP=4.5'), 4.5);
    expect(BoardClient.parseClimateTemp('temp=-3.0'), -3.0);
  });
  test('TEMP: none, −100, ERR и пустая строка дают null', () {
    expect(BoardClient.parseClimateTemp('TEMP=none'), isNull);
    expect(BoardClient.parseClimateTemp('TEMP=-100.0'), isNull);
    expect(BoardClient.parseClimateTemp('ERR: unknown'), isNull);
    expect(BoardClient.parseClimateTemp(''), isNull);
  });
  test('STATE: охлаждение 5 °C', () {
    final r = BoardClient.parseClimateState('STATE mode=1 temp=5')!;
    expect(r.mode, 1);
    expect(r.setpoint, 5);
  });
  test('STATE: ? и не-STATE', () {
    final r = BoardClient.parseClimateState('STATE mode=? temp=?')!;
    expect(r.mode, isNull);
    expect(BoardClient.parseClimateState('ERR: x'), isNull);
  });
}
