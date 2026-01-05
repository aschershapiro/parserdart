import 'package:flutter/material.dart';
import 'package:parserdart/parserdart.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Parser Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const ParserExamplePage(),
    );
  }
}

class ParserExamplePage extends StatefulWidget {
  const ParserExamplePage({super.key});

  @override
  State<ParserExamplePage> createState() => _ParserExamplePageState();
}

class _ParserExamplePageState extends State<ParserExamplePage> {
  late BinaryParser _parser;
  UdpTransport? _receiver;
  final List<Map<String, dynamic>> _parsedPackets = [];
  String _status = 'Not connected';
  bool _isConnected = false;

  @override
  void initState() {
    super.initState();
    _parser = BinaryParser();
    _initParser();
  }

  Future<void> _initParser() async {
    try {
      // Load schemas from the package's schema directory
      await _parser.loadSchemas('../lib/src/schema');
      setState(() {
        _status = 'Schemas loaded. Ready to connect.';
      });
    } catch (e) {
      setState(() {
        _status = 'Error loading schemas: $e';
      });
    }

    _parser.onParsedData.listen((parsedData) {
      setState(() {
        _parsedPackets.insert(0, parsedData);
        if (_parsedPackets.length > 50) {
          _parsedPackets.removeLast();
        }
      });
    });
  }

  Future<void> _startListening() async {
    try {
      const receiverPort = 5555;
      final receiverConfig = UdpConfig(
        localHost: '127.0.0.1',
        localPort: receiverPort,
      );
      _receiver = UdpTransport(receiverConfig);
      await _receiver!.connect();
      _parser.start(_receiver!);
      setState(() {
        _status = 'Listening on UDP port $receiverPort';
        _isConnected = true;
      });
    } catch (e) {
      setState(() {
        _status = 'Error connecting: $e';
      });
    }
  }

  Future<void> _stopListening() async {
    await _receiver?.disconnect();
    await _receiver?.dispose();
    _receiver = null;
    setState(() {
      _status = 'Disconnected';
      _isConnected = false;
    });
  }

  @override
  void dispose() {
    _receiver?.dispose();
    _parser.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Binary Parser Example'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Icon(
                      _isConnected ? Icons.check_circle : Icons.circle_outlined,
                      color: _isConnected ? Colors.green : Colors.grey,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_status)),
                    const SizedBox(width: 16),
                    ElevatedButton(
                      onPressed: _isConnected
                          ? _stopListening
                          : _startListening,
                      child: Text(_isConnected ? 'Stop' : 'Start Listening'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Parsed Packets (${_parsedPackets.length})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _parsedPackets.isEmpty
                  ? const Center(child: Text('No packets received yet'))
                  : ListView.builder(
                      itemCount: _parsedPackets.length,
                      itemBuilder: (context, index) {
                        final packet = _parsedPackets[index];
                        return Card(
                          child: ListTile(
                            title: Text('Schema: ${packet['schemaId']}'),
                            subtitle: Text(
                              packet.entries
                                  .where(
                                    (e) =>
                                        e.key != 'schemaId' &&
                                        e.key != 'timestamp',
                                  )
                                  .map((e) => '${e.key}: ${e.value}')
                                  .join(', '),
                            ),
                            trailing: Text(
                              packet['timestamp']
                                      ?.toString()
                                      .split('T')
                                      .last
                                      .split('.')
                                      .first ??
                                  '',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
