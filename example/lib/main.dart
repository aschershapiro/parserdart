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

  // Parameter sync state
  Parameters? _parameters;
  List<ParameterSyncResult> _syncResults = [];
  bool _isSyncing = false;
  int _syncProgress = 0; // number of parameters processed so far
  String _syncStatus = 'Parameters not loaded';

  // Mission sync state. Replace these sample items with the mission created by
  // your application before calling MissionSync.
  final List<MissionItem> _missionItems = const [
    MissionItem(
      waypointNumber: 1,
      latitude: 35.6892,
      longitude: 51.3890,
      altitude: 120,
      speed: 20,
      mode: 0,
      param: 0,
    ),
    MissionItem(
      waypointNumber: 2,
      latitude: 35.6900,
      longitude: 51.3910,
      altitude: 140,
      speed: 25,
      mode: 0,
      param: 0,
    ),
    MissionItem(
      waypointNumber: 3,
      latitude: 35.6885,
      longitude: 51.3930,
      altitude: 120,
      speed: 20,
      mode: 0,
      param: 0,
    ),
  ];
  List<MissionSyncResult> _missionSyncResults = [];
  bool _isMissionSyncing = false;
  int _missionSyncProgress = 0;
  String _missionSyncStatus = 'Mission ready to sync';

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
      // Load the parameter definitions
      _parameters = Parameters.fromJson(
        '../lib/src/schema_params/parameters.json',
      );
      setState(() {
        _status = 'Schemas loaded. Ready to connect.';
        _syncStatus =
            '${_parameters!.params.length} parameters loaded. '
            'Connect and press "Sync All" to send them one by one.';
      });
    } catch (e) {
      setState(() {
        _status = 'Error loading schemas: $e';
        _syncStatus = 'Failed to load parameters: $e';
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
                ButtonSegment<int>(
                  value: 2,
                  label: Text('Param Sync'),
                  icon: Icon(Icons.sync),
                ),
                ButtonSegment<int>(
                  value: 3,
                  label: Text('Mission Sync'),
                  icon: Icon(Icons.route),
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
              child: _tabIndex == 0
                  ? _buildReceiverView()
                  : _tabIndex == 1
                  ? _buildSenderView()
                  : _tabIndex == 2
                  ? _buildParamSyncView()
                  : _buildMissionSyncView(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _syncAllParameters() async {
    if (_parameters == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Parameters not loaded')));
      return;
    }
    if (!_isConnected) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please connect first')));
      return;
    }

    setState(() {
      _isSyncing = true;
      _syncResults = [];
      _syncProgress = 0;
      _syncStatus = 'Syncing parameters...';
    });

    final sync = ParameterSync(
      sender: _sender,
      parser: _parser,
      parameters: _parameters!,
      timeout: const Duration(seconds: 2),
      maxRetries: 3,
    );

    final results = await sync.syncAll(
      onResult: (result, processed, total) async {
        if (!mounted) return;

        setState(() {
          _syncResults = [..._syncResults, result];
          _syncProgress = processed;
          final matched = _syncResults.where((r) => r.matched).length;
          _syncStatus =
              'Syncing parameters... $processed/$total processed, '
              '$matched matched.';
        });

        await WidgetsBinding.instance.endOfFrame;
      },
    );

    if (!mounted) return;
    final matched = results.where((r) => r.matched).length;
    setState(() {
      _syncResults = results;
      _syncProgress = results.length;
      _isSyncing = false;
      _syncStatus =
          'Done: $matched/${results.length} parameters confirmed. '
          '${results.length - matched} failed.';
    });
  }

  Widget _buildParamSyncView() {
    if (_parameters == null) {
      return Center(child: Text(_syncStatus));
    }

    final total = _parameters!.params.length;
    final matched = _syncResults.where((r) => r.matched).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header + sync button
        Row(
          children: [
            Expanded(
              child: Text(
                'Parameter Sync ($total params)',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (_isSyncing)
              const Padding(
                padding: EdgeInsets.only(right: 12),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ElevatedButton.icon(
              onPressed: _isSyncing || _isMissionSyncing || !_isConnected
                  ? null
                  : _syncAllParameters,
              icon: const Icon(Icons.sync),
              label: const Text('Sync All'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(_syncStatus, style: Theme.of(context).textTheme.bodySmall),
        if (_isSyncing || _syncResults.isNotEmpty) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: total == 0 ? 0 : _syncProgress / total,
          ),
          const SizedBox(height: 4),
          Text(
            '$_syncProgress / $total'
            '${_syncResults.isNotEmpty ? "  •  $matched matched" : ""}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 16),
        // Results / parameter list
        Expanded(
          child: _syncResults.isEmpty
              ? _buildParameterPreview(total)
              : _buildResultsList(),
        ),
      ],
    );
  }

  /// Shows the loaded parameters before a sync has been run.
  Widget _buildParameterPreview(int total) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Loaded parameters (preview):',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: total,
            itemBuilder: (context, index) {
              final p = _parameters!.params[index];
              return ListTile(
                dense: true,
                leading: CircleAvatar(radius: 14, child: Text('${index + 1}')),
                title: Text(p.title),
                subtitle: Text(
                  'G=${p.group.toInt()} K=${p.key.toInt()} '
                  'type=${p.type} value=${p.value}',
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Shows the per-parameter outcome after a sync run.
  Widget _buildResultsList() {
    return ListView.builder(
      itemCount: _syncResults.length,
      itemBuilder: (context, index) {
        final r = _syncResults[index];
        final p = r.parameter;
        final icon = r.matched
            ? Icons.check_circle
            : r.sent
            ? Icons.error_outline
            : Icons.cancel;
        final color = r.matched
            ? Colors.green
            : r.sent
            ? Colors.orange
            : Colors.red;
        return ListTile(
          leading: Icon(icon, color: color),
          title: Text(p.title),
          subtitle: Text(
            'G=${p.group.toInt()} K=${p.key.toInt()} '
            'sent=${p.value.toStringAsFixed(3)} '
            'recv=${r.receivedValue?.toStringAsFixed(3) ?? "—"} '
            'attempts=${r.attempts}'
            '${r.error != null ? "  err=${r.error}" : ""}',
          ),
        );
      },
    );
  }

  Future<void> _syncMission() async {
    if (_missionItems.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Mission is empty')));
      return;
    }
    if (!_isConnected) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please connect first')));
      return;
    }

    setState(() {
      _isMissionSyncing = true;
      _missionSyncResults = [];
      _missionSyncProgress = 0;
      _missionSyncStatus = 'Syncing mission...';
    });

    try {
      final results =
          await MissionSync(
            sender: _sender,
            parser: _parser,
            missionItems: _missionItems,
            timeout: const Duration(seconds: 2),
            maxRetries: 3,
          ).syncAll(
            onResult: (result, processed, total) async {
              if (!mounted) return;

              setState(() {
                _missionSyncResults = [..._missionSyncResults, result];
                _missionSyncProgress = processed;
                final matched = _missionSyncResults
                    .where((result) => result.matched)
                    .length;
                _missionSyncStatus = result.success
                    ? 'Syncing mission... $processed/$total processed, '
                          '$matched matched.'
                    : 'Mission stopped at waypoint '
                          '${result.item.waypointNumber}: ${result.error}.';
              });

              await WidgetsBinding.instance.endOfFrame;
            },
          );

      if (!mounted) return;
      final matched = results.where((result) => result.matched).length;
      final failure = results.where((result) => !result.success).firstOrNull;
      setState(() {
        _missionSyncResults = results;
        _missionSyncProgress = results.length;
        _isMissionSyncing = false;
        _missionSyncStatus = failure == null
            ? 'Done: all $matched mission items confirmed.'
            : 'Stopped at waypoint ${failure.item.waypointNumber}: '
                  '${failure.error}. $matched/${_missionItems.length} '
                  'mission items confirmed.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isMissionSyncing = false;
        _missionSyncStatus = 'Mission sync failed: $e';
      });
    }
  }

  Widget _buildMissionSyncView() {
    final total = _missionItems.length;
    final matched = _missionSyncResults
        .where((result) => result.matched)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Mission Sync ($total waypoints)',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (_isMissionSyncing)
              const Padding(
                padding: EdgeInsets.only(right: 12),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ElevatedButton.icon(
              onPressed: _isMissionSyncing || _isSyncing || !_isConnected
                  ? null
                  : _syncMission,
              icon: const Icon(Icons.sync),
              label: const Text('Sync Mission'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(_missionSyncStatus, style: Theme.of(context).textTheme.bodySmall),
        if (_isMissionSyncing || _missionSyncResults.isNotEmpty) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: total == 0 ? 0 : _missionSyncProgress / total,
          ),
          const SizedBox(height: 4),
          Text(
            '$_missionSyncProgress / $total'
            '${_missionSyncResults.isNotEmpty ? "  •  $matched matched" : ""}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 16),
        Expanded(
          child: _missionSyncResults.isEmpty
              ? _buildMissionPreview()
              : _buildMissionResults(),
        ),
      ],
    );
  }

  Widget _buildMissionPreview() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Loaded mission (preview):',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: _missionItems.length,
            itemBuilder: (context, index) {
              final item = _missionItems[index];
              return ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 14,
                  child: Text('${item.waypointNumber}'),
                ),
                title: Text('Waypoint ${item.waypointNumber}'),
                subtitle: Text(
                  'lat=${item.latitude.toStringAsFixed(6)} '
                  'lon=${item.longitude.toStringAsFixed(6)} '
                  'alt=${item.altitude.toStringAsFixed(1)}  '
                  'speed=${item.speed} mode=${item.mode} param=${item.param}',
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMissionResults() {
    return ListView.builder(
      itemCount: _missionSyncResults.length,
      itemBuilder: (context, index) {
        final result = _missionSyncResults[index];
        final item = result.item;
        final received = result.receivedItem;
        final icon = result.matched
            ? Icons.check_circle
            : result.sent
            ? Icons.error_outline
            : Icons.cancel;
        final color = result.matched
            ? Colors.green
            : result.sent
            ? Colors.orange
            : Colors.red;

        return ListTile(
          leading: Icon(icon, color: color),
          title: Text('Waypoint ${item.waypointNumber}'),
          subtitle: Text(
            'sent: ${_missionItemSummary(item)}\n'
            'echo: ${received == null ? "—" : _missionItemSummary(received)}  '
            'attempts=${result.attempts}'
            '${result.error != null ? "  err=${result.error}" : ""}',
          ),
          isThreeLine: true,
        );
      },
    );
  }

  String _missionItemSummary(MissionItem item) {
    return '${item.latitude.toStringAsFixed(6)}, '
        '${item.longitude.toStringAsFixed(6)}, '
        'alt=${item.altitude.toStringAsFixed(1)}, speed=${item.speed}, '
        'mode=${item.mode}, param=${item.param}';
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
                initialValue: _selectedPort,
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
