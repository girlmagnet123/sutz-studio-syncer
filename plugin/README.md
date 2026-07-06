# Sutz Studio Syncer Plugin

This folder contains the first Studio-side slice of Sutz Studio Syncer.

The plugin connects to a local daemon at `ws://127.0.0.1:8181`, sends a Studio snapshot, and can receive script patches back from the daemon.

## Current Protocol

Studio sends:

- `hello`
- `snapshot`
- `scriptChanged`
- `instanceChanged`
- `instanceRemoved`
- `pong`

Daemon sends:

- `requestSnapshot`
- `patchScript`
- `ping`
- `disconnect`

## Next Step

Build the local daemon that accepts the WebSocket connection, writes script instances to disk, watches those files, and sends `patchScript` messages back to Studio.
