import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parserdart/parserdart.dart';
import 'package:binary/binary.dart';

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

/// A send-side [Transport] that captures every packet written via [write] and
/// invokes [onWrite] for each. Used in tests to react deterministically to
/// outgoing GCS packets (e.g. emitting an AP echo in response).
class CapturingTransport implements Transport {
  final List<Uint8List> sent = [];
  void Function(Uint8List packet)? onWrite;

  final StreamController<Uint8List> _dataController = StreamController();
  @override
  Stream<Uint8List> get onData => _dataController.stream;
  void emitData(Uint8List data) => _dataController.add(data);

  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async => _dataController.close();
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
  Future<int> write(Uint8List data) async {
    sent.add(data);
    onWrite?.call(data);
    return data.length;
  }

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
    await parser.loadSchemas('lib/src/schema_input');

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
    // Field offsets are computed from header length (6) + preceding field sizes:
    //   temperature: uint16 at offset 6  (headerLength=6)
    //   humidity:    double  at offset 8  (6+2)
    //   status:      uint8   at offset 16 (8+8)

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

  test('BinaryParser parses auto dataLength packet from schema', () async {
    await parser.loadSchemas('lib/src/schema_input');
    parser.start(transport);

    final futureResult = parser.onParsedData.first;

    // Packet header: 0xCA,0xFE,0x01,0x02,0x10,0x10 (dataLength=16)
    final header = <int>[0xCA, 0xFE, 0x01, 0x02, 0x10, 0x10];

    final dataBytes = ByteData(16);
    dataBytes.setFloat32(0, 1.1, Endian.little);
    dataBytes.setFloat32(4, 2.2, Endian.little);
    dataBytes.setFloat32(8, 3.3, Endian.little);
    dataBytes.setFloat32(12, 4.4, Endian.little);
    final dataList = dataBytes.buffer.asUint8List();

    int crc = 0xFFFF;
    const polynomial = 0x1021;
    for (final byte in dataList) {
      crc ^= (byte << 8);
      for (int i = 0; i < 8; i++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ polynomial) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }

    final packet = <int>[...header, ...dataList, crc & 0xFF, (crc >> 8) & 0xFF];

    transport.emitData(Uint8List.fromList(packet));
    final result = await futureResult;

    expect(result['schemaId'], 'ap_sample_2');
    expect(result['IMU.roll'], closeTo(1.1, 1e-6));
    expect(result['IMU.pitch'], closeTo(2.2, 1e-6));
    expect(result['IMU.yaw'], closeTo(3.3, 1e-6));
    expect(result['IMU.altBaro'], closeTo(4.4, 1e-6));
  });

  // Builds an `ap_parameter_single` echo packet (header CA FE 01 02 11 0A +
  // Group/Key/Value(double) + CRC16) matching the parser's CRC16-CCITT.
  Uint8List buildApParameterPacket(int group, int key, double value) {
    final dataBytes = ByteData(10);
    dataBytes.setUint8(0, group);
    dataBytes.setUint8(1, key);
    dataBytes.setFloat64(2, value, Endian.little);
    final dataList = dataBytes.buffer.asUint8List();

    int crc = 0xFFFF;
    const polynomial = 0x1021;
    for (final byte in dataList) {
      crc ^= (byte << 8);
      for (int i = 0; i < 8; i++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ polynomial) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }

    return Uint8List.fromList(<int>[
      0xCA,
      0xFE,
      0x01,
      0x02,
      0x11,
      0x0A,
      ...dataList,
      crc & 0xFF,
      (crc >> 8) & 0xFF,
    ]);
  }

