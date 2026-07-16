import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'jsonhandler.dart';
import 'package:binary/binary.dart';
import 'utility.dart';

class Parameters implements JsonHandler {
  Parameters();

  Parameters.fromJson(String path) {
    var input = File(path).readAsStringSync();
    var map = jsonDecode(input);
    var list = map['Params'];
    for (var element in list) {
      var par = Parameter(
        group: Uint8(element['Group']),
        key: Uint8(element['Key']),
        type: element['Type'],
        info: element['Info'],
        title: element['Title'],
        val: (element['Value'] as num).toDouble(),
      );
      params.add(par);
    }
  }
  @override
  Map toJson() {
    var pr = params.map((e) => e.toJson()).toList();
    return {'Params': pr};
  }

  List<Parameter> params = [];
}

class Parameter {
  Parameter({
    required this.type,
    required this.title,
    required this.group,
    required this.key,
    required this.info,
    required double val,
  }) {
    bytes = Uint8List(dataLength(type));
    value = val;
  }
  Map toJson() => {
    'Title': title,
    'Type': type,
    'Group': group.toInt(),
    'Key': key.toInt(),
    'Value': (type == 'float' || type == 'double') ? value : value.toInt(),
    'Info': info,
  };
  final String title;
  final String type;
  final String info;
  final Uint8 group;
  final Uint8 key;
  bool transmitData = false;
  late double _value;
  late Uint8List bytes;
  // define setter and getter for value
  double get value => _value;
  set value(double val) {
    _value = val;
    setBytes(val);
  }

  // set bytes from value
  void setBytes(double val) {
    if (type == "float") {
      bytes = float32ToBytes(val);
    } else if (type == "double") {
      bytes = float64ToBytes(val);
    } else if (type == "int32") {
      bytes = int32ToBytes(val.toInt());
    } else if (type == "uint32") {
      bytes = uint32ToBytes(val.toInt());
    } else if (type == "int16") {
      bytes = int16ToBytes(val.toInt());
    } else if (type == "uint16") {
      bytes = uint16ToBytes(val.toInt());
    } else if (type == "uint8") {
      bytes = uint8ToBytes(val.toInt());
    }
  }

  // set value from bytes
  void setValue(Uint8List data) {
    if (type == "float") {
      _value = bytesToFloat32(data);
    } else if (type == "double") {
      _value = bytesToFloat64(data);
    } else if (type == "int32") {
      _value = bytesToInt32(data).toDouble();
    } else if (type == "uint32") {
      _value = bytesToUint32(data).toDouble();
    } else if (type == "int16") {
      _value = bytesToInt16(data).toDouble();
    } else if (type == "uint16") {
      _value = bytesToUint16(data).toDouble();
    } else if (type == "uint8") {
      _value = data[0].toDouble();
    }
  }

  void updateBytes(Uint8List inp) {
    bytes = inp;
    setValue(bytes);
  }

  @override
  String toString() {
    return type == 'float' || type == 'double'
        ? value.toString()
        : value.toInt().toString();
  }
}
