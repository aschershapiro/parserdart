import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:iodart/iodart.dart';

/// Represents a field definition in a packet schema.
class PacketField {
  final String name;
  final String type;
  int offset;
  final String endian;
  final String? description;

  PacketField({
    required this.name,
    required this.type,
    required this.offset,
    this.endian = 'little',
    this.description,
  });

  int get size {
    switch (type) {
      case 'uint8':
      case 'int8':
      case 'bool':
        return 1;
      case 'uint16':
      case 'int16':
        return 2;
      case 'uint32':
      case 'int32':
      case 'float32':
        return 4;
      case 'float64':
      case 'double':
        return 8;
      default:
        return 0;
    }
  }

  factory PacketField.fromJson(Map<String, dynamic> json) {
    return PacketField(
      name: json['field_name'] as String,
      type: json['type'] as String,
      offset: json['byteOffset'] as int,
      endian: json['endian'] as String? ?? 'little',
      description: json['description'] as String?,
    );
  }
}

/// Represents a packet schema definition.
class PacketSchema {
  final String id;
  final String description;
  final List<int> headerBytes;
  final int length;
  final List<PacketField> fields;
  final String checksum;

  PacketSchema({
    required this.id,
    required this.description,
    required this.headerBytes,
    required this.length,
    required this.fields,
    required this.checksum,
  });

  factory PacketSchema.fromJson(Map<String, dynamic> json) {
    final headers = json['headers'] as Map<String, dynamic>;
    final headerBytes = <int>[];
    for (final value in headers.values) {
      final str = value as String;
      final hexValue = str.startsWith('0x') ? str.substring(2) : str;
      headerBytes.add(int.parse(hexValue, radix: 16));
    }
    final headerLength = headerBytes.length;
    final dataLengthStr = json['dataLength'] as String?;
    final dataLength = dataLengthStr != null
        ? int.parse(
            dataLengthStr.startsWith('0x')
                ? dataLengthStr.substring(2)
                : dataLengthStr,
            radix: 16,
          )
        : 0;
    final checksum = json['checksum'] as String;
    final checksumSize = checksum == 'CRC16' ? 2 : 0;
    final fieldsList = json['data'] as List;
    final fields = <PacketField>[];
    for (final f in fieldsList) {
      final field = PacketField.fromJson(f as Map<String, dynamic>);
      field.offset += headerLength;
      fields.add(field);
    }
    final length = headerLength + dataLength + checksumSize;
    return PacketSchema(
      id: json['packet_name'] as String,
      description: json['description'] as String,
      headerBytes: headerBytes,
      length: length,
      fields: fields,
      checksum: checksum,
    );
  }
}

/// Parser for binary data streams based on JSON schemas.
class BinaryParser {
  final List<PacketSchema> _schemas = [];
  final StreamController<Map<String, dynamic>> _parsedDataController =
      StreamController.broadcast();

  // Buffer to hold incoming data until a full packet is parsed
  final List<int> _buffer = [];

  Stream<Map<String, dynamic>> get onParsedData => _parsedDataController.stream;

  /// Loads schemas from a directory.
  Future<void> loadSchemas(String directoryPath) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) {
      throw Exception('Schema directory not found: $directoryPath');
    }

    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final content = await entity.readAsString();
          final json = jsonDecode(content) as Map<String, dynamic>;
          _schemas.add(PacketSchema.fromJson(json));
        } catch (e) {
          print('Error loading schema from ${entity.path}: $e');
        }
      }
    }
  }

  /// Starts listening to a transport's data stream.
  void start(Transport transport) {
    transport.onData.listen(_handleData);
  }

  /// Handles incoming raw binary data.
  void _handleData(Uint8List data) {
    _buffer.addAll(data);
    _processBuffer();
  }

  /// Processes the buffer to find and parse packets.
  void _processBuffer() {
    if (_buffer.isEmpty) return;

    bool packetFound = false;

    // Try to match schemas against the buffer
    for (final schema in _schemas) {
      // Check if buffer is large enough for the header check
      if (_buffer.length >= schema.headerBytes.length) {
        bool headerMatches = true;
        for (int i = 0; i < schema.headerBytes.length; i++) {
          if (_buffer[i] != schema.headerBytes[i]) {
            headerMatches = false;
            break;
          }
        }
        if (headerMatches) {
          // Potential match, check length
          if (_buffer.length >= schema.length) {
            // We have a full packet
            _parsePacket(schema);
            packetFound = true;
            break; // Restart processing with modified buffer
          }
        }
      }
    }

    // If a packet was found and parsed, try processing again (buffer shifted)
    // If no packet found but buffer is growing, we might need to discard garbage
    // For now, simple logic: if we parsed, recurse.
    if (packetFound) {
      _processBuffer();
    } else {
      // Optimization: If buffer is very large and no schema matches start,
      // we might need to shift buffer by 1 byte to search for header.
      // This is a simple implementation assuming aligned packets or clean stream.
      // For robust stream parsing, we should scan for headers.
      _scanForHeader();
    }
  }

  void _scanForHeader() {
    // If the start of the buffer doesn't match any schema header, shift until it does or buffer empty
    if (_buffer.isEmpty) return;

    bool possibleMatch = false;
    for (final schema in _schemas) {
      if (_buffer.length >= schema.headerBytes.length) {
        bool headerMatches = true;
        for (int i = 0; i < schema.headerBytes.length; i++) {
          if (_buffer[i] != schema.headerBytes[i]) {
            headerMatches = false;
            break;
          }
        }
        if (headerMatches) {
          possibleMatch = true;
          break;
        }
      }
    }

    if (!possibleMatch && _buffer.isNotEmpty) {
      // Remove first byte and try again
      _buffer.removeAt(0);
      _processBuffer();
    }
  }

  void _parsePacket(PacketSchema schema) {
    // Extract packet bytes
    final packetBytes = Uint8List.fromList(_buffer.sublist(0, schema.length));
    final byteData = ByteData.sublistView(packetBytes);

    final result = <String, dynamic>{
      'schemaId': schema.id,
      'timestamp': DateTime.now().toIso8601String(),
    };

    for (final field in schema.fields) {
      dynamic value;
      final endian = field.endian == 'little' ? Endian.little : Endian.big;

      switch (field.type) {
        case 'uint8':
          value = byteData.getUint8(field.offset);
          break;
        case 'int8':
          value = byteData.getInt8(field.offset);
          break;
        case 'uint16':
          value = byteData.getUint16(field.offset, endian);
          break;
        case 'int16':
          value = byteData.getInt16(field.offset, endian);
          break;
        case 'uint32':
          value = byteData.getUint32(field.offset, endian);
          break;
        case 'int32':
          value = byteData.getInt32(field.offset, endian);
          break;
        case 'float32':
          value = byteData.getFloat32(field.offset, endian);
          break;
        case 'float64':
          value = byteData.getFloat64(field.offset, endian);
          break;
        case 'double':
          value = byteData.getFloat64(field.offset, endian);
          break;
        case 'bool':
          value = byteData.getUint8(field.offset) != 0;
          break;
        default:
          value = 'unsupported_type';
      }
      result[field.name] = value;
    }

    _parsedDataController.add(result);

    // Remove parsed bytes from buffer
    _buffer.removeRange(0, schema.length);
  }

  Future<void> dispose() async {
    await _parsedDataController.close();
  }
}
