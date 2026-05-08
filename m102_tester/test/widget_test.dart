import 'package:flutter_test/flutter_test.dart';
import 'package:m102_tester/models/motor_layout.dart';

void main() {
  test('Motor layout: shelf label ↔ motor id round-trip', () {
    expect(MotorLayout.labelToMotor('001'), 99);
    expect(MotorLayout.labelToMotor('006'), 94);
    expect(MotorLayout.labelToMotor('011'), 89);
    expect(MotorLayout.labelToMotor('056'), 44);
    expect(MotorLayout.motorToLabel(99), '001');
    expect(MotorLayout.motorToLabel(44), '056');
    expect(MotorLayout.allMotors().length, 36);
  });
}
