import 'package:flutter/foundation.dart';
import 'types.dart';
import 'package:binary/binary.dart';

//convert float32 to uint8list
Uint8List float32ToBytes(double value) {
  var buffer = ByteData(4);
  buffer.setFloat32(0, value, Endian.little);
  return buffer.buffer.asUint8List();
}

//convert float64 to uint8list
Uint8List float64ToBytes(double value) {
  var buffer = ByteData(8);
  buffer.setFloat64(0, value, Endian.little);
  return buffer.buffer.asUint8List();
}

//convert int32 to uint8list
Uint8List int32ToBytes(int value) {
  var buffer = ByteData(4);
  buffer.setInt32(0, value, Endian.little);
  return buffer.buffer.asUint8List();
}

//convert uint32 to uint8list
Uint8List uint32ToBytes(int value) {
  var buffer = ByteData(4);
  buffer.setUint32(0, value, Endian.little);
  return buffer.buffer.asUint8List();
}

//convert int16 to uint8list
Uint8List int16ToBytes(int value) {
  var buffer = ByteData(2);
  buffer.setInt16(0, value, Endian.little);
  return buffer.buffer.asUint8List();
}

//convert uint16 to uint8list
Uint8List uint16ToBytes(int value) {
  var buffer = ByteData(2);
  buffer.setUint16(0, value, Endian.little);
  return buffer.buffer.asUint8List();
}

//convert int8 to uint8list
Uint8List int8ToBytes(int value) {
  var buffer = ByteData(1);
  buffer.setInt8(0, value);
  return buffer.buffer.asUint8List();
}

//convert uint8 to uint8list
Uint8List uint8ToBytes(int value) {
  var buffer = ByteData(1);
  buffer.setUint8(0, value);
  return buffer.buffer.asUint8List();
}

int dataLength(String type) {
  if (type == "float" || type == "int" || type == "uint") {
    return 4;
  } else if (type == "double") {
    return 8;
  }
  if (type == "short" || type == "ushort") {
    return 2;
  } else if (type == "byte") {
    return 1;
  }
  return 0;
}

double bytesToFloat32(Uint8List data) {
  var buffer = ByteData(4);
  buffer.setUint8(0, data[0]);
  buffer.setUint8(1, data[1]);
  buffer.setUint8(2, data[2]);
  buffer.setUint8(3, data[3]);
  return buffer.getFloat32(0, Endian.little);
}

double bytesToFloat64(Uint8List data) {
  var buffer = ByteData(8);
  buffer.setUint8(0, data[0]);
  buffer.setUint8(1, data[1]);
  buffer.setUint8(2, data[2]);
  buffer.setUint8(3, data[3]);
  buffer.setUint8(4, data[4]);
  buffer.setUint8(5, data[5]);
  buffer.setUint8(6, data[6]);
  buffer.setUint8(7, data[7]);
  return buffer.getFloat64(0, Endian.little);
}

int bytesToInt32(Uint8List data) {
  var buffer = ByteData(4);
  buffer.setUint8(0, data[0]);
  buffer.setUint8(1, data[1]);
  buffer.setUint8(2, data[2]);
  buffer.setUint8(3, data[3]);
  return buffer.getInt32(0, Endian.little);
}

int bytesToUint32(Uint8List data) {
  var buffer = ByteData(4);
  buffer.setUint8(0, data[0]);
  buffer.setUint8(1, data[1]);
  buffer.setUint8(2, data[2]);
  buffer.setUint8(3, data[3]);
  return buffer.getUint32(0, Endian.little);
}

int bytesToInt16(Uint8List data) {
  var buffer = ByteData(2);
  buffer.setUint8(0, data[0]);
  buffer.setUint8(1, data[1]);
  return buffer.getInt16(0, Endian.little);
}

int bytesToUint16(Uint8List data) {
  var buffer = ByteData(2);
  buffer.setUint8(0, data[0]);
  buffer.setUint8(1, data[1]);
  return buffer.getUint16(0, Endian.little);
}

generateCheckSum(Uint8List data) {
  //TODO check to see if this works
  Uint8 b = Uint8(0);
  Uint8 b2 = Uint8(0);
  for (int i = 0; i < data.length; i++) {
    b += Uint8(data[i]);
    b2 += b;
  }

  return Uint8List.fromList([
    (Uint8(255) & b - b2),
    (Uint8(255) & b2 - Uint8(2) * b),
  ]);
}

checkSum(List<int> data, int headerLength, int chkLength) {
  //TODO check to see if this works
  Uint8 b = Uint8(0);
  Uint8 b2 = Uint8(0);
  for (int i = headerLength; i < (data.length - chkLength); i++) {
    b += Uint8(data[i]);
    b2 += b;
  }
  var chk = Uint8List.fromList([
    (Uint8(255) & b - b2),
    (Uint8(255) & b2 - Uint8(2) * b),
  ]);
  return listEquals(chk, data.sublist(data.length - chkLength));
}
