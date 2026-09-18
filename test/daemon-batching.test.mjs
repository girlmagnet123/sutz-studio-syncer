import assert from "node:assert/strict";
import { EventEmitter, once } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { WebSocket } from "ws";
import { SutzDaemon } from "../dist/daemon.js";

class FakeSocket extends EventEmitter {
  readyState = WebSocket.OPEN;
  messages = [];

  send(raw) {
    this.messages.push(JSON.parse(raw));
  }

  close() {
    if (this.readyState === WebSocket.CLOSED) return;
    this.readyState = WebSocket.CLOSED;
    this.emit("close");
  }

  terminate() {
    this.close();
  }
}

const hello = { type: "hello", client: "batch-regression-test", protocolVersion: 1 };

function record(guid, name = guid, source = `return ${JSON.stringify(guid)}`) {
  return {
    guid,
    className: "ModuleScript",
    name,
    path: ["ReplicatedStorage", name],
    ...(source === null ? {} : { source }),
  };
}

function fixture(t) {
  const syncDir = fs.mkdtempSync(path.join(os.tmpdir(), "sutz-batching-"));
  const daemon = new SutzDaemon({ host: "127.0.0.1", port: 0, syncDir });
  const sockets = [];
  const connect = () => {
    const socket = new FakeSocket();
    sockets.push(socket);
    daemon.handleConnection(socket);
    return socket;
  };
  const socket = connect();
  const send = (message, target = socket) => {
    target.emit("message", Buffer.from(JSON.stringify(message), "utf8"));
  };
  send(hello);
  t.after(async () => {
    for (const client of sockets) client.close();
    await daemon.stop();
    fs.rmSync(syncDir, { recursive: true, force: true });
  });
  return {
    daemon,
    socket,
    send,
    connect,
    syncDir,
    file: (instance) => daemon.fileWriter.getFilePath(instance),
    read: (instance) => fs.readFileSync(daemon.fileWriter.getFilePath(instance), "utf8"),
  };
}

function start(f, snapshotId = "snapshot-1") {
  f.send({ type: "snapshotStart", snapshotId });
}

function chunk(f, instances, sequence = 0, snapshotId = "snapshot-1") {
  f.send({ type: "snapshotChunk", snapshotId, sequence, instances });
}

function end(f, chunks, instanceCount, snapshotId = "snapshot-1") {
  f.send({ type: "snapshotEnd", snapshotId, chunks, instanceCount });
}

function assertAck(socket, snapshotId, sequence) {
  const reply = socket.messages.at(-1);
  assert.equal(reply?.type, "snapshotAck");
  assert.equal(reply.snapshotId, snapshotId);
  assert.equal(reply.sequence, sequence);
}

test("advertises batching and commits every batch before pruning stale files", (t) => {
  const f = fixture(t);
  assert.equal(f.socket.messages[0].type, "requestSnapshot");
  assert.equal(f.socket.messages[0].snapshotBatches, true);
  assert.equal(f.socket.messages[0].messageChunks, true);

  const old = record("existing", "Existing", "return 'old contents'");
  const stale = record("stale", "RemovedInStudio");
  f.send({ type: "snapshot", instances: [old, stale] });

  const updated = { ...old, source: "return 'new contents'" };
  const unicode = record("unicode", "日本語 🦊", "return 'こんにちは 🦊 café'");
  const later = record("later", "LastBatch");
  const folder = { guid: "folder", className: "Folder", name: "Folder", path: ["ReplicatedStorage", "Folder"] };
  start(f);
  assertAck(f.socket, "snapshot-1", -1);
  chunk(f, [updated, folder]);
  assertAck(f.socket, "snapshot-1", 0);
  assert.equal(f.read(old), old.source, "a partial snapshot must not overwrite existing sources");
  assert.equal(f.read(stale), stale.source, "a partial snapshot must not prune existing files");
  assert.equal(f.daemon.instances.get(old.guid).source, old.source);
  chunk(f, [unicode], 1);
  chunk(f, [later], 2);
  assertAck(f.socket, "snapshot-1", 2);
  assert.equal(fs.existsSync(f.file(unicode)), false, "new files wait for complete validation");
  end(f, 3, 4);

  assertAck(f.socket, "snapshot-1", 3);
  assert.equal(f.read(updated), updated.source);
  assert.equal(f.read(unicode), unicode.source);
  assert.equal(f.read(later), later.source);
  assert.equal(fs.existsSync(f.file(stale)), false);
  assert.deepEqual([...f.daemon.instances.keys()].sort(), ["existing", "folder", "later", "unicode"]);
});

