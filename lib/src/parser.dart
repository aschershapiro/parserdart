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
      case 'float':
      case 'float32':
        return 4;
      case 'uint64':
      case 'int64':
      case 'float64':
      case 'double':
        return 8;
      default:
        return 0;
    }
  }

  factory PacketField.fromJson(Map<String, dynamic> json) {
    return PacketField(
      name: (json['field_name'] ?? json['tag']) as String,
      type: json['type'] as String,
      offset: 0,
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
  final int headerLength;
  final int dataLength;
  final bool hasAutoDataLength;
  final int? dataLengthHeaderIndex;
  final int length;
  final List<PacketField> fields;
  final String checksum;
  final int checksumSize;

  PacketSchema({
    required this.id,
    required this.description,
    required this.headerBytes,
    required this.headerLength,
    required this.dataLength,
    required this.hasAutoDataLength,
    required this.dataLengthHeaderIndex,
    required this.length,
    required this.fields,
    required this.checksum,
    required this.checksumSize,
  });

  factory PacketSchema.fromJson(Map<String, dynamic> json) {
    final headers = json['headers'] as Map<String, dynamic>;
    final headerBytes = <int>[];
    int dataLength = 0;
    bool hasAutoDataLength = false;
    int? dataLengthHeaderIndex;

    for (final entry in headers.entries) {
      final str = entry.value as String;
      if (entry.key == 'dataLength' && str.toLowerCase() == 'auto') {
        hasAutoDataLength = true;
        dataLengthHeaderIndex = headerBytes.length;
        headerBytes.add(0);
        continue;
      }
      final hexValue = str.startsWith('0x') ? str.substring(2) : str;
      final byteValue = int.parse(hexValue, radix: 16);
      headerBytes.add(byteValue);

      // Extract dataLength value from the header
      if (entry.key == 'dataLength') {
        dataLength = byteValue;
      }
    }
    final headerLength = headerBytes.length;
    final checksum = json['checksum'] as String;
    final checksumSize = checksum == 'CRC16' ? 2 : 0;
    final fieldsList = json['data'] as List;
    final fields = <PacketField>[];
    int fieldOffset = headerLength;
    for (final f in fieldsList) {
      final field = PacketField.fromJson(f as Map<String, dynamic>);
      field.offset = fieldOffset;
      fieldOffset += field.size;
      fields.add(field);
    }
    final length = headerLength + dataLength + checksumSize;
    return PacketSchema(
      id: json['packet_name'] as String,
      description: json['description'] as String,
      headerBytes: headerBytes,
      headerLength: headerLength,
      dataLength: dataLength,
      hasAutoDataLength: hasAutoDataLength,
      dataLengthHeaderIndex: dataLengthHeaderIndex,
      length: length,
      fields: fields,
      checksum: checksum,
      checksumSize: checksumSize,
    );
  }

  int actualDataLength(Uint8List packetBytes) {
    if (hasAutoDataLength && dataLengthHeaderIndex != null) {
      return packetBytes[dataLengthHeaderIndex!];
    }
    return dataLength;
  }

  int packetLength(Uint8List packetBytes) {
    return headerLength + actualDataLength(packetBytes) + checksumSize;
  }
}

/// Parser for binary data streams based on JSON schemas.
class BinaryParser {
  final List<PacketSchema> _schemas = [];
  final List<StreamSubscription<Uint8List>> _transportSubscriptions = [];
  final StreamController<Map<String, dynamic>> _parsedDataController =
      StreamController.broadcast();

  /// Buffer to hold incoming data until a full packet is parsed.
  final List<int> _buffer = [];

  /// Maximum buffer size to prevent memory issues (default: 64KB).
  static const int maxBufferSize = 65536;

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
    _transportSubscriptions.add(transport.onData.listen(_handleData));
  }

  /// Handles incoming raw binary data.
  void _handleData(Uint8List data) {
    _buffer.addAll(data);
    _trimBufferIfNeeded();
    _processBuffer();
  }

  /// Trims the buffer if it exceeds the maximum size.
  void _trimBufferIfNeeded() {
    if (_buffer.length > maxBufferSize) {
      final excess = _buffer.length - maxBufferSize;
      _buffer.removeRange(0, excess);
    }
  }

  /// Processes the buffer to find and parse complete packets.
  void _processBuffer() {
    while (_buffer.isNotEmpty) {
      // Step 1: Find a valid header
      final headerIndex = _findHeader();
      if (headerIndex == -1) {
        // No valid header found, clear buffer (keep last few bytes for partial header)
        _discardInvalidData();
        return;
      }

      // Step 2: Discard bytes before the header
      if (headerIndex > 0) {
        _buffer.removeRange(0, headerIndex);
      }

      // Step 3: Try to match and parse a packet
      final schema = _matchSchema();
      if (schema == null) {
        // Header matched but no schema fits - discard first byte and retry
        _buffer.removeAt(0);
        continue;
      }

      if (_buffer.length < schema.headerLength) {
        // Wait until the full header is available
        return;
      }

      // Determine full packet length using received header bytes when auto length is used.
      final packetLength = schema.hasAutoDataLength
          ? schema.packetLength(
              Uint8List.fromList(_buffer.sublist(0, schema.headerLength)),
            )
          : schema.length;

      if (_buffer.length < packetLength) {
        // Incomplete packet, wait for more data
        return;
      }

      // Step 5: Parse the complete packet
      _parsePacket(schema, packetLength);
    }
  }

  /// Finds the index of the first valid header in the buffer.
  /// Returns -1 if no header is found.
  int _findHeader() {
    for (int i = 0; i <= _buffer.length; i++) {
      for (final schema in _schemas) {
        if (_matchesHeaderAt(schema, i)) {
          return i;
        }
      }
    }
    return -1;
  }

  /// Checks if the buffer matches a schema's header at the given index.
  bool _matchesHeaderAt(PacketSchema schema, int index) {
    if (index + schema.headerBytes.length > _buffer.length) {
      return false;
    }
    for (int i = 0; i < schema.headerBytes.length; i++) {
      if (schema.hasAutoDataLength && schema.dataLengthHeaderIndex == i) {
        continue;
      }
      if (_buffer[index + i] != schema.headerBytes[i]) {
        return false;
      }
    }
    return true;
  }

  /// Returns the first schema that matches the current buffer start.
  PacketSchema? _matchSchema() {
    for (final schema in _schemas) {
      if (_matchesHeaderAt(schema, 0)) {
        return schema;
      }
    }
    return null;
  }

  /// Discards invalid data while keeping potential partial headers.
  void _discardInvalidData() {
    if (_schemas.isEmpty || _buffer.isEmpty) {
      _buffer.clear();
      return;
    }

    // Keep only the last (maxHeaderLength - 1) bytes for partial header matching
    final maxHeaderLength = _schemas
        .map((s) => s.headerBytes.length)
        .reduce((a, b) => a > b ? a : b);
    final keepBytes = maxHeaderLength - 1;

    if (_buffer.length > keepBytes) {
      _buffer.removeRange(0, _buffer.length - keepBytes);
    }
  }

  /// Parses a packet from the buffer using the given schema.
  /// Returns true if packet was valid and parsed, false if CRC failed.
  bool _parsePacket(PacketSchema schema, int packetLength) {
    final packetBytes = Uint8List.fromList(_buffer.sublist(0, packetLength));
    final actualDataLength = schema.actualDataLength(packetBytes);

    // Validate CRC16 if checksum is enabled
    if (schema.checksum == 'CRC16' && schema.checksumSize > 0) {
      final dataStart = schema.headerLength;
      final dataEnd = schema.headerLength + actualDataLength;
      final dataBytes = packetBytes.sublist(dataStart, dataEnd);

      // Extract received CRC (last 2 bytes, little-endian)
      final crcOffset = packetLength - 2;
      final receivedCrc =
          packetBytes[crcOffset] | (packetBytes[crcOffset + 1] << 8);

      // Calculate CRC16 of data bytes
      final calculatedCrc = _calculateCrc16(dataBytes);

      if (receivedCrc != calculatedCrc) {
        // CRC mismatch - discard this packet
        _buffer.removeRange(0, packetLength);
        return false;
      }
    }

    final byteData = ByteData.sublistView(packetBytes);

    final result = <String, dynamic>{
      'schemaId': schema.id,
      'timestamp': DateTime.now().toIso8601String(),
    };

    for (final field in schema.fields) {
      result[field.name] = _parseField(byteData, field);
    }

    _parsedDataController.add(result);

    // Remove parsed bytes from buffer
    _buffer.removeRange(0, packetLength);
    return true;
  }

  /// Calculates CRC16 (CCITT) for the given data bytes.
  int _calculateCrc16(Uint8List data) {
    int crc = 0xFFFF;
    const polynomial = 0x1021;

    for (final byte in data) {
      crc ^= (byte << 8);
      for (int i = 0; i < 8; i++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ polynomial) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }
    return crc;
  }

  /// Parses a single field from the byte data.
  dynamic _parseField(ByteData byteData, PacketField field) {
    final endian = field.endian == 'little' ? Endian.little : Endian.big;

    switch (field.type) {
      case 'uint8':
        return byteData.getUint8(field.offset);
      case 'int8':
        return byteData.getInt8(field.offset);
      case 'uint16':
        return byteData.getUint16(field.offset, endian);
      case 'int16':
        return byteData.getInt16(field.offset, endian);
      case 'uint32':
        return byteData.getUint32(field.offset, endian);
      case 'int32':
        return byteData.getInt32(field.offset, endian);
      case 'float':
      case 'float32':
        return byteData.getFloat32(field.offset, endian);
      case 'float64':
      case 'double':
        return byteData.getFloat64(field.offset, endian);
      case 'bool':
        return byteData.getUint8(field.offset) != 0;
      default:
        return null;
    }
  }

  /// Clears the internal buffer.
  void clearBuffer() {
    _buffer.clear();
  }

  /// Returns the current buffer size.
  int get bufferSize => _buffer.length;

  Future<void> dispose() async {
    for (final subscription in _transportSubscriptions) {
      await subscription.cancel();
    }
    _transportSubscriptions.clear();
    await _parsedDataController.close();
    _buffer.clear();
  }
}
