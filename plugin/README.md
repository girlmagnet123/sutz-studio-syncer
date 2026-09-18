# Sutz Studio Syncer Plugin

This folder contains the first Studio-side slice of Sutz Studio Syncer.

The plugin connects to a local daemon at `ws://127.0.0.1:8181`, sends a Studio snapshot, and can receive script patches back from the daemon.

## Current Protocol

Studio sends:

- `hello`
- `snapshotStart` (`snapshotId`)
- `snapshotChunk` (`snapshotId`, zero-based `sequence`, `instances`)
- `snapshotEnd` (`snapshotId`, `chunks`, `instanceCount`)
- `messageChunk` (`messageId`, zero-based `sequence`, `total`, UTF-8 `data`)
- `scriptChanged`
- `instanceChanged`
- `instanceRemoved`
- `pong`

Daemon sends:

- `requestSnapshot` (`snapshotBatches: true` and `messageChunks: true` capabilities required)
- `snapshotAck` (`snapshotId`, `sequence`: -1 for start, chunk sequence, or chunk count for end)
- `snapshotError` (`snapshotId`, `error`)
- `patchScript`
- `ping`
- `disconnect`

## Large-place snapshots

Only `Script`, `LocalScript`, and `ModuleScript` instances are included in snapshots
and live updates. Each record carries its full path, so no separate folder, model,
part, keyframe, or pose records are needed. Discovery still looks through arbitrary
containers to find nested scripts. Live listeners are limited to scripts and their
shared ancestors, preserving container rename/move behavior without watching every
object in the place. Script discovery is performed once when connecting; later
snapshots use the script index, with additions/removals maintained by live events.

The plugin walks the instance tree and encodes metadata in batches of at most 200 records and 48 KiB of UTF-8 JSON per WebSocket message, including the envelope. It never constructs a complete snapshot JSON string. Each batch waits for the daemon's acknowledgement, with a 30-second timeout, before sending the next one. A single record that cannot fit reports its path and size instead of silently omitting it.

The daemon commits only after `snapshotEnd` validates every batch and count. An incomplete or rejected metadata transfer does not prune the previously synced files. Script sources are sent individually after that acknowledgement. Any individual JSON message over 48 KiB is sent as ordered `messageChunk` frames with at most 4 KiB of UTF-8 data each; the daemon reconstructs and parses that individual message only when all fragments arrive. This keeps every outgoing frame under 48 KiB even when JSON escaping makes a script larger than 64 KiB. A single exceptionally large script still has its own runtime string and memory limits; the full snapshot is never reassembled into one string. Changes made while syncing are coalesced by instance and replayed from their current state after the snapshot.

Update both the plugin and daemon for this protocol, run `npm run build` in the daemon directory, restart `sutz`, and reload the updated plugin in Studio. The plugin reports an old daemon without batch support instead of falling back to an unbounded snapshot.
