import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:parserdart/parserdart.dart';

void main() async {
  print("hello:");
  BinaryParser parser = BinaryParser();
  await parser.loadSchemas('../lib/src/schema');
  const receiverPort = 5555;
  final receiverConfig = UdpConfig(
    localHost: '127.0.0.1',
    localPort: receiverPort,
  );
  final receiver = UdpTransport(receiverConfig);
  await receiver.connect();
  parser.start(receiver);
  parser.onParsedData.listen((parsedData) {
    print('Received Parsed Data: $parsedData');
  });
}
