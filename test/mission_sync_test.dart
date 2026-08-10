import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parserdart/parserdart.dart';

class _TestTransport implements Transport {
  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>.broadcast();
  final List<Uint8List> sent = <Uint8List>[];
  void Function(Uint8List packet)? onWrite;

  @override
  Stream<Uint8List> get onData => _controller.stream;

  void emit(Uint8List data) => _controller.add(data);

  @override
  Future<int> write(Uint8List data) async {
    sent.add(data);
    onWrite?.call(data);
    return data.length;
  }

  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() => _controller.close();
  @override
  bool get isConnected => true;
  @override
  bool get isReconnecting => false;
  @override
  int get reconnectionAttempts => 0;
  @override
  TransportState get state => TransportState.connected;
  @override
  Stream<void> get onDisconnect => const Stream.empty();
  @override
  Stream<Object> get onError => const Stream.empty();
  @override
  Stream<TransportState> get onStateChange => const Stream.empty();
  @override
  Future<void> reconnect([ReconnectionConfig? config]) async {}
  @override
  void cancelReconnection() {}
}

const _first = MissionItem(
  waypointNumber: 1,
  latitude: 35.7,
  longitude: 51.4,
  altitude: 120.0,
  speed: 25,
  mode: 2,
  param: 500,
);

const _second = MissionItem(
  waypointNumber: 2,
  latitude: 35.8,
  longitude: 51.5,
  altitude: 140.0,
  speed: 30,
  mode: 3,
  param: 600,
);

Uint8List _apEcho(MissionItem item) {
  final data = ByteData(27)
    ..setUint16(0, item.waypointNumber, Endian.little)
    ..setFloat64(2, item.latitude, Endian.little)
    ..setFloat64(10, item.longitude, Endian.little)
    ..setFloat32(18, item.altitude, Endian.little)
    ..setUint16(22, item.speed, Endian.little)
    ..setUint8(24, item.mode)
    ..setUint16(25, item.param, Endian.little);
  final dataBytes = data.buffer.asUint8List();

  var crc = 0xFFFF;
  for (final byte in dataBytes) {
    crc ^= byte << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0
          ? ((crc << 1) ^ 0x1021) & 0xFFFF
          : (crc << 1) & 0xFFFF;
    }
  }

  return Uint8List.fromList(<int>[
    0xCA,
    0xFE,
    0x01,
    0x02,
    0x12,
    0x1B,
    ...dataBytes,
    crc & 0xFF,
    crc >> 8,
  ]);
}

void main() {
  late BinaryParser parser;
  late BinaryPacketSender sender;
  late _TestTransport apTransport;
  late _TestTransport gcsTransport;

  setUp(() async {
    parser = BinaryParser();
    sender = BinaryPacketSender();
    apTransport = _TestTransport();
    gcsTransport = _TestTransport();
    await parser.loadSchemas('lib/src/schema_input');
    await sender.loadSchemas('lib/src/schema_output');
    parser.start(apTransport);
    sender.setTransport(gcsTransport);
  });

  tearDown(() async {
    await parser.dispose();
    await apTransport.dispose();
    await gcsTransport.dispose();
  });

  test(
    'sends mission items in order and waits for each matching echo',
    () async {
      gcsTransport.onWrite = (packet) {
        final number = ByteData.sublistView(packet).getUint16(6, Endian.little);
        final item = number == 1 ? _first : _second;
        scheduleMicrotask(() => apTransport.emit(_apEcho(item)));
      };

      final results = await MissionSync(
        sender: sender,
        parser: parser,
        missionItems: const <MissionItem>[_first, _second],
      ).syncAll();

      expect(results, hasLength(2));
      expect(results.every((result) => result.success), isTrue);
      expect(gcsTransport.sent, hasLength(2));
      expect(gcsTransport.sent[0][5], 0x1B);
      expect(
        ByteData.sublistView(gcsTransport.sent[0]).getUint16(31, Endian.little),
        500,
      );
      expect(
        ByteData.sublistView(gcsTransport.sent[1]).getUint16(6, Endian.little),
        2,
      );
    },
  );

  test('retries when any echoed field differs', () async {
    gcsTransport.onWrite = (_) {
      final echo = gcsTransport.sent.length == 1
          ? const MissionItem(
              waypointNumber: 1,
              latitude: 35.7,
              longitude: 51.4,
              altitude: 120.0,
              speed: 25,
              mode: 2,
              param: 501,
            )
          : _first;
      scheduleMicrotask(() => apTransport.emit(_apEcho(echo)));
    };

    final results = await MissionSync(
      sender: sender,
      parser: parser,
      missionItems: const <MissionItem>[_first],
    ).syncAll();

    expect(results.single.success, isTrue);
    expect(results.single.attempts, 2);
    expect(gcsTransport.sent, hasLength(2));
  });

  test('stops the mission when an item exhausts its attempts', () async {
    final results = await MissionSync(
      sender: sender,
      parser: parser,
      missionItems: const <MissionItem>[_first, _second],
      timeout: const Duration(milliseconds: 20),
      maxRetries: 2,
    ).syncAll();

    expect(results, hasLength(1));
    expect(results.single.success, isFalse);
    expect(results.single.error, 'timeout');
    expect(results.single.attempts, 2);
    expect(gcsTransport.sent, hasLength(2));
  });
}
