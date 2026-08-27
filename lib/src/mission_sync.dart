import 'dart:async';

import 'parser.dart';
import 'sender.dart';

/// One waypoint sent with the `gcs_mission_single` packet.
class MissionItem {
  const MissionItem({
    required this.waypointNumber,
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.speed,
    required this.mode,
    required this.param,
  });

  final int waypointNumber;
  final double latitude;
  final double longitude;
  final double altitude;
  final int speed;
  final int mode;
  final int param;

  Map<String, dynamic> toPacketData() => <String, dynamic>{
    'waypoint_number': waypointNumber,
    'waypoint_latitude': latitude,
    'waypoint_longitude': longitude,
    'waypoint_altitude': altitude,
    'waypoint_speed': speed,
    'waypoint_mode': mode,
    'waypoint_param': param,
  };

  factory MissionItem.fromPacketData(Map<String, dynamic> data) {
    return MissionItem(
      waypointNumber: (data['waypoint_number'] as num).toInt(),
      latitude: (data['waypoint_latitude'] as num).toDouble(),
      longitude: (data['waypoint_longitude'] as num).toDouble(),
      altitude: (data['waypoint_altitude'] as num).toDouble(),
      speed: (data['waypoint_speed'] as num).toInt(),
      mode: (data['waypoint_mode'] as num).toInt(),
      param: (data['waypoint_param'] as num).toInt(),
    );
  }
}

/// Outcome of sending and verifying one [MissionItem].
class MissionSyncResult {
  const MissionSyncResult({
    required this.item,
    required this.sent,
    required this.matched,
    required this.attempts,
    this.receivedItem,
    this.error,
  });

  final MissionItem item;
  final bool sent;
  final bool matched;
  final int attempts;
  final MissionItem? receivedItem;
  final String? error;

  bool get success => sent && matched;
}

/// Sends mission items sequentially and waits for a matching AP echo after
/// every item. The upload stops as soon as an item cannot be verified.
class MissionSync {
  MissionSync({
    required this.sender,
    required this.parser,
    required Iterable<MissionItem> missionItems,
    this.timeout = const Duration(seconds: 2),
    this.maxRetries = 3,
    this.coordinateEpsilon = 1e-5,
    this.altitudeEpsilon = 1e-3,
  }) : missionItems = List<MissionItem>.unmodifiable(missionItems) {
    if (maxRetries < 1) {
      throw ArgumentError.value(maxRetries, 'maxRetries', 'must be at least 1');
    }
  }

  final BinaryPacketSender sender;
  final BinaryParser parser;

  /// Items are sent in this list's order. Their packet waypoint numbers are
  /// assigned from zero and packet params contain the total mission size.
  final List<MissionItem> missionItems;
  final Duration timeout;

  /// Maximum send attempts for each item, including the initial attempt.
  final int maxRetries;

  /// Absolute comparison tolerance for double-precision coordinates.
  final double coordinateEpsilon;

  /// Absolute comparison tolerance for the float32 altitude field.
  final double altitudeEpsilon;

  static const String gcsSchemaName = 'gcs_mission_single';
  static const String apSchemaName = 'ap_mission_single';

  /// Sends and verifies each item. If an item fails, its failure is included
  /// as the last result and no later item is sent.
  Future<List<MissionSyncResult>> syncAll({
    FutureOr<void> Function(MissionSyncResult result, int processed, int total)?
    onResult,
  }) async {
    final results = <MissionSyncResult>[];

    for (
      var waypointNumber = 0;
      waypointNumber < missionItems.length;
      waypointNumber++
    ) {
      final source = missionItems[waypointNumber];
      final item = MissionItem(
        waypointNumber: waypointNumber,
        latitude: source.latitude,
        longitude: source.longitude,
        altitude: source.altitude,
        speed: source.speed,
        mode: source.mode,
        param: missionItems.length,
      );
      final result = await _syncOne(item);
      results.add(result);
      await onResult?.call(result, results.length, missionItems.length);
      if (!result.success) break;
    }

    return results;
  }

  Future<MissionSyncResult> _syncOne(MissionItem item) async {
    MissionItem? receivedItem;
    String? error;

    for (var attempts = 1; attempts <= maxRetries; attempts++) {
      final echoCompleter = Completer<Map<String, dynamic>>();
      final echoSubscription = parser.onParsedData.listen((data) {
        if (!echoCompleter.isCompleted &&
            data['schemaId'] == apSchemaName &&
            data['waypoint_number'] == item.waypointNumber) {
          echoCompleter.complete(data);
        }
      });

      try {
        await sender.send(
          schemaName: gcsSchemaName,
          messageId: sender.messageIdForSchema(gcsSchemaName),
          data: item.toPacketData(),
        );
      } catch (e) {
        await echoSubscription.cancel();
        return MissionSyncResult(
          item: item,
          sent: false,
          matched: false,
          attempts: attempts,
          error: 'send_failed: $e',
        );
      }

      try {
        final response = await echoCompleter.future.timeout(timeout);
        receivedItem = MissionItem.fromPacketData(response);
        if (_itemsMatch(item, receivedItem)) {
          return MissionSyncResult(
            item: item,
            sent: true,
            matched: true,
            attempts: attempts,
            receivedItem: receivedItem,
          );
        }
        error = 'value_mismatch';
      } on TimeoutException {
        error = 'timeout';
      } finally {
        await echoSubscription.cancel();
      }
    }

    return MissionSyncResult(
      item: item,
      sent: true,
      matched: false,
      attempts: maxRetries,
      receivedItem: receivedItem,
      error: error,
    );
  }

  bool _itemsMatch(MissionItem sent, MissionItem received) {
    return sent.waypointNumber == received.waypointNumber &&
        (sent.latitude - received.latitude).abs() <= coordinateEpsilon &&
        (sent.longitude - received.longitude).abs() <= coordinateEpsilon &&
        (sent.altitude - received.altitude).abs() <= altitudeEpsilon &&
        sent.speed == received.speed &&
        sent.mode == received.mode &&
        sent.param == received.param;
  }
}