test("legacy snapshots and source-optional records still support subsequent live edits", (t) => {
  const f = fixture(t);
  const existing = record("existing", "MetadataOnly", "return 'keep until source arrives'");
  f.send({ type: "snapshot", instances: [existing] });
  assert.equal(f.read(existing), existing.source);

  const metadata = record(existing.guid, existing.name, null);
  start(f);
  chunk(f, [metadata]);
  end(f, 1, 1);
  assert.equal(f.read(existing), existing.source);

  const source = "return 'fresh source after snapshot'";
  f.send({ type: "scriptChanged", guid: existing.guid, path: existing.path, className: existing.className, source });
  assert.equal(f.read(existing), source);
  const localSource = "return 'local edit → Studio 🦊'";
  fs.writeFileSync(f.file(existing), localSource, "utf8");
  f.daemon.patchStudioFromFile(path.normalize(path.resolve(f.file(existing))));
  assert.deepEqual(f.socket.messages.at(-1), { type: "patchScript", guid: existing.guid, source: localSource });
});

test("an empty completed snapshot can deliberately prune the previous snapshot", (t) => {
  const f = fixture(t);
  const previous = record("previous");
  f.send({ type: "snapshot", instances: [previous] });
  start(f);
  assert.equal(fs.existsSync(f.file(previous)), true);
  end(f, 0, 0);
  assertAck(f.socket, "snapshot-1", 0);
  assert.equal(fs.existsSync(f.file(previous)), false);
  assert.equal(f.daemon.instances.size, 0);
});

const invalidTransfers = [
  ["missing chunk", (f) => { chunk(f, [record("new")]); end(f, 2, 2); }],
  ["incorrect instance count", (f) => { chunk(f, [record("new")]); end(f, 1, 2); }],
  ["out-of-order first chunk", (f) => { chunk(f, [record("new")], 1); }],
  ["duplicate chunk sequence", (f) => { chunk(f, [record("new")]); chunk(f, [record("other")]); }],
  ["wrong snapshot id", (f) => { chunk(f, [record("new")], 0, "another-snapshot"); }],
];

for (const [name, sendInvalid] of invalidTransfers) {
  test(`rejects ${name} without changing the committed snapshot`, (t) => {
    const f = fixture(t);
    const previous = record("previous");
    f.send({ type: "snapshot", instances: [previous] });
    start(f);
    sendInvalid(f);
    assert.equal(f.socket.messages.at(-1)?.type, "snapshotError");
    assert.equal(f.read(previous), previous.source);
    assert.equal(fs.existsSync(f.file(record("new"))), false);
    assert.deepEqual([...f.daemon.instances.keys()], ["previous"]);

    // A rejected transfer must not poison a subsequent complete transfer.
    start(f, "retry");
    const next = record("next");
    chunk(f, [next], 0, "retry");
    end(f, 1, 1, "retry");
    assertAck(f.socket, "retry", 1);
    assert.equal(f.read(next), next.source);
  });
}

test("disconnect discards partial state and cannot finish an old transfer after reconnect", (t) => {
  const f = fixture(t);
  const previous = record("previous");
  f.send({ type: "snapshot", instances: [previous] });
  start(f);
  chunk(f, [record("abandoned")]);
  f.socket.close();
  assert.equal(f.read(previous), previous.source);

  const replacement = f.connect();
  f.send(hello, replacement);
  f.send({ type: "snapshotEnd", snapshotId: "snapshot-1", chunks: 1, instanceCount: 1 }, replacement);
  assert.equal(replacement.messages.at(-1)?.type, "snapshotError");
  assert.equal(f.read(previous), previous.source);
  assert.equal(fs.existsSync(f.file(record("abandoned"))), false);
  assert.deepEqual([...f.daemon.instances.keys()], ["previous"]);
});

