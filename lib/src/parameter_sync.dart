import 'dart:async';

import 'parameters.dart';
import 'parser.dart';
import 'sender.dart';

/// Outcome of attempting to sync a single [Parameter].
class ParameterSyncResult {
  ParameterSyncResult({
    required this.parameter,
    required this.sent,
    required this.matched,
    required this.attempts,
    this.receivedValue,
    this.error,
  });

  /// The parameter that was being synchronized.
  final Parameter parameter;

  /// Whether the GCS packet was successfully sent over the transport.
  final bool sent;

  /// Whether the AP echo matched the sent Group + Key + Value.
  final bool matched;

  /// Number of send attempts made (1..maxRetries).
  final int attempts;

  /// The Value field echoed back by the AP, if a response was received.
  final double? receivedValue;

  /// A short error reason when the parameter did not match
  /// (e.g. 'timeout', 'value_mismatch', 'send_failed: ...').
  final String? error;

  /// True when the parameter was both sent and matched.
  bool get success => sent && matched;

  @override
  String toString() {
    final g = parameter.group.toInt();
    final k = parameter.key.toInt();
    final title = parameter.title;
    return 'ParameterSyncResult($title G=$g K=$k '
        'sent=$sent matched=$matched attempts=$attempts '
        'received=$receivedValue error=$error)';
  }
}

/// Orchestrates sending every [Parameter] in a [Parameters] collection to the
/// flight controller one at a time, waiting for the matching AP echo, and
/// verifying that the echoed Group + Key + Value match what was sent.
///
/// The caller is responsible for wiring the transports:
///   - `sender.setTransport(gcsTransport)` (GCS -> AP direction)
///   - `parser.start(apTransport)`        (AP -> GCS direction)
/// and for loading the relevant schemas:
///   - sender: `schema_output/` (contains `gcs_parameter_single`)
///   - parser: `schema_input/`  (contains `ap_parameter_single`)
class ParameterSync {
  ParameterSync({
    required this.sender,
    required this.parser,
    required this.parameters,
    this.timeout = const Duration(seconds: 2),
    this.maxRetries = 3,
    this.valueEpsilon = 1e-6,
  });

  final BinaryPacketSender sender;
  final BinaryParser parser;
  final Parameters parameters;

  /// How long to wait for an AP echo before retrying.
  final Duration timeout;

  /// Maximum number of send attempts per parameter before giving up.
  final int maxRetries;

  /// Absolute tolerance used when comparing the echoed Value to the sent one.
  final double valueEpsilon;

  /// Name of the GCS (output) schema used to send a parameter.
  static const String gcsSchemaName = 'gcs_parameter_single';

  /// Name of the AP (input) schema emitted by the parser for an echo.
  static const String apSchemaName = 'ap_parameter_single';

  /// Sends every parameter in [parameters] one at a time.
  ///
  /// For each parameter:
  ///   1. Subscribe to [BinaryParser.onParsedData] filtering by the AP schema
  ///      and the parameter's Group + Key.
  ///   2. Send the GCS parameter packet.
  ///   3. Wait for the echo up to [timeout].
  ///   4. On a matching echo (Group + Key + Value within [valueEpsilon]) record
  ///      success and move on.
  ///   5. On a value mismatch or timeout, retry up to [maxRetries] times.
  ///   6. If retries are exhausted, record the failure and continue to the
  ///      next parameter (the loop is never aborted by a single failure).
  Future<List<ParameterSyncResult>> syncAll() async {
    final results = <ParameterSyncResult>[];

    for (final parameter in parameters.params) {
      results.add(await _syncOne(parameter));
    }

    return results;
  }

  Future<ParameterSyncResult> _syncOne(Parameter parameter) async {
    final group = parameter.group.toInt();
    final key = parameter.key.toInt();
    final sentValue = parameter.value;

    int attempts = 0;
    double? receivedValue;
    String? error;

    while (attempts < maxRetries) {
      attempts++;

      // Subscribe BEFORE sending: onParsedData is a broadcast stream, so a
      // future captured now will see the next matching event.
      final Future<Map<String, dynamic>> echoFuture = parser.onParsedData
          .firstWhere(
            (m) =>
                m['schemaId'] == apSchemaName &&
                m['Group'] == group &&
                m['Key'] == key,
          );

      try {
        await sender.send(
          schemaName: gcsSchemaName,
          data: {'Group': group, 'Key': key, 'Value': sentValue},
        );
      } catch (e) {
        // Send failed — no point waiting for an echo. Record and stop retrying
        // this parameter, but let the overall loop continue.
        return ParameterSyncResult(
          parameter: parameter,
          sent: false,
          matched: false,
          attempts: attempts,
          error: 'send_failed: $e',
        );
      }

      try {
        final response = await echoFuture.timeout(timeout);
        receivedValue = (response['Value'] as num?)?.toDouble();

        if (_valuesMatch(sentValue, receivedValue)) {
          return ParameterSyncResult(
            parameter: parameter,
            sent: true,
            matched: true,
            attempts: attempts,
            receivedValue: receivedValue,
          );
        }

        // Value mismatch — retry.
        error = 'value_mismatch';
      } on TimeoutException {
        // No echo in time — retry.
        error = 'timeout';
      }
    }

    // Exhausted retries.
    return ParameterSyncResult(
      parameter: parameter,
      sent: true,
      matched: false,
      attempts: attempts,
      receivedValue: receivedValue,
      error: error,
    );
  }

  bool _valuesMatch(double sent, double? received) {
    if (received == null) return false;
    return (sent - received).abs() <= valueEpsilon;
  }
}
