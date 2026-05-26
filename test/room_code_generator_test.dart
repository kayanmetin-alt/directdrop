import 'package:flutter_test/flutter_test.dart';

import 'package:directdrop/utils/room_code_generator.dart';

void main() {
  test('room code is 6 characters', () {
    final code = RoomCodeGenerator.generate();
    expect(code.length, 6);
  });

  test('room code uses allowed charset', () {
    final code = RoomCodeGenerator.generate();
    expect(RegExp(r'^[A-HJ-NP-Z2-9]{6}$').hasMatch(code), isTrue);
  });
}
