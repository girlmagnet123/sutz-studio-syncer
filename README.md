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
- Connect to `ws://127.0.0.1:8181`.
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

Leave the plugin's WebSocket URI set to the base URL, usually
`ws://127.0.0.1:8181`. The plugin shows the actual paired daemon after it connects
but does not save that paired port as the new base, so every Studio can keep the
same setting and auto-pair with daemon `8181`, `8182`, `8183`, and so on.

For development, `npm run dev` still runs the TypeScript source directly.

## Updating the syncer

After changing the daemon's TypeScript, stop the running daemon, run `npm run build`,
then start `sutz` again. Updating GitHub does not rebuild a running local daemon.
Changes under `plugin/src` also need to be installed in the Studio plugin; restart
Studio after replacing its local plugin file.

To package updated plugin sources with the Fusion library and assets from your
installed plugin, run `npm run build:plugin`. This writes
`dist/SutzStudioSyncerPlugin.rbxmx`. The builder accepts an explicit template with
`powershell -File scripts/build-plugin.ps1 -TemplatePath <existing-plugin.rbxmx>`.
Replace the installed local plugin with the generated file and restart Studio.
Publishing to Roblox is only necessary when distributing the plugin to other users.

### WebSocket frame errors

`WS_ERR_UNEXPECTED_RSV_1` means the receiver found an unexpected reserved/compression
bit in a WebSocket frame, before parsing any sync JSON. If no compression extension
was negotiated, compressed frames are invalid; malformed framing can produce the
same error. This error alone does not establish a plugin version mismatch.
`WS_ERR_UNEXPECTED_RSV_2_3` also indicates invalid reserved bits in the incoming
framing; it does not establish that the configured URL is wrong.

The daemon logs the offered and negotiated extensions and the byte size of the last
complete message for both errors. Rebuild and restart `sutz` to use these diagnostics.
Compare `plugin/src` with both the Studio plugin source and its installed local
plugin file when investigating version differences; editing a model in
`ServerStorage` does not reload the installed plugin. Keep WebSocket frame validation
enabled, and use the diagnostic details to establish the cause before changing
compression settings. An incomplete snapshot is discarded when its socket fails;
the last committed sync files are preserved.

## Large snapshots

The plugin sends only `Script`, `LocalScript`, and `ModuleScript` records and their
full paths. Parts, folders, models, keyframes, poses, and other objects are not
serialized. Scripts nested inside any of those objects are still discovered.
Only scripts and the ancestors needed to detect path changes are watched; renaming
or moving a container updates the paths of its tracked scripts. Discovery scans
each selected service once, then snapshots use the script index.

The plugin streams script metadata in batches of at most 48 KiB minus 64 bytes and 200 records,
waiting for the daemon to acknowledge each batch before sending the next one.
The daemon processes each batch separately and keeps records as objects; it never
reassembles the whole place into a JSON string. It only removes stale sync files
after every batch and the final record count have been received successfully.
Interrupted or invalid metadata transfers leave the previous synced files intact.

Update both the daemon and the Studio plugin together. An older daemon that does
not support batches is rejected with an update message. Script sources are sent
individually after the metadata transfer. Individual updates larger than 48 KiB
are split into UTF-8-safe `messageChunk` envelopes before being sent; the daemon
reassembles only that one update, never the entire place snapshot. This also keeps
large script messages out of the WebSocket 64-bit payload-length encoding.

Every outgoing wire message after the initial hello now also waits for a
`messageAck` from the daemon. The 64-byte reserve keeps the added transport sequence
inside the 48 KiB limit. Only one wire message is outstanding at a time, including
fragments of large script sources. A single worker keeps logical messages ordered,
so live edits cannot interleave with a fragmented source while waiting. Pending
encoded messages are capped at 64 MiB, and a 30-second ACK timeout closes the
connection and releases waiting senders. Native socket errors are forwarded to
the plugin UI. `Send()` returning successfully only queues data in Roblox; the
transport acknowledgement confirms the daemon received it.

Update both sides for this version: the plugin requires the daemon's `messageAcks`
capability. The daemon still accepts older plugins, but they retain their old send
behavior. Transport ACKs do not replace snapshot validation or mean a complete
snapshot has committed.

Run `npm test` to build and run the transport regression checks, including an
11.4 MiB Unicode script transfer and malformed-frame recovery. The separate
`scripts/check-plugin-flow-control.luau` harness exercises the plugin with mocked
sockets in Studio Edit mode, without networking or a play session.

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
