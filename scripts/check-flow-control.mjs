import assert from "node:assert/strict";
import { once } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { WebSocket } from "ws";
import { SutzDaemon } from "../dist/daemon.js";

const hello = { type: "hello", client: "flow-control-regression-test", protocolVersion: 1 };

function record(guid, source = "return 'committed source'") {
  return { guid, className: "ModuleScript", name: guid, path: ["ReplicatedStorage", guid], source };
}

function update(instance, source) {
  return { type: "scriptChanged", guid: instance.guid, path: instance.path, className: instance.className, source };
}

function inbox(socket) {
  const messages = [];
  const queued = [];
  let pending;
  let closed = false;
  socket.on("message", (raw) => {
    const message = JSON.parse(raw.toString());
    messages.push(message);
    if (pending && pending.matches(message)) {
      const waiter = pending;
      pending = undefined;
      waiter.resolve(message);
    } else {
      queued.push(message);
    }
  });
  socket.on("close", () => {
    closed = true;
    pending?.reject(new Error("Socket closed before the expected message arrived"));
  });
  socket.on("error", (error) => pending?.reject(error));
  return {
    messages,
    next(matches) {
      const index = queued.findIndex(matches);
      if (index !== -1) return Promise.resolve(queued.splice(index, 1)[0]);
      if (closed) return Promise.reject(new Error("Socket is already closed"));
      assert.equal(pending, undefined, "only one receive waiter at a time");
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending = undefined;
          reject(new Error("Timed out waiting for a daemon message"));
        }, 5000);
        pending = {
          matches,
          resolve: (value) => { clearTimeout(timer); resolve(value); },
          reject: (error) => { clearTimeout(timer); pending = undefined; reject(error); },
        };
      });
    },
  };
}

async function fixture(t) {
  const temporaryRoot = fs.realpathSync(os.tmpdir());
  const syncDir = fs.mkdtempSync(path.join(temporaryRoot, "sutz-flow-control-"));
  const daemon = new SutzDaemon({ host: "127.0.0.1", port: 0, syncDir });
  const sockets = [];
  t.after(async () => {
    for (const socket of sockets) socket.terminate();
    await daemon.stop();
    const resolved = fs.realpathSync(syncDir);
    assert.equal(path.dirname(resolved), temporaryRoot);
    assert.ok(path.basename(resolved).startsWith("sutz-flow-control-"));
    fs.rmSync(resolved, { recursive: true, force: true });
  });
  await daemon.start();
  const address = daemon.httpServer.address();
  assert.equal(typeof address, "object");
  const connect = async (pair = true) => {
    const socket = new WebSocket(`ws://127.0.0.1:${address.port}`, { perMessageDeflate: false });
    sockets.push(socket);
    const received = inbox(socket);
    await once(socket, "open", { signal: AbortSignal.timeout(5000) });
    let sequence = 0;
    const client = {
      socket,
      received,
      send: (message) => socket.send(JSON.stringify(message)),
      async sendAcked(message) {
        const transportSequence = ++sequence;
        const reply = received.next((incoming) => incoming.type === "messageAck" && incoming.sequence === transportSequence);
        socket.send(JSON.stringify({ ...message, transportSequence }));
        assert.deepEqual(await reply, { type: "messageAck", sequence: transportSequence });
        return transportSequence;
      },
    };
    if (pair) {
      client.send(hello);
      client.capabilities = await received.next((message) => message.type === "requestSnapshot");
    }
    return client;
  };
  const client = await connect();
  return {
    daemon, syncDir, client, connect,
    file: (instance) => path.join(syncDir, ...instance.path.slice(0, -1), `${instance.name}.luau`),
    read(instance) { return fs.readFileSync(this.file(instance), "utf8"); },
  };
}

function fragments(message, messageId = "source-message") {
  const encoded = Buffer.from(JSON.stringify(message), "utf8");
  const parts = [];
  for (let offset = 0; offset < encoded.length;) {
    let end = Math.min(offset + 4096, encoded.length);
    while (end < encoded.length && (encoded[end] & 0xc0) === 0x80) end--;
    parts.push(encoded.subarray(offset, end).toString("utf8"));
    offset = end;
  }
  return parts.map((data, sequence) => ({ type: "messageChunk", messageId, sequence, total: parts.length, data }));
}

async function assertSnapshotAck(client, snapshotId, sequence) {
  assert.deepEqual(await client.received.next((message) => message.type === "snapshotAck"), {
    type: "snapshotAck", snapshotId, sequence,
  });
}