test("a decoding failure closes the old client without crashing or committing its partial snapshot", (t) => {
  const f = fixture(t);
  const previous = record("previous");
  f.send({ type: "snapshot", instances: [previous] });
  start(f);
  chunk(f, [record("abandoned")]);

  // Reproduce Buffer.toString's failure without allocating a 512 MiB string.
  const raw = Buffer.from("oversized payload");
  raw.toString = () => {
    const error = new RangeError("Cannot create a string longer than 0x1fffffe8 characters");
    error.code = "ERR_STRING_TOO_LONG";
    throw error;
  };
  assert.doesNotThrow(() => f.socket.emit("message", raw));
  assert.equal(f.socket.messages.at(-1)?.type, "snapshotError");
  assert.equal(f.socket.readyState, WebSocket.CLOSED);
  assert.equal(f.read(previous), previous.source);
  assert.equal(fs.existsSync(f.file(record("abandoned"))), false);
  assert.deepEqual([...f.daemon.instances.keys()], ["previous"]);
  assert.equal(f.daemon.pendingSnapshot, null);
});

test("an unpaired client cannot replace or interfere with the paired client's snapshot", (t) => {
  const f = fixture(t);
  const previous = record("previous");
  f.send({ type: "snapshot", instances: [previous] });
  start(f);
  const next = record("next");
  chunk(f, [next]);

  const intruder = f.connect();
  f.send({ type: "snapshot", instances: [] }, intruder);
  f.send({ type: "snapshotStart", snapshotId: "intruder" }, intruder);
  f.send({ type: "snapshotChunk", snapshotId: "snapshot-1", sequence: 1, instances: [record("intruder")] }, intruder);
  f.send({ type: "snapshotEnd", snapshotId: "snapshot-1", chunks: 1, instanceCount: 1 }, intruder);
  f.send({ type: "instanceRemoved", guid: previous.guid }, intruder);
  assert.equal(f.read(previous), previous.source);
  assert.deepEqual([...f.daemon.instances.keys()], ["previous"]);
  f.send(hello, intruder);
  assert.equal(intruder.messages.at(-1)?.type, "busy");

  end(f, 1, 1);
  assertAck(f.socket, "snapshot-1", 1);
  assert.equal(f.read(next), next.source);
  assert.deepEqual([...f.daemon.instances.keys()], ["next"]);
});

function fragmentMessage(message, messageId = "source-message") {
  const parts = [];
  let part = "";
  let bytes = 0;
  for (const character of JSON.stringify(message)) {
    const nextBytes = Buffer.byteLength(character, "utf8");
    if (bytes + nextBytes > 4096) {
      parts.push(part);
      part = "";
      bytes = 0;
    }
    part += character;
    bytes += nextBytes;
  }
  if (part) parts.push(part);
  return parts.map((data, sequence) => ({ type: "messageChunk", messageId, sequence, total: parts.length, data }));
}

function largeScriptChange(previous) {
  return {
    type: "scriptChanged", guid: previous.guid, path: previous.path, className: previous.className,
    source: `-- JSON escaping and Unicode must survive every fragment boundary.\n${'local value = "日本語 🦊 café \\\"quoted\\\""\n'.repeat(2600)}return value`,
  };
}

test("large Unicode script messages are assembled losslessly only after every fragment arrives", (t) => {
  const f = fixture(t);
  const previous = record("large", "日本語 🦊", "return 'previous source'");
  f.send({ type: "snapshot", instances: [previous] });
  const update = largeScriptChange(previous);
  assert.ok(Buffer.byteLength(JSON.stringify(update), "utf8") > 65535);
  const fragments = fragmentMessage(update);
  assert.ok(fragments.length > 2);
  for (const fragment of fragments.slice(0, -1)) {
    assert.ok(Buffer.byteLength(fragment.data, "utf8") <= 4096);
    assert.ok(Buffer.byteLength(JSON.stringify(fragment), "utf8") <= 48 * 1024);
    f.send(fragment);
  }
  assert.equal(f.read(previous), previous.source, "partial source must not overwrite a script");
  assert.equal(f.daemon.instances.get(previous.guid).source, previous.source);
  f.send(fragments.at(-1));
  assert.equal(f.read(previous), update.source);
  assert.equal(f.daemon.instances.get(previous.guid).source, update.source);
  assert.equal(f.daemon.pendingMessage, null, "completed source must release its fragment buffer");
});

