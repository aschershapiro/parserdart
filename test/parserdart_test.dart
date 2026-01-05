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
  late Directory tempDir;
  late BinaryParser parser;
  late MockTransport transport;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('schema_test');
    parser = BinaryParser();
    transport = MockTransport();
  });

  tearDown(() async {
    await parser.dispose();
    await transport.dispose();
    await tempDir.delete(recursive: true);
  });

  test('BinaryParser loads schema and parses packet', () async {
    // Create a schema file based on new format
    final schemaJson = '''
    {
      "packet_name": "test_packet",
      "version": "1.0.0",
      "description": "Test Packet",
      "headers": {
        "header1": "0xAA"
      },
      "dataLength": "0x05",
      "data": [
        { "field_name": "val1", "type": "uint8", "byteOffset": 0 },
        { "field_name": "val2", "type": "uint16", "byteOffset": 1, "endian": "little" },
        { "field_name": "flag", "type": "bool", "byteOffset": 3 }
      ],
      "checksum": "CRC16"
    }
    ''';
    final schemaFile = File('${tempDir.path}/test.json');
    await schemaFile.writeAsString(schemaJson);

    // Load schemas
    await parser.loadSchemas(tempDir.path);

    // Start parser
    parser.start(transport);

    // Expect parsed data
    final futureResult = parser.onParsedData.first;

    // Send data: header 0xAA, data: val1=0x01, val2=0x0203 (little), flag=0x01, padding?, checksum 2 bytes
    // Total length: 1 + 5 + 2 = 8
    final data = Uint8List.fromList([
      0xAA,
      0x01,
      0x02,
      0x03,
      0x01,
      0x00,
      0x00,
      0x00,
    ]);
    transport.emitData(data);

    final result = await futureResult;

    expect(result['schemaId'], 'test_packet');
    expect(result['val1'], 1);
    expect(result['val2'], 0x0302);
    expect(result['flag'], true);
  });
}
