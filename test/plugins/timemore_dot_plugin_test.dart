import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import '../helpers/timemore_dot_plugin_fixture.dart';
import 'plugin_test_helpers.dart';

BleAdvertisementEvidence dotEvidence() => BleAdvertisementEvidence(
  name: 'TIMEMORE DOT',
  serviceUuids: const [timemoreDotServiceUuid],
);

Future<Scale> createDotScale(
  PluginManager manager,
  TimemoreDotPluginTransport transport,
  BleAdvertisementEvidence evidence,
) async {
  return await manager.bleService.createCandidate(
        driver: manager.bleService.registry.decide(evidence).drivers.single,
        physicalId: 'AA:BB',
        evidence: evidence,
        admit: () => true,
        createTransport: () => transport,
      )
      as Scale;
}

void main() {
  test('Dot manifest declares the BLE Scale driver and its capabilities', () {
    final driver = timemoreDotManifest().drivers.single;
    expect(driver.id, 'timemore-dot');
    expect(driver.type, PluginDriverType.scale);
    expect(driver.ble, isNotNull);
    expect(driver.capabilities.map((capability) => capability.name).toSet(), {
      'battery',
      'tare',
      'timerControl',
      'timerTelemetry',
      'disconnectToSleep',
    });
  });

  test(
    'Dot connect runs the init sequence and maps weight, battery, timer',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      final controller = ScaleController();
      addTearDown(() async {
        controller.dispose();
        await manager.dispose();
      });
      await loadTimemoreDotPlugin(manager);
      final evidence = dotEvidence();
      final transport = TimemoreDotPluginTransport('AA:BB');
      final scale = await createDotScale(manager, transport, evidence);
      final samples = <WeightSnapshot>[];
      final sampleSubscription = controller.weightSnapshot.listen(samples.add);
      addTearDown(sampleSubscription.cancel);
      final connect = controller.connectToScale(scale);
      await transport.subscribed.future;
      transport.emit(dotAckFrame(0x0D));
      transport.emit(dotBatteryFrame(88));
      transport.emit(dotWeightFrame(12.3, timerSeconds: 7));
      await connect;
      final first = await controller.weightSnapshot.first;
      expect(first.weight, 12.3);
      expect(first.battery, 88);
      expect(samples.last.timerValue, const Duration(seconds: 7));
      expect(transport.writes.map((write) => write.data), [
        timemoreDotCommands['initUnit'],
        timemoreDotCommands['initMode'],
        timemoreDotCommands['initBattery'],
      ]);
      expect(transport.writes.every((write) => write.withResponse), isFalse);
      await scale.disconnect();
    },
  );

  test('Dot reports negative weight and drops a zero timer', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    final controller = ScaleController();
    addTearDown(() async {
      controller.dispose();
      await manager.dispose();
    });
    await loadTimemoreDotPlugin(manager);
    final evidence = dotEvidence();
    final transport = TimemoreDotPluginTransport('AA:BB');
    final scale = await createDotScale(manager, transport, evidence);
    final samples = <WeightSnapshot>[];
    final sampleSubscription = controller.weightSnapshot.listen(samples.add);
    addTearDown(sampleSubscription.cancel);
    final connect = controller.connectToScale(scale);
    await transport.subscribed.future;
    transport.emit(dotWeightFrame(-4.5));
    await connect;
    final first = await controller.weightSnapshot.first;
    expect(first.weight, -4.5);
    expect(first.battery, isNull);
    expect(samples.last.timerValue, isNull);
    await scale.disconnect();
  });

  test(
    'Dot commands are byte-identical to the verified reference frames',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      final controller = ScaleController();
      addTearDown(() async {
        controller.dispose();
        await manager.dispose();
      });
      await loadTimemoreDotPlugin(manager);
      final evidence = dotEvidence();
      final transport = TimemoreDotPluginTransport('AA:BB');
      final scale = await createDotScale(manager, transport, evidence);
      final connect = controller.connectToScale(scale);
      await transport.subscribed.future;
      transport.emit(dotWeightFrame(1.0));
      await connect;
      transport.writes.clear();
      await scale.tare();
      await scale.startTimer();
      await scale.stopTimer();
      await scale.resetTimer();
      expect(transport.writes.map((write) => write.data), [
        timemoreDotCommands['tare'],
        timemoreDotCommands['timerStart'],
        timemoreDotCommands['timerStop'],
        timemoreDotCommands['timerReset'],
      ]);
      await scale.disconnect();
    },
  );

  test('Dot resyncs past a garbage prefix', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    final controller = ScaleController();
    addTearDown(() async {
      controller.dispose();
      await manager.dispose();
    });
    await loadTimemoreDotPlugin(manager);
    final evidence = dotEvidence();
    final transport = TimemoreDotPluginTransport('AA:BB');
    final scale = await createDotScale(manager, transport, evidence);
    final connect = controller.connectToScale(scale);
    await transport.subscribed.future;
    transport.emit([0x11, 0x22, 0x33, ...dotWeightFrame(6.3)]);
    await connect;
    expect((await controller.weightSnapshot.first).weight, 6.3);
    await scale.disconnect();
  });

  test('Dot partial frame never satisfies readiness', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadTimemoreDotPlugin(manager);
    final evidence = dotEvidence();
    final transport = TimemoreDotPluginTransport('AA:BB');
    final scale = await createDotScale(manager, transport, evidence);
    final snapshots = <ScaleSnapshot>[];
    final snapshotSubscription = scale.currentSnapshot.listen(snapshots.add);
    addTearDown(snapshotSubscription.cancel);
    final connect = expectLater(scale.onConnect(), throwsA(anything));
    await transport.subscribed.future;
    final frame = dotWeightFrame(10.0);
    transport.emit(frame.sublist(0, frame.length - 1));
    expect(snapshots, isEmpty);
    await connect;
  });

  test('Dot splits a frame across notifications and reassembles it', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    final controller = ScaleController();
    addTearDown(() async {
      controller.dispose();
      await manager.dispose();
    });
    await loadTimemoreDotPlugin(manager);
    final evidence = dotEvidence();
    final transport = TimemoreDotPluginTransport('AA:BB');
    final scale = await createDotScale(manager, transport, evidence);
    final samples = <WeightSnapshot>[];
    final sampleSubscription = controller.weightSnapshot.listen(samples.add);
    addTearDown(sampleSubscription.cancel);
    final connect = controller.connectToScale(scale);
    await transport.subscribed.future;
    final frame = dotWeightFrame(9.8, timerSeconds: 3);
    transport.emit(frame.sublist(0, 5));
    transport.emit(frame.sublist(5));
    await connect;
    final sample = await controller.weightSnapshot.first;
    expect(sample.weight, 9.8);
    expect(samples.last.timerValue, const Duration(seconds: 3));
    await scale.disconnect();
  });

  test(
    'Dot display sleep disconnects through the disconnectToSleep capability',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      final controller = ScaleController();
      addTearDown(() async {
        controller.dispose();
        await manager.dispose();
      });
      await loadTimemoreDotPlugin(manager);
      final evidence = dotEvidence();
      final transport = TimemoreDotPluginTransport('AA:BB');
      final scale = await createDotScale(manager, transport, evidence);
      final connect = controller.connectToScale(scale);
      await transport.subscribed.future;
      transport.emit(dotWeightFrame(1.0));
      await connect;
      await scale.sleepDisplay();
      expect(transport.disconnectCalls, greaterThan(0));
    },
  );

  test('Dot advertisement without a matching name is not claimed', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadTimemoreDotPlugin(manager);
    final decision = manager.bleService.registry.decide(
      BleAdvertisementEvidence(
        name: 'Acme Sausage',
        serviceUuids: const [timemoreDotServiceUuid],
      ),
    );
    expect(decision.drivers, isEmpty);
  });
}