const invalidFragments = [
  ["out-of-order", (f, fragments) => { f.send(fragments[0]); f.send(fragments[2]); }],
  ["duplicate", (f, fragments) => { f.send(fragments[0]); f.send(fragments[0]); }],
  ["wrong message ID", (f, fragments) => { f.send(fragments[0]); f.send({ ...fragments[1], messageId: "another-message" }); }],
];

for (const [name, sendInvalid] of invalidFragments) {
  test(`rejects ${name} source fragments without changing synced files`, (t) => {
    const f = fixture(t);
    const previous = record("large");
    f.send({ type: "snapshot", instances: [previous] });
    sendInvalid(f, fragmentMessage(largeScriptChange(previous)));
    assert.equal(f.socket.messages.at(-1)?.type, "snapshotError");
    assert.equal(f.socket.readyState, WebSocket.CLOSED);
    assert.equal(f.read(previous), previous.source);
    assert.equal(f.daemon.instances.get(previous.guid).source, previous.source);
    assert.equal(f.daemon.pendingMessage, null);
  });
}

test("disconnect drops source fragments and reconnect cannot finish that old message", (t) => {
  const f = fixture(t);
  const previous = record("large");
  f.send({ type: "snapshot", instances: [previous] });
  const fragments = fragmentMessage(largeScriptChange(previous));
  f.send(fragments[0]);
  assert.ok(f.daemon.pendingMessage);
  f.socket.close();
  assert.equal(f.daemon.pendingMessage, null);

  const replacement = f.connect();
  f.send(hello, replacement);
  f.send(fragments[1], replacement);
  assert.equal(replacement.messages.at(-1)?.type, "snapshotError");
  assert.equal(replacement.readyState, WebSocket.CLOSED);
  assert.equal(f.read(previous), previous.source);
  assert.equal(f.daemon.pendingMessage, null);
});

test("batches round-trip with acknowledgements over a real WebSocket", { timeout: 10000 }, async (t) => {
  const syncDir = fs.mkdtempSync(path.join(os.tmpdir(), "sutz-batching-socket-"));
  const daemon = new SutzDaemon({ host: "127.0.0.1", port: 0, syncDir });
  let socket;
  t.after(async () => {
    socket?.terminate();
    await daemon.stop();
    fs.rmSync(syncDir, { recursive: true, force: true });
  });
  await daemon.start();
  const address = daemon.httpServer.address();
  assert.equal(typeof address, "object");
  socket = new WebSocket(`ws://127.0.0.1:${address.port}`);
  await once(socket, "open");
  const exchange = async (message) => {
    const reply = once(socket, "message", { signal: AbortSignal.timeout(3000) });
    socket.send(JSON.stringify(message));
    const [raw] = await reply;
    return JSON.parse(raw.toString());
  };
  const capabilities = await exchange(hello);
  assert.equal(capabilities.snapshotBatches, true);
  assert.equal(capabilities.messageChunks, true);
  assert.deepEqual(await exchange({ type: "snapshotStart", snapshotId: "wire" }), {
    type: "snapshotAck", snapshotId: "wire", sequence: -1,
  });
  const instances = [record("first", "日本語", "return '最初 🦊'"), record("last")];
  for (let sequence = 0; sequence < instances.length; sequence++) {
    assert.deepEqual(await exchange({ type: "snapshotChunk", snapshotId: "wire", sequence, instances: [instances[sequence]] }), {
      type: "snapshotAck", snapshotId: "wire", sequence,
    });
  }
  assert.deepEqual(await exchange({ type: "snapshotEnd", snapshotId: "wire", chunks: 2, instanceCount: 2 }), {
    type: "snapshotAck", snapshotId: "wire", sequence: 2,
  });
  for (const instance of instances) {
    assert.equal(fs.readFileSync(daemon.fileWriter.getFilePath(instance), "utf8"), instance.source);
  }
});
