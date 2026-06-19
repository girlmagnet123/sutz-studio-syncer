# Sutz Studio Syncer

Sutz Studio Syncer is a Roblox Studio to filesystem sync experiment inspired by the broad shape of Azul, but implemented as its own project.

## Build Order

1. Studio plugin: connects from Roblox Studio to a local daemon and sends snapshots/changes.
2. Local daemon: receives Studio messages, writes scripts to disk, watches file edits, and patches Studio.
3. Sourcemap support: emits a Luau-LSP friendly map of the Studio tree.
4. Build/push commands: one-shot filesystem to Studio workflows.

## Current State

The initial Studio plugin scaffold lives in `plugin/src`.

It can:

- Create a Studio toolbar button.
- Connect to `ws://localhost:8181`.
- Send an initial Studio snapshot.
- Send script, instance, and removal messages.
- Receive `patchScript` messages and apply source through `ScriptEditorService`.

The daemon can:

- Start a local WebSocket server on `127.0.0.1:8181`.
- Create a `sync` folder in the project where `sutz` is run.
- Write Studio script snapshots into `sync`.
- Update or remove synced script files when Studio sends changes.
- Create or update Studio scripts when new `.luau` files are added under `sync`
  while Studio is connected.

## Local Command

Install dependencies and register the local `sutz` command:

```powershell
npm install
npm link
```

Then start the daemon with:

```powershell
sutz
```

By default, `sutz` writes generated Studio scripts to `./sync`. To use a different folder:

```powershell
$env:SUTZ_SYNC_DIR = "my-sync-folder"
sutz
```

## Multiple Studios

Each `sutz` daemon pairs with exactly one Studio. To sync several Studios at once,
run `sutz` in several terminals (typically one per project folder): the first binds
port `8181`, the next free port up to `8181 + SUTZ_PORT_SCAN - 1` (default 10).

When you press **Connect** in the plugin, it probes those ports over HTTP and pairs
with the first daemon that has no Studio attached, so a second Studio automatically
lands on a second daemon instead of stealing the first one. A daemon that is already
paired rejects new connections with a `busy` message. Override the base port with
`SUTZ_PORT` and the scan width with `SUTZ_PORT_SCAN`.

For development, `npm run dev` still runs the TypeScript source directly.

## Filesystem to Studio

When Studio is connected, files created inside the sync folder are pushed into
Studio using their path and suffix:

- `sync/ServerScriptService/MyScript.server.luau` creates a `Script`.
- `sync/StarterPlayer/StarterPlayerScripts/MyClient.client.luau` creates a `LocalScript`.
- `sync/ReplicatedStorage/Modules/MyModule.luau` creates a `ModuleScript`.

Missing intermediate folders are created as `Folder` instances. A Studio
snapshot is still authoritative: each manual snapshot removes files from the
sync folder when they no longer exist in Studio, keeping the folder 1:1 with
the current Studio tree.
