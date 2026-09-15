import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:reaprime/src/models/device/device.dart' as device;
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';

import 'plugin_ble_fixture.dart';

const timemoreDotPluginPath = 'examples/plugins/timemore-dot.reaplugin';
const timemoreDotServiceUuid = '0000fff0-0000-1000-8000-00805f9b34fb';
const timemoreDotWeightCharacteristicUuid =
    '0000fff1-0000-1000-8000-00805f9b34fb';
const timemoreDotCommandCharacteristicUuid =
    '0000fff2-0000-1000-8000-00805f9b34fb';

PluginManifest timemoreDotManifest() => PluginManifest.fromJson(
  jsonDecode(File('$timemoreDotPluginPath/manifest.json').readAsStringSync()),
);

Future<void> loadTimemoreDotPlugin(PluginManager manager) => manager.loadPlugin(
  id: timemoreDotManifest().id,
  manifest: timemoreDotManifest(),
  settings: {},
  jsCode: File('$timemoreDotPluginPath/plugin.js').readAsStringSync(),
);

/// Command frames byte-identical to the reference driver's verified captures.
/// The notification path does not use these: the Dot firmware leaves the
/// trailing two bytes at `00 00` on every weight and battery notification.
const timemoreDotCommands = <String, List<int>>{
  'tare': [0xA5, 0x5A, 0x03, 0x0D, 0x00, 0x00, 0x64, 0xD1],
  'timerStart': [0xA5, 0x5A, 0x03, 0x02, 0x00, 0x01, 0x01, 0x18, 0x67],
  'timerStop': [0xA5, 0x5A, 0x03, 0x02, 0x00, 0x01, 0x02, 0x19, 0x27],
  'timerReset': [0xA5, 0x5A, 0x03, 0x02, 0x00, 0x01, 0x03, 0xD9, 0xE6],
  'initUnit': [0xA5, 0x5A, 0x03, 0x06, 0x00, 0x01, 0x00, 0xE8, 0xA7],
  'initMode': [0xA5, 0x5A, 0x03, 0x08, 0x00, 0x02, 0x01, 0x00, 0xEB, 0x31],
  'initBattery': [0xA5, 0x5A, 0x02, 0x05, 0x00, 0x00, 0x5A, 0x51],
};

/// Wraps the payload in the `A5 5A` header with the firmware's fixed `00 00`
/// tail, which is what the notify path actually emits.
List<int> dotNotification(int opcode, int cmdId, List<int> payload) => [
  0xA5,
  0x5A,
  opcode,
  cmdId,
  (payload.length >> 8) & 0xFF,
  payload.length & 0xFF,
  ...payload,
  0x00,
  0x00,
];

List<int> dotWeightFrame(double grams, {int timerSeconds = 0}) {
  final tenths = (grams * 10).round();
  final raw = tenths < 0 ? tenths + 0x100000000 : tenths;
  return dotNotification(0x02, 0x01, [
    (raw >> 24) & 0xFF,
    (raw >> 16) & 0xFF,
    (raw >> 8) & 0xFF,
    raw & 0xFF,
    0,
    0,
    (timerSeconds >> 8) & 0xFF,
    timerSeconds & 0xFF,
  ]);
}

List<int> dotBatteryFrame(int percent) =>
    dotNotification(0x02, 0x05, [0, percent]);

List<int> dotAckFrame(int cmdId) => dotNotification(0x03, cmdId, []);

class TimemoreDotPluginTransport extends PluginBleFixtureTransport {
  TimemoreDotPluginTransport(
    super.physicalId, {
    this.firstPacket,
    this.servicePresent = true,
    this.writeFailure,
    this.connectFailure,
  });

  final List<int>? firstPacket;
  final bool servicePresent;
  final Object? writeFailure;
  final Object? connectFailure;

  final acquisitionStarted = Completer<void>();
  final subscribed = Completer<void>();
  int discoverServicesCalls = 0;

  @override
  Future<void> connect() async {
    connectCalls++;
    if (!acquisitionStarted.isCompleted) acquisitionStarted.complete();
    if (connectFailure != null) {
      states.add(device.ConnectionState.disconnected);
      throw connectFailure!;
    }
    states.add(device.ConnectionState.connected);
  }

  @override
  Future<List<String>> discoverServices() async {
    discoverServicesCalls++;
    return servicePresent ? [timemoreDotServiceUuid] : [];
  }

  @override
  Future<void> subscribe(
    String service,
    String characteristic,
    void Function(Uint8List) callback,
  ) async {
    if (service != timemoreDotServiceUuid ||
        characteristic != timemoreDotWeightCharacteristicUuid) {
      throw StateError('Unexpected Dot subscription $service/$characteristic');
    }
    subscribers[characteristic] = callback;
    if (firstPacket != null) callback(Uint8List.fromList(firstPacket!));
    if (!subscribed.isCompleted) subscribed.complete();
  }

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    if (serviceUUID != timemoreDotServiceUuid ||
        characteristicUUID != timemoreDotCommandCharacteristicUuid) {
      throw StateError('Unexpected Dot write $serviceUUID/$characteristicUUID');
    }
    if (writeFailure != null) throw writeFailure!;
    await super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
  }

  void emit(List<int> frame) =>
      subscribers[timemoreDotWeightCharacteristicUuid]!(
        Uint8List.fromList(frame),
      );
}
