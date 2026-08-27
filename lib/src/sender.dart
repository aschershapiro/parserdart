import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:iodart/iodart.dart';
import 'parser.dart';

/// Sender for binary data packets based on JSON schemas.
class BinaryPacketSender {
  final List<PacketSchema> _schemas = [];
  Transport? _transport;

  /// Sets the transport to use for sending packets.
  void setTransport(Transport transport) {
    _transport = transport;
  }

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

  /// Loads a single schema from a file path.
  Future<void> loadSchema(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('Schema file not found: $filePath');
    }

    try {
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      _schemas.add(PacketSchema.fromJson(json));
    } catch (e) {
      throw Exception('Error loading schema from $filePath: $e');
    }
  }

  /// Finds a schema by packet name.
  PacketSchema? _findSchema(String schemaName) {
    try {
      return _schemas.firstWhere((schema) => schema.id == schemaName);
    } catch (e) {
      return null;
    }
  }

  /// Returns the message ID declared by the named loaded schema.
  int messageIdForSchema(String schemaName) {
    final schema = _findSchema(schemaName);
    if (schema == null) {
      throw Exception('Schema not found: $schemaName');
    }
    if (schema.headerBytes.length <= 4) {
      throw Exception('Schema "$schemaName" has no messageId header.');
    }
    return schema.headerBytes[4];
  }

  /// Sends a packet based on the schema name and data.
  ///
  /// If the schema has fields defined in "data", pass a Map<String, dynamic>
  /// with field names as keys and their values.
  ///
  /// If the schema has empty "data", pass a Uint8List for raw data.
  ///
  /// The messageId parameter allows overriding the messageId in the schema header.
  Future<void> send({
    required String schemaName,
    int? messageId,
    dynamic data,
  }) async {
    if (_transport == null) {
      throw Exception('Transport not set. Call setTransport() first.');
    }

    final schema = _findSchema(schemaName);
    if (schema == null) {
      throw Exception('Schema not found: $schemaName');
    }

    Uint8List packet;

    if (schema.fields.isEmpty) {
      // Schema has no fields - expecting raw Uint8List data
      if (data is! Uint8List) {
        throw Exception(
          'Schema "$schemaName" has no fields. Expected Uint8List data.',
        );
      }
      packet = _buildPacketWithRawData(schema, data, messageId);
    } else {
      // Schema has fields - expecting Map<String, dynamic> data
      if (data is! Map<String, dynamic>) {
        throw Exception(
          'Schema "$schemaName" has fields. Expected Map<String, dynamic> data.',
        );
      }
      packet = _buildPacketWithFields(schema, data, messageId);
    }

    _transport!.write(packet);
  }

  /// Builds a packet with raw data (when schema has no fields).
  Uint8List _buildPacketWithRawData(
    PacketSchema schema,
    Uint8List rawData,
    int? messageId,
  ) {
    final headerBytes = List<int>.from(schema.headerBytes);

    // Override messageId if provided
    if (messageId != null) {
      // Assuming messageId is at index 4 (after header1, header2, senderId, receiverId)
      if (headerBytes.length > 4) {
        headerBytes[4] = messageId;
      }
    }

    // Update dataLength in header if needed (typically at index 5)
    if (headerBytes.length > 5) {
      headerBytes[5] = rawData.length;
    }

    final packetLength =
        headerBytes.length + rawData.length + schema.checksumSize;
    final packet = Uint8List(packetLength);

    // Copy header
    packet.setRange(0, headerBytes.length, headerBytes);

    // Copy raw data
    packet.setRange(
      headerBytes.length,
      headerBytes.length + rawData.length,
      rawData,
    );

    // Calculate and append checksum if required
    if (schema.checksum == 'CRC16' && schema.checksumSize > 0) {
      final dataStart = schema.headerLength;
      final dataEnd = dataStart + rawData.length;
      final dataBytes = packet.sublist(dataStart, dataEnd);
      final crc = _calculateCrc16(dataBytes);

      // Append CRC16 in little-endian format
      packet[dataEnd] = crc & 0xFF;
      packet[dataEnd + 1] = (crc >> 8) & 0xFF;
    }

    return packet;
  }

  /// Builds a packet with structured fields from data map.
  Uint8List _buildPacketWithFields(
    PacketSchema schema,
    Map<String, dynamic> data,
    int? messageId,
  ) {
    final headerBytes = List<int>.from(schema.headerBytes);

    // Override messageId if provided
    if (messageId != null) {
      // Assuming messageId is at index 4
      if (headerBytes.length > 4) {
        headerBytes[4] = messageId;
      }
    }

    // Calculate actual data length from fields
    int calculatedDataLength = 0;
    if (schema.fields.isNotEmpty) {
      final lastField = schema.fields.last;
      calculatedDataLength =
          lastField.offset + lastField.size - schema.headerLength;
    }

    // Update dataLength in header (typically at index 5)
    if (headerBytes.length > 5) {
      headerBytes[5] = calculatedDataLength;
    }

    final packetLength =
        headerBytes.length + calculatedDataLength + schema.checksumSize;
    final packet = Uint8List(packetLength);
    final byteData = ByteData.sublistView(packet);

    // Copy header
    packet.setRange(0, headerBytes.length, headerBytes);

    // Encode each field
    for (final field in schema.fields) {
      if (!data.containsKey(field.name)) {
        throw Exception('Missing field in data: ${field.name}');
      }

      final value = data[field.name];
      _encodeField(byteData, field, value);
    }

    // Calculate and append checksum if required
    if (schema.checksum == 'CRC16' && schema.checksumSize > 0) {
      final dataStart = schema.headerLength;
      final dataEnd = dataStart + calculatedDataLength;
      final dataBytes = packet.sublist(dataStart, dataEnd);
      final crc = _calculateCrc16(dataBytes);

      // Append CRC16 in little-endian format
      packet[dataEnd] = crc & 0xFF;
      packet[dataEnd + 1] = (crc >> 8) & 0xFF;
    }

    return packet;
  }

  /// Encodes a single field into the byte data.
  void _encodeField(ByteData byteData, PacketField field, dynamic value) {
    final endian = field.endian == 'little' ? Endian.little : Endian.big;

    switch (field.type) {
      case 'uint8':
        if (value is! int) {
          throw Exception(
            'Field ${field.name} expects int, got ${value.runtimeType}',
          );
        }
        byteData.setUint8(field.offset, value);
        break;
      case 'int8':
        if (value is! int) {
          throw Exception(
            'Field ${field.name} expects int, got ${value.runtimeType}',
          );
        }
        byteData.setInt8(field.offset, value);
        break;
      case 'uint16':
        if (value is! int) {
          throw Exception(
            'Field ${field.name} expects int, got ${value.runtimeType}',
          );
        }
        byteData.setUint16(field.offset, value, endian);
        break;
      case 'int16':
        if (value is! int) {
          throw Exception(
            'Field ${field.name} expects int, got ${value.runtimeType}',
          );
        }
        byteData.setInt16(field.offset, value, endian);
        break;
      case 'uint32':
        if (value is! int) {
          throw Exception(
            'Field ${field.name} expects int, got ${value.runtimeType}',
          );
        }
        byteData.setUint32(field.offset, value, endian);
        break;
      case 'int32':
        if (value is! int) {
          throw Exception(
            'Field ${field.name} expects int, got ${value.runtimeType}',
          );
        }
        byteData.setInt32(field.offset, value, endian);
        break;
      case 'float':
      case 'float32':
        if (value is! num) {
          throw Exception(
            'Field ${field.name} expects num, got ${value.runtimeType}',
          );
        }
        byteData.setFloat32(field.offset, value.toDouble(), endian);
        break;
      case 'float64':
      case 'double':
        if (value is! num) {
          throw Exception(
            'Field ${field.name} expects num, got ${value.runtimeType}',
          );
        }
        byteData.setFloat64(field.offset, value.toDouble(), endian);
        break;
      case 'bool':
        byteData.setUint8(field.offset, value == true ? 1 : 0);
        break;
      default:
        throw Exception('Unsupported field type: ${field.type}');
    }
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

  /// Returns the list of loaded schema names.
  List<String> get schemaNames => _schemas.map((s) => s.id).toList();

  /// Returns the list of loaded schemas.
  List<PacketSchema> get schemas => List.unmodifiable(_schemas);

  /// Clears all loaded schemas.
  void clearSchemas() {
    _schemas.clear();
  }
}
