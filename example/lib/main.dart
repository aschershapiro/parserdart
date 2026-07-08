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
  Transport? _receiver;
  Transport? _senderTransport;
  final List<Map<String, dynamic>> _parsedPackets = [];
  String _status = 'Not connected';
  bool _isConnected = false;
  int _tabIndex = 0;

  // Connection type
  int _connectionType = 0; // 0 = UDP, 1 = Serial

  // UDP config
  final _receiverPortController = TextEditingController(text: '5555');
  final _senderPortController = TextEditingController(text: '5556');
  final _remoteHostController = TextEditingController(text: '127.0.0.1');

  // Serial config
  List<SerialDeviceInfo> _availablePorts = [];
  String? _selectedPort;
  final _baudRateController = TextEditingController(text: '115200');
  SerialTransport? _serialTransport;

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

  Future<void> _refreshSerialPorts() async {
    try {
      final transport = createSerialTransport();
      final devices = await transport.listDevices();
      await transport.dispose();
      setState(() {
        _availablePorts = devices;
        if (_selectedPort == null && devices.isNotEmpty) {
          _selectedPort = devices.first.portName;
        }
      });
    } catch (e) {
      setState(() {
        _status = 'Error listing serial ports: $e';
      });
    }
  }

  Future<void> _startListening() async {
    try {
      if (_connectionType == 0) {
        await _startUdp();
      } else {
        await _startSerial();
      }
    } catch (e) {
      setState(() {
        _status = 'Error connecting: $e';
      });
    }
  }

  Future<void> _startUdp() async {
    final receiverPort = int.parse(_receiverPortController.text);
    final senderPort = int.parse(_senderPortController.text);

    // Setup receiver
    final receiverConfig = UdpConfig(
      localHost: '127.0.0.1',
      localPort: receiverPort,
    );
    _receiver = UdpTransport(receiverConfig);
    await _receiver!.connect();
    _parser.start(_receiver!);

    // Setup sender transport
    final senderConfig = UdpConfig(
      localHost: '127.0.0.1',
      localPort: senderPort,
      remoteHost: _remoteHostController.text,
      remotePort: receiverPort,
    );
    _senderTransport = UdpTransport(senderConfig);
    await _senderTransport!.connect();
    _sender.setTransport(_senderTransport!);

    setState(() {
      _status =
          'UDP Connected - Receiving on port $receiverPort, Sending to ${_remoteHostController.text}:$receiverPort';
      _isConnected = true;
    });
  }

  Future<void> _startSerial() async {
    if (_selectedPort == null) {
      throw Exception('No serial port selected');
    }

    final baudRate = int.parse(_baudRateController.text);

    // Create a single serial transport for both sending and receiving
    _serialTransport = createSerialTransport();
    final config = SerialConfig(baudRate: baudRate);
    await _serialTransport!.open(_selectedPort!, config);

    // Use the serial transport for both parser (receiving) and sender
    _receiver = _serialTransport;
    _senderTransport = _serialTransport;
    _parser.start(_serialTransport!);
    _sender.setTransport(_serialTransport!);

    setState(() {
      _status = 'Serial Connected - $_selectedPort @ $baudRate baud';
      _isConnected = true;
    });
  }

  Future<void> _stopListening() async {
    if (_connectionType == 1 && _serialTransport != null) {
      await _serialTransport!.disconnect();
      await _serialTransport!.dispose();
      _serialTransport = null;
    } else {
      await _receiver?.disconnect();
      await _receiver?.dispose();
      await _senderTransport?.disconnect();
      await _senderTransport?.dispose();
    }
    _receiver = null;
    _senderTransport = null;
    setState(() {
      _status = 'Disconnected';
      _isConnected = false;
    });
  }

  @override
  void dispose() {
    _receiver?.dispose();
    _senderTransport?.dispose();
    _receiverPortController.dispose();
    _senderPortController.dispose();
    _remoteHostController.dispose();
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _isConnected
                              ? Icons.check_circle
                              : Icons.circle_outlined,
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
                    if (!_isConnected) ...[
                      const SizedBox(height: 16),
                      SegmentedButton<int>(
                        segments: const [
                          ButtonSegment<int>(
                            value: 0,
                            label: Text('UDP'),
                            icon: Icon(Icons.lan),
                          ),
                          ButtonSegment<int>(
                            value: 1,
                            label: Text('Serial'),
                            icon: Icon(Icons.usb),
                          ),
                        ],
                        selected: {_connectionType},
                        onSelectionChanged: (Set<int> newSelection) {
                          setState(() {
                            _connectionType = newSelection.first;
                            if (_connectionType == 1 &&
                                _availablePorts.isEmpty) {
                              _refreshSerialPorts();
                            }
                          });
                        },
                      ),
                      const SizedBox(height: 16),
                      if (_connectionType == 0)
                        _buildUdpConfig()
                      else
                        _buildSerialConfig(),
                    ],
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

  Widget _buildUdpConfig() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _remoteHostController,
            decoration: const InputDecoration(
              labelText: 'Remote Host',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 100,
          child: TextField(
            controller: _receiverPortController,
            decoration: const InputDecoration(
              labelText: 'Rx Port',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 100,
          child: TextField(
            controller: _senderPortController,
            decoration: const InputDecoration(
              labelText: 'Tx Port',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
          ),
        ),
      ],
    );
  }

  Widget _buildSerialConfig() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _selectedPort,
                decoration: const InputDecoration(
                  labelText: 'Serial Port',
                  border: OutlineInputBorder(),
                ),
                items: _availablePorts.map((device) {
                  final label = device.description != null
                      ? '${device.portName} (${device.description})'
                      : device.portName;
                  return DropdownMenuItem(
                    value: device.portName,
                    child: Text(label),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedPort = value;
                  });
                },
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _refreshSerialPorts,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh ports',
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 120,
              child: TextField(
                controller: _baudRateController,
                decoration: const InputDecoration(
                  labelText: 'Baud Rate',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
        if (_availablePorts.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'No serial ports found. Click refresh to scan again.',
              style: TextStyle(color: Colors.orange),
            ),
          ),
      ],
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