test("transport ACKs follow metadata/source processing and remain distinct from snapshot ACKs", { timeout: 15000 }, async (t) => {
  const f = await fixture(t);
  const client = f.client;
  assert.equal(client.capabilities.messageAcks, true);
  const instance = record("MetadataOnly");
  const { source, ...metadata } = instance;
  await client.sendAcked({ type: "snapshotStart", snapshotId: "metadata" });
  await assertSnapshotAck(client, "metadata", -1);
  await client.sendAcked({ type: "snapshotChunk", snapshotId: "metadata", sequence: 0, instances: [metadata] });
  await assertSnapshotAck(client, "metadata", 0);
  await client.sendAcked({ type: "snapshotEnd", snapshotId: "metadata", chunks: 1, instanceCount: 1 });
  await assertSnapshotAck(client, "metadata", 1);
  assert.equal(fs.existsSync(f.file(instance)), false);
  await client.sendAcked(update(instance, source));
  assert.equal(f.read(instance), source, "source must be on disk before its transport ACK");
  assert.equal(client.received.messages.filter((message) => message.type === "messageAck").length, 4);
  assert.equal(client.received.messages.filter((message) => message.type === "snapshotAck").length, 3);
});

test("an 11.4 MiB Unicode source round-trips over loopback with only one unacknowledged fragment", { timeout: 30000 }, async (t) => {
  const f = await fixture(t);
  const instance = record("LargeUnicode");
  await f.client.sendAcked({ type: "snapshot", instances: [instance] });
  const line = 'local value = "日本語 🦊 café \\\"quoted\\\""\n';
  const source = line.repeat(Math.ceil(11.4 * 1024 * 1024 / Buffer.byteLength(line))) + "return value\n";
  assert.ok(Buffer.byteLength(source) >= 11.4 * 1024 * 1024);
  const pieces = fragments(update(instance, source));
  assert.ok(pieces.length > 2800);
  for (let index = 0; index < pieces.length; index++) {
    assert.ok(Buffer.byteLength(pieces[index].data) <= 4096);
    if (index === pieces.length - 1) assert.equal(f.read(instance), instance.source, "incomplete source cannot overwrite the existing script");
    await f.client.sendAcked(pieces[index]);
  }
  assert.equal(f.read(instance), source);
  assert.equal(f.daemon.pendingMessage, null);
  assert.equal(f.client.received.messages.filter((message) => message.type === "messageAck").length, pieces.length + 1);
});

test("legacy messages without transport sequences remain accepted without unsolicited ACKs", { timeout: 15000 }, async (t) => {
  const f = await fixture(t);
  const instance = record("Legacy");
  f.client.send({ type: "snapshot", instances: [instance] });
  f.client.send(update(instance, "return 'legacy live edit'"));
  f.client.send({ type: "snapshotStart", snapshotId: "legacy" });
  await assertSnapshotAck(f.client, "legacy", -1);
  assert.equal(f.read(instance), "return 'legacy live edit'");
  assert.equal(f.client.received.messages.some((message) => message.type === "messageAck"), false);
  await f.client.sendAcked({ type: "pong" });
});

test("closing a partially acknowledged source preserves committed files and permits reconnection", { timeout: 15000 }, async (t) => {
  const f = await fixture(t);
  const instance = record("KeepCommitted");
  await f.client.sendAcked({ type: "snapshot", instances: [instance] });
  const pieces = fragments(update(instance, "return 'unfinished'\n".repeat(5000)));
  await f.client.sendAcked(pieces[0]);
  const closed = once(f.client.socket, "close", { signal: AbortSignal.timeout(5000) });
  f.client.socket.close();
  await closed;
  assert.equal(f.read(instance), instance.source);
  const replacement = await f.connect();
  await replacement.sendAcked(update(instance, "return 'reconnected successfully'"));
  assert.equal(f.read(instance), "return 'reconnected successfully'");
});

for (const transportSequence of [0, -1, 1.5, Number.MAX_SAFE_INTEGER + 1, "1", null]) {
  test(`rejects invalid transport sequence ${JSON.stringify(transportSequence)} without applying or acknowledging it`, { timeout: 15000 }, async (t) => {
    const f = await fixture(t);
    const instance = record("InvalidSequence");
    await f.client.sendAcked({ type: "snapshot", instances: [instance] });
    const ackCount = f.client.received.messages.filter((message) => message.type === "messageAck").length;
    const closed = once(f.client.socket, "close", { signal: AbortSignal.timeout(5000) });
    f.client.send({ ...update(instance, "return 'must not be written'"), transportSequence });
    const [code] = await closed;
    assert.equal(code, 1008);
    assert.equal(f.read(instance), instance.source);
    assert.equal(f.client.received.messages.filter((message) => message.type === "messageAck").length, ackCount);
  });
}

