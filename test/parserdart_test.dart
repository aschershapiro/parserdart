import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parserdart/parserdart.dart';

// Mock Transport
class MockTransport implements Transport {
  final StreamController<Uint8List> _dataController = StreamController();

  @override
  Stream<Uint8List> get onData => _dataController.stream;

  void emitData(Uint8List data) {
    _dataController.add(data);
  }

  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async {
    await _dataController.close();
  }

  @override
  bool get isConnected => true;
  @override
  Stream<void> get onDisconnect => const Stream.empty();
  @override
  Stream<Object> get onError => const Stream.empty();
  @override
  Stream<TransportState> get onStateChange => const Stream.empty();
  @override
  TransportState get state => TransportState.connected;
  @override
  Future<int> write(Uint8List data) async => 0;
  @override
  bool get isReconnecting => false;
  @override
  int get reconnectionAttempts => 0;
  @override
  Future<void> reconnect([ReconnectionConfig? config]) async {}
  @override
  void cancelReconnection() {}
}

void main() {
  late BinaryParser parser;
  late MockTransport transport;

  setUp(() async {
    parser = BinaryParser();
    transport = MockTransport();
  });

  tearDown(() async {
    await parser.dispose();
    await transport.dispose();
  });

  test('BinaryParser loads schema and parses packet', () async {
    // Load schemas from the actual schema directory
    await parser.loadSchemas('lib/src/schema');

    // Start parser
    parser.start(transport);

    // Expect parsed data
    final futureResult = parser.onParsedData.first;

    // Build packet based on sample.json:
    // Headers (6 bytes): 0xCA, 0xFE, 0x01, 0x02, 0x12, 0x0B (dataLength=11)
    // Data (11 bytes = 0x0B): temperature(uint16=2), humidity(double=8), status(uint8=1)
    // Checksum: CRC16 = 2 bytes
    // Total: 6 + 11 + 2 = 19 bytes
    //
    // Fields (byteOffset is absolute from packet start):
    //   temperature: uint16 at byteOffset 6
    //   humidity: double at byteOffset 8
    //   status: uint8 at byteOffset 16

    // Create data section (11 bytes)
    final dataBytes = ByteData(11);
    dataBytes.setUint16(
      0,
      2500,
      Endian.little,
    ); // temperature at offset 6 (0 in data)
    dataBytes.setFloat64(
      2,
      65.5,
      Endian.little,
    ); // humidity at offset 8 (2 in data)
    dataBytes.setUint8(10, 0x01); // status at offset 16 (10 in data)

    final dataBytesAsList = dataBytes.buffer.asUint8List();

    // Calculate CRC16
    int crc = 0xFFFF;
    const polynomial = 0x1021;
    for (final byte in dataBytesAsList) {
      crc ^= (byte << 8);
      for (int i = 0; i < 8; i++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ polynomial) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }

    // Build full packet
    final packet = <int>[
      0xCA,
      0xFE,
      0x01,
      0x02,
      0x12,
      0x0B, // headers (6 bytes, includes dataLength=11)
      ...dataBytesAsList, // data (11 bytes)
      crc & 0xFF, (crc >> 8) & 0xFF, // CRC16 little-endian
    ];

    transport.emitData(Uint8List.fromList(packet));

    final result = await futureResult;

    expect(result['schemaId'], 'MainPacket');
    expect(result['temperature'], 2500);
    expect(result['humidity'], 65.5);
    expect(result['status'], 1);
  });
}
