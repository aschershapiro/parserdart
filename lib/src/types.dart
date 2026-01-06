import 'package:binary/binary.dart';

extension Uint8_p on Uint8 {
  Uint8 operator +(Uint8 other) => Uint8((this + other) & Uint8(0xFF));
  Uint8 operator -(Uint8 other) => Uint8((this - other) & Uint8(0xFF));
  Uint8 operator *(Uint8 other) => Uint8((this * other) & Uint8(0xFF));
}

extension Uint16_p on Uint16 {
  Uint16 operator +(Uint16 other) => Uint16((this + other) & Uint16(0xFFFF));
  Uint16 operator -(Uint16 other) => Uint16((this - other) & Uint16(0xFFFF));
  Uint16 operator *(Uint16 other) => Uint16((this * other) & Uint16(0xFFFF));
}
