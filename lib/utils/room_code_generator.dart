import 'dart:math';

class RoomCodeGenerator {
  static const _chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static final _random = Random.secure();

  static String generate({int length = 6}) {
    return List.generate(
      length,
      (_) => _chars[_random.nextInt(_chars.length)],
    ).join();
  }
}