test("a reconstructed inner message cannot forge a transport ACK or modify files", { timeout: 15000 }, async (t) => {
  const f = await fixture(t);
  const instance = record("NestedSequence");
  await f.client.sendAcked({ type: "snapshot", instances: [instance] });
  const pieces = fragments({ ...update(instance, "return 'must not be written'"), transportSequence: 999 });
  assert.equal(pieces.length, 1);
  const closed = once(f.client.socket, "close", { signal: AbortSignal.timeout(5000) });
  f.client.send({ ...pieces[0], transportSequence: 2 });
  const [code] = await closed;
  assert.equal(code, 1008);
  assert.equal(f.read(instance), instance.source);
  assert.deepEqual(f.client.received.messages.filter((message) => message.type === "messageAck"), [{ type: "messageAck", sequence: 1 }]);
});

test("out-of-order source chunks close without an ACK or partial writes", { timeout: 15000 }, async (t) => {
  const f = await fixture(t);
  const instance = record("BadChunk");
  await f.client.sendAcked({ type: "snapshot", instances: [instance] });
  const pieces = fragments(update(instance, "return 'incomplete'\n".repeat(5000)));
  await f.client.sendAcked(pieces[0]);
  const closed = once(f.client.socket, "close", { signal: AbortSignal.timeout(5000) });
  f.client.send({ ...pieces[2], transportSequence: 3 });
  const [code] = await closed;
  assert.equal(code, 1008);
  assert.equal(f.read(instance), instance.source);
  assert.equal(f.client.received.messages.filter((message) => message.type === "messageAck").length, 2);
});

test("only the paired Studio can receive transport ACKs", { timeout: 15000 }, async (t) => {
  const f = await fixture(t);
  const intruder = await f.connect(false);
  intruder.send({ type: "pong", transportSequence: 1 });
  const closed = once(intruder.socket, "close", { signal: AbortSignal.timeout(5000) });
  intruder.send({ ...hello, transportSequence: 2 });
  await closed;
  assert.equal(intruder.received.messages.some((message) => message.type === "messageAck"), false);
  assert.equal(intruder.received.messages.some((message) => message.type === "busy"), true);
  await f.client.sendAcked({ type: "pong" });
});

for (const [name, header, expectedCode] of [
  ["RSV1", 0xc1, "WS_ERR_UNEXPECTED_RSV_1"],
  ["RSV2", 0xa1, "WS_ERR_UNEXPECTED_RSV_2_3"],
  ["RSV3", 0x91, "WS_ERR_UNEXPECTED_RSV_2_3"],
]) {
  test(`${name} framing errors report protocol metadata, retain committed files, and allow reconnect`, { timeout: 15000 }, async (t) => {
    const errors = [];
    t.mock.method(console, "error", (...args) => errors.push(args));
    const f = await fixture(t);
    const instance = record("KeepAfterFrameError");
    await f.client.sendAcked({ type: "snapshot", instances: [instance] });
    await f.client.sendAcked({ type: "snapshotStart", snapshotId: "abandoned" });
    const lastMessage = { type: "snapshotChunk", snapshotId: "abandoned", sequence: 0, instances: [record("NeverCommitted")] };
    const transportSequence = await f.client.sendAcked(lastMessage);
    const expectedLastBytes = Buffer.byteLength(JSON.stringify({ ...lastMessage, transportSequence }));
    const closed = once(f.client.socket, "close", { signal: AbortSignal.timeout(5000) });
    // Deliberately malformed, masked, empty text frame sent after a valid upgrade.
    f.client.socket._socket.write(Buffer.from([header, 0x80, 0, 0, 0, 0]));
    const [code] = await closed;
    assert.equal(code, 1002);
    const diagnostic = errors.find(([message]) => String(message).includes(expectedCode));
    assert.ok(diagnostic, `diagnostic must include ${expectedCode}`);
    assert.deepEqual(diagnostic[1], {
      offeredExtensions: "(none)", negotiatedExtensions: "(none)", lastCompleteMessageBytes: expectedLastBytes,
    });
    assert.doesNotMatch(String(diagnostic[0]), /http:\/\/ URL|browser tab|Make sure the plugin is using/i);
    assert.equal(f.read(instance), instance.source);
    assert.equal(fs.existsSync(f.file(record("NeverCommitted"))), false);
    const replacement = await f.connect();
    await replacement.sendAcked(update(instance, "return 'working after reconnect'"));
    assert.equal(f.read(instance), "return 'working after reconnect'");
  });
}
