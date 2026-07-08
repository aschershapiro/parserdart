import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:parserdart/parserdart.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Parser & Sender Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const ParserSenderExamplePage(),
    );
  }
}

class ParserSenderExamplePage extends StatefulWidget {
  const ParserSenderExamplePage({super.key});

  @override
  State<ParserSenderExamplePage> createState() =>
      _ParserSenderExamplePageState();
}

class _ParserSenderExamplePageState extends State<ParserSenderExamplePage> {
  late BinaryParser _parser;
  late BinaryPacketSender _sender;
  SerialTransport? _stp;
  // UdpTransport? _receiver;
  // UdpTransport? _senderTransport;
  final List<Map<String, dynamic>> _parsedPackets = [];
  String _status = 'Not connected';
  bool _isConnected = false;
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _parser = BinaryParser();
    _sender = BinaryPacketSender();
    _initParserAndSender();
  }

  Future<void> _initParserAndSender() async {
    try {
      // Load schemas for receiving
      await _parser.loadSchemas('../lib/src/schema_input');
      // Load schemas for sending
      await _sender.loadSchemas('../lib/src/schema_output');
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
      // const receiverPort = 5555;
      // const senderPort = 5556;

      // Setup receiver
      // final receiverConfig = UdpConfig(
      //   localHost: '127.0.0.1',
      //   localPort: receiverPort,
      // );
      _stp = createSerialTransport();
      await _stp!.open('COM4', const SerialConfig(baudRate: 115200));
      _parser.start(_stp!);

      // Setup sender transport
      // final senderConfig = UdpConfig(
      //   localHost: '127.0.0.1',
      //   localPort: senderPort,
      //   remoteHost: '127.0.0.1',
      //   remotePort: receiverPort,
      // );
      // _senderTransport = UdpTransport(senderConfig);
      // await _senderTransport!.connect();
      _sender.setTransport(_stp!);

      setState(() {
        _status = 'Connected to Serial port ${_stp?.portName}';
        // 'Connected - Receiving on port $receiverPort, Sending to port $receiverPort';
        _isConnected = true;
      });
    } catch (e) {
      setState(() {
        _status = 'Error connecting: $e';
      });
    }
  }

  Future<void> _stopListening() async {
    await _stp?.close();

    setState(() {
      _status = 'Disconnected';
      _isConnected = false;
    });
  }

  @override
  void dispose() {
    _stp?.dispose();
    _parser.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Binary Parser & Sender Example'),
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
                      child: Text(_isConnected ? 'Disconnect' : 'Connect'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment<int>(
                  value: 0,
                  label: Text('Receiver'),
                  icon: Icon(Icons.download),
                ),
                ButtonSegment<int>(
                  value: 1,
                  label: Text('Sender'),
                  icon: Icon(Icons.upload),
                ),
              ],
              selected: {_tabIndex},
              onSelectionChanged: (Set<int> newSelection) {
                setState(() {
                  _tabIndex = newSelection.first;
                });
              },
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _tabIndex == 0 ? _buildReceiverView() : _buildSenderView(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReceiverView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
                                    e.key != 'schemaId' && e.key != 'timestamp',
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
    );
  }

  Widget _buildSenderView() {
    if (!_isConnected) {
      return const Center(
        child: Text('Please connect first to enable sending'),
      );
    }

    return DefaultTabController(
      length: _sender.schemaNames.length,
      child: Column(
        children: [
          TabBar(
            isScrollable: true,
            tabs: _sender.schemaNames.map((name) => Tab(text: name)).toList(),
          ),
          Expanded(
            child: TabBarView(
              children: _sender.schemaNames.map((schemaName) {
                return _buildSchemaForm(schemaName);
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSchemaForm(String schemaName) {
    // Get the schema to build the form
    final schemas = _sender.schemas;
    final schema = schemas.firstWhere((s) => s.id == schemaName);

    if (schema.fields.isEmpty) {
      return _buildRawDataForm(schemaName);
    } else {
      return _buildFieldsForm(schemaName, schema);
    }
  }

  Widget _buildRawDataForm(String schemaName) {
    final controller = TextEditingController();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Send Raw Data', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text(
            'This schema has no fields. Enter raw bytes as hex (e.g., 01 02 FF):',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Hex Data',
              hintText: '01 02 03 FF',
              border: OutlineInputBorder(),
            ),
            maxLines: 3,
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () async {
              try {
                final hexString = controller.text.replaceAll(' ', '');
                final bytes = <int>[];
                for (int i = 0; i < hexString.length; i += 2) {
                  bytes.add(
                    int.parse(hexString.substring(i, i + 2), radix: 16),
                  );
                }
                await _sender.send(
                  schemaName: schemaName,
                  data: Uint8List.fromList(bytes),
                );
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Sent $schemaName packet')),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('Error: $e')));
                }
              }
            },
            icon: const Icon(Icons.send),
            label: const Text('Send Packet'),
          ),
        ],
      ),
    );
  }

  Widget _buildFieldsForm(String schemaName, PacketSchema schema) {
    final controllers = <String, TextEditingController>{};
    for (final field in schema.fields) {
      controllers[field.name] = TextEditingController();
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            schema.description,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          ...schema.fields.map((field) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: TextField(
                controller: controllers[field.name],
                decoration: InputDecoration(
                  labelText: field.name,
                  hintText: _getHintForType(field.type),
                  helperText:
                      '${field.type}${field.description != null ? ' - ${field.description}' : ''}',
                  border: const OutlineInputBorder(),
                ),
                keyboardType: _getKeyboardTypeForField(field.type),
                inputFormatters: _getInputFormattersForField(field.type),
              ),
            );
          }),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () async {
              try {
                final data = <String, dynamic>{};
                for (final field in schema.fields) {
                  final value = controllers[field.name]!.text;
                  if (value.isEmpty) {
                    throw Exception('Field ${field.name} is required');
                  }
                  data[field.name] = _parseValue(value, field.type);
                }

                await _sender.send(schemaName: schemaName, data: data);

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Sent $schemaName packet')),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('Error: $e')));
                }
              }
            },
            icon: const Icon(Icons.send),
            label: const Text('Send Packet'),
          ),
        ],
      ),
    );
  }

  String _getHintForType(String type) {
    switch (type) {
      case 'uint8':
      case 'int8':
        return '0-255';
      case 'uint16':
      case 'int16':
        return 'Integer';
      case 'uint32':
      case 'int32':
        return 'Integer';
      case 'float':
      case 'float32':
      case 'float64':
      case 'double':
        return 'Decimal number';
      case 'bool':
        return 'true or false';
      default:
        return '';
    }
  }

  TextInputType _getKeyboardTypeForField(String type) {
    if (type.contains('float') || type == 'double') {
      return const TextInputType.numberWithOptions(decimal: true);
    } else if (type.contains('int') || type.contains('uint')) {
      return TextInputType.number;
    }
    return TextInputType.text;
  }

  List<TextInputFormatter> _getInputFormattersForField(String type) {
    if (type.contains('float') || type == 'double') {
      return [FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d*'))];
    } else if (type.contains('int') || type.contains('uint')) {
      return [FilteringTextInputFormatter.digitsOnly];
    }
    return [];
  }

  dynamic _parseValue(String value, String type) {
    switch (type) {
      case 'uint8':
      case 'int8':
      case 'uint16':
      case 'int16':
      case 'uint32':
      case 'int32':
        return int.parse(value);
      case 'float':
      case 'float32':
      case 'float64':
      case 'double':
        return double.parse(value);
      case 'bool':
        return value.toLowerCase() == 'true' || value == '1';
      default:
        return value;
    }
  }
}