  test('ParameterSync matches an echoing AP for a single parameter', () async {
    final sender = BinaryPacketSender();
    await sender.loadSchemas('lib/src/schema_output');

    await parser.loadSchemas('lib/src/schema_input');
    parser.start(transport);

    final parameters = Parameters()
      ..params.add(
        Parameter(
          title: 'TEST_PARAM',
          type: 'double',
          group: Uint8(1),
          key: Uint8(4),
          info: '',
          val: 1100.0,
        ),
      );

    // Send-side transport: on every GCS packet written, emit a matching AP
    // echo into the parser's transport. The microtask delay lets the
    // parser's firstWhere subscription attach before the event arrives
    // (onParsedData is a broadcast stream).
    final senderTransport = CapturingTransport()
      ..onWrite = (_) {
        scheduleMicrotask(() {
          transport.emitData(buildApParameterPacket(1, 4, 1100.0));
        });
      };
    sender.setTransport(senderTransport);

    final sync = ParameterSync(
      sender: sender,
      parser: parser,
      parameters: parameters,
      timeout: const Duration(seconds: 1),
      maxRetries: 3,
    );

    final results = await sync.syncAll();

    expect(results.length, 1);
    expect(results.first.matched, isTrue);
    expect(results.first.sent, isTrue);
    expect(results.first.attempts, 1);
    expect(results.first.receivedValue, 1100.0);
    expect(senderTransport.sent.length, 1); // exactly one GCS packet sent
  });

  test('ParameterSync retries on value mismatch then succeeds', () async {
    final sender = BinaryPacketSender();
    await sender.loadSchemas('lib/src/schema_output');

    await parser.loadSchemas('lib/src/schema_input');
    parser.start(transport);

    final parameters = Parameters()
      ..params.add(
        Parameter(
          title: 'TEST_PARAM',
          type: 'double',
          group: Uint8(2),
          key: Uint8(7),
          info: '',
          val: 500.0,
        ),
      );

    // First send -> echo wrong value (mismatch -> retry).
    // Second send -> echo correct value (match -> success).
    final senderTransport = CapturingTransport();
    senderTransport.onWrite = (_) {
      final echoValue = senderTransport.sent.length == 1 ? 999.0 : 500.0;
      scheduleMicrotask(() {
        transport.emitData(buildApParameterPacket(2, 7, echoValue));
      });
    };
    sender.setTransport(senderTransport);

    final sync = ParameterSync(
      sender: sender,
      parser: parser,
      parameters: parameters,
      timeout: const Duration(seconds: 1),
      maxRetries: 3,
    );

    final results = await sync.syncAll();

    expect(results.length, 1);
    expect(results.first.matched, isTrue);
    expect(results.first.attempts, 2);
    expect(results.first.receivedValue, 500.0);
    expect(senderTransport.sent.length, 2); // mismatch then match
  });

  test(
    'ParameterSync records timeout failure and continues to next param',
    () async {
      final sender = BinaryPacketSender();
      await sender.loadSchemas('lib/src/schema_output');

      await parser.loadSchemas('lib/src/schema_input');
      parser.start(transport);

      // Two parameters; the first gets no echo (timeout), the second echoes.
      final parameters = Parameters()
        ..params.add(
          Parameter(
            title: 'NO_ECHO',
            type: 'double',
            group: Uint8(3),
            key: Uint8(1),
            info: '',
            val: 10.0,
          ),
        )
        ..params.add(
          Parameter(
            title: 'WITH_ECHO',
            type: 'double',
            group: Uint8(3),
            key: Uint8(2),
            info: '',
            val: 20.0,
          ),
        );

      // Echo only the second parameter (Group=3, Key=2); ignore the first.
      final senderTransport = CapturingTransport()
        ..onWrite = (packet) {
          // Inspect the sent GCS packet's Group/Key to decide whether to echo.
          // GCS packet layout: header(6) + Group(1) + Key(1) + Value(8) + CRC(2)
          final group = packet[6];
          final key = packet[7];
          if (group == 3 && key == 2) {
            scheduleMicrotask(() {
              transport.emitData(buildApParameterPacket(3, 2, 20.0));
            });
          }
        };
      sender.setTransport(senderTransport);

      final sync = ParameterSync(
        sender: sender,
        parser: parser,
        parameters: parameters,
        timeout: const Duration(milliseconds: 100),
        maxRetries: 2,
      );

      final progress = <int>[];
      final results = await sync.syncAll(
        onResult: (_, processed, _) {
          progress.add(processed);
        },
      );

      expect(results.length, 2);
      expect(results[0].matched, isFalse);
      expect(results[0].error, 'timeout');
      expect(results[0].attempts, 2);
      expect(results[1].matched, isTrue);
      expect(results[1].attempts, 1);
      expect(progress, [1, 2]);
    },
  );
}
