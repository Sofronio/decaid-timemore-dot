# Timemore Dot for Decaid

A [Decaid](https://github.com/decentespresso/decaid) plugin that adds the
Timemore Dot (TES017) BLE scale. The plugin owns the device protocol; Decaid
owns discovery, the BLE connection lifecycle, and the Scale surface.

No Decaid release is needed to use this, and none is needed to add support for
another device.

## Install

From the Decaid REST API, which installs the repository's latest release:

```bash
curl -X POST http://localhost:8080/api/v1/plugins/install/github-release \
  -H 'content-type: application/json' \
  -d '{"repo": "Sofronio/decaid-timemore-dot"}'
```

Or open the Plugins settings screen in Decaid and install from the repository.

Once installed, the plugin matches a Dot advertisement and exposes it through
the normal Scale APIs and WebSocket. The public device ID is
`plugin:timemore-dot.reaplugin:timemore-dot:<physical id>`.

## What the driver matches

An advertisement whose name contains `dot` (case-insensitive) that also
advertises service `FFF0`. Both constraints are required, so a Dot advertising
`FFF0` with no name — which it does outside pairing mode — is left to Decaid's
native matching rather than claimed here.

## Protocol

Frames are `A5 5A`-framed: opcode, command id, a big-endian payload length, the
payload, and a two-byte tail.

Command frames carry CRC-16 with initial value `0xFFFF` (reflected polynomial
`0xA001`, no final XOR). Notification frames do not — the firmware leaves the
tail at `00 00` on every weight and battery notification, so the notify path
trusts the header and length field alone. A consequence worth knowing is that
abutting fragments can reassemble into a frame the driver accepts, because
there is no checksum to reject it.

| Command | Frame |
| --- | --- |
| Tare | `A5 5A 03 0D 00 00 64 D1` |
| Timer start | `A5 5A 03 02 00 01 01 18 67` |
| Timer stop | `A5 5A 03 02 00 01 02 19 27` |
| Timer reset | `A5 5A 03 02 00 01 03 D9 E6` |
| Init unit (gram) | `A5 5A 03 06 00 01 00 E8 A7` |
| Init mode (standard) | `A5 5A 03 08 00 02 01 00 EB 31` |
| Init battery request | `A5 5A 02 05 00 00 5A 51` |

Weight notifications carry a signed big-endian 32-bit value in tenths of a gram
and the running timer in seconds; battery notifications report a percentage.
Commands are written without a response, because the Dot acknowledges over
`FFF1` notifications rather than the write itself. Weight resolution is 0.1 g.

Display sleep disconnects through the `disconnectToSleep` capability rather
than sending the protocol's power-off command, so the machine waking can
reconnect the scale automatically instead of requiring a button press.

The protocol follows Timemore's published specification,
[open-scale-protocol](https://github.com/TIMEMORE-COFFEE/open-scale-protocol/) —
`Timemore Black Mirror SCALE BLE Protocol` v1.0.3, in which the Dot is device
type `01`. The `0x08` mode command sent during initialization is not in the
published command table; it comes from a reference driver and is retained
because hardware accepts it.

## Releasing

`scripts/package.sh` builds `dist/timemore-dot.reaplugin-<version>.zip`.
Pushing a `vX.Y.Z` tag runs the same script in CI and publishes the release.

Decaid enforces three things the script keeps in sync:

- the release tag is `X.Y.Z` or `vX.Y.Z` and equals `manifest.version` exactly
- the release carries exactly one `.zip` asset
- the archive holds a single top-level `timemore-dot.reaplugin/` directory
  containing `manifest.json` and `plugin.js`

So bump `manifest.version` and tag the same version. A release whose tag and
manifest disagree is rejected at install time.

## Verified against hardware

Discovery claims the advertisement, connect completes the subscribe and init
sequence, and weight, battery, and timer telemetry stream at the firmware's
reporting cadence. Tare and timer start both reached a physical Dot, confirmed
by the weight returning to zero and the reported timer advancing.

## License

Not yet chosen. Until one is added, this repository is all rights reserved by
default.
