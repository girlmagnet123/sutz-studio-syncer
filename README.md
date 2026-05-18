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

For development, `npm run dev` still runs the TypeScript source directly.
