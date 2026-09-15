# Tests

These tests live here because the driver owns its protocol coverage, but they
**cannot run standalone**: they exercise the plugin through Decaid's shared
plugin harness, not a copy of it.

The imports resolve against a Decaid checkout, not this repository:

- `../helpers/plugin_ble_fixture.dart` — the fake BLE transport and platform
- `plugin_test_helpers.dart` — `FakeKeyValueStoreService` and manifest helpers

Both belong to Decaid's test tree because other plugin tests use them too, and
duplicating them here would drift.

## Running

From a Decaid checkout, overlay this directory onto its `test/` tree and run
the suite there:

```bash
cp -r test/helpers/timemore_dot_plugin_fixture.dart <decaid>/test/helpers/
cp -r test/plugins/timemore_dot_plugin_test.dart    <decaid>/test/plugins/
cd <decaid> && flutter test test/plugins/timemore_dot_plugin_test.dart
```

The plugin source is read from `examples/plugins/timemore-dot.reaplugin/` by
relative path, so the copy must sit beside that directory. Keep the two in sync
when either changes — `scripts/package.sh` in this repository builds the
released archive from `timemore-dot.reaplugin/`, and the Decaid copy is what the
tests load.

## What the fixture covers

`timemore_dot_plugin_fixture.dart` builds notification frames with the
firmware's fixed `00 00` tail — the notify path carries no checksum — and pins
the seven command frames against the verified reference bytes, so a regression
in the CRC-16 initial value fails here rather than only against hardware.
