import { createServer, type Server } from "node:http";
import { constants as bufferConstants } from "node:buffer";
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { WebSocket, WebSocketServer } from "ws";
import { FileWriter } from "./fileWriter.js";
import {
  ClientMessageType,
  ServerMessageType,
  type ClientMessage,
  type ServerMessage,
  type StudioInstanceRecord,
} from "./protocol.js";

export interface DaemonOptions {
  port: number;
  host: string;
  syncDir: string;
  portScanCount?: number;
}

interface PendingSnapshot {
  socket: WebSocket;
  id: string;
  nextSequence: number;
  instances: Map<string, StudioInstanceRecord>;
}

interface PendingMessage {
  socket: WebSocket;
  id: string;
  total: number;
  bytes: number;
  parts: string[];
}

export class SutzDaemon {
  private readonly port: number;
  private readonly host: string;
  private readonly portScanCount: number;
  private boundPort = 0;
  private httpServer: Server | null = null;
  private socketServer: WebSocketServer | null = null;
  private studioClient: WebSocket | null = null;
  private instances = new Map<string, StudioInstanceRecord>();
  private pendingSnapshot: PendingSnapshot | null = null;
  private pendingMessage: PendingMessage | null = null;
  private fileWriter: FileWriter;
  private fileWatcher: fs.FSWatcher | null = null;
  private readonly guidToFilePath = new Map<string, string>();
  private readonly filePathToGuid = new Map<string, string>();
  private readonly pendingFileTimers = new Map<string, NodeJS.Timeout>();

  public constructor(options: DaemonOptions) {
    this.port = options.port;
    this.host = options.host;
    this.portScanCount = Math.max(1, options.portScanCount ?? 10);
    this.fileWriter = new FileWriter({ rootDir: options.syncDir });
  }

  public getPort(): number {
    return this.boundPort;
  }

  public async start(): Promise<void> {
    if (this.httpServer || this.socketServer) {
      return;
    }

    this.fileWriter.ensureRoot();
    this.startFileWatcher();

    this.httpServer = createServer((request, response) => {
      // The plugin probes this endpoint to discover a free daemon to pair with.
      const requestUrl = new URL(request.url ?? "/", `http://${this.host}:${this.boundPort || this.port}`);
      if (!["/", "/status", "/sutz/status"].includes(requestUrl.pathname)) {
        response.writeHead(404, { "content-type": "application/json; charset=utf-8" });
        response.end(JSON.stringify({ sutz: false, error: "not_found" }) + "\n");
        return;
      }

      response.writeHead(200, { "content-type": "application/json; charset=utf-8" });
      response.end(
        JSON.stringify({
          sutz: true,
          port: this.boundPort,
          paired: this.isPaired(),
        }) + "\n",
      );
    });

    // Bind the port first (scanning upward if busy) so the WebSocketServer is
    // only attached to an already-listening server. Attaching it earlier makes
    // ws re-emit the http server's EADDRINUSE on itself and crash the process.
    this.boundPort = await this.listen();

    this.socketServer = new WebSocketServer({
      server: this.httpServer,
      maxPayload: 0, // Snapshot messages are bounded by the plugin's batch size.
    });

    this.socketServer.on("connection", (socket) => {
      this.handleConnection(socket);
    });

    console.log(`Sutz daemon listening on ws://${this.host}:${this.boundPort}`);
    console.log(`Sync folder: ${path.relative(process.cwd(), this.fileWriter.getRootDir()) || "."}`);
  }

  // Bind to the requested port, scanning upward if it is already in use so that
  // a second `sutz` lands on the next free port instead of failing.
  private listen(): Promise<number> {
    const tryPort = (index: number): Promise<number> => {
      const candidate = this.port + index;
      const server = this.httpServer!;

      return new Promise<number>((resolve, reject) => {
        const onError = (error: NodeJS.ErrnoException): void => {
          server.off("listening", onListening);
          if (error.code === "EADDRINUSE" && index + 1 < this.portScanCount) {
            resolve(tryPort(index + 1));
          } else {
            reject(error);
          }
        };

        const onListening = (): void => {
          server.off("error", onError);
          resolve(candidate);
        };

        server.once("error", onError);
        server.once("listening", onListening);
        server.listen(candidate, this.host);
      });
    };

    return tryPort(0);
  }

  public async stop(): Promise<void> {
    this.pendingSnapshot = null;
    this.pendingMessage = null;
    this.send({ type: ServerMessageType.Disconnect });
    this.stopFileWatcher();

    if (this.studioClient) {
      this.studioClient.close();
      this.studioClient = null;
    }

    if (this.socketServer) {
      await new Promise<void>((resolve, reject) => {
        this.socketServer!.close((error) => {
          if (error) reject(error);
          else resolve();
        });
      });
      this.socketServer = null;
    }

    if (this.httpServer) {
      await new Promise<void>((resolve, reject) => {
        this.httpServer!.close((error) => {
          if (error) reject(error);
          else resolve();
        });
      });
      this.httpServer = null;
    }
  }

  private handleConnection(socket: WebSocket): void {
    console.log("Client connected.");

    socket.on("message", (raw) => {
      const byteLength = Array.isArray(raw)
        ? raw.reduce((total, part) => total + part.byteLength, 0)
        : raw.byteLength;
      let text: string;
      try {
        // Older plugins may still send the entire place as one JSON message.
        // Reject that message without crashing at Buffer.toString().
        if (byteLength > bufferConstants.MAX_STRING_LENGTH) {
          throw new RangeError("Message exceeds Node's single-string limit");
        }
        const buffer = Array.isArray(raw)
          ? Buffer.concat(raw)
          : raw instanceof ArrayBuffer ? Buffer.from(raw) : raw;
        text = buffer.toString("utf8");
      } catch (error) {
        const reason = `Cannot decode ${byteLength} bytes from Studio. Update the Studio plugin to use batched snapshots.`;
        console.error(reason, error);
        this.failSnapshot(socket, undefined, reason);
        socket.close(1009, "Update Studio plugin: use batched snapshots");
        return;
      }
      this.handleRawMessage(socket, text);
    });

    socket.on("close", () => {
      this.discardSnapshot(socket);
      if (this.studioClient === socket) {
        this.studioClient = null;
        console.log("Studio disconnected.");
      }
    });

    socket.on("error", (error) => {
      this.discardSnapshot(socket);
      this.logSocketError(error);
      if (this.studioClient === socket) {
        this.studioClient = null;
      }
      socket.close();
    });
  }

  private isPaired(): boolean {
    return this.studioClient?.readyState === WebSocket.OPEN;
  }

  private logSocketError(error: Error): void {
    const code = "code" in error ? String(error.code) : "";

    if (code === "WS_ERR_UNEXPECTED_RSV_2_3") {
      console.error(
        "Studio socket error: received non-standard WebSocket bytes. " +
          "Make sure the plugin is using a ws:// URL from Sutz discovery, not an http:// URL or browser tab.",
      );
      return;
    }

    console.error("Studio socket error:", error);
  }

  private handleRawMessage(socket: WebSocket, raw: string, allowChunks = true): void {
    let message: ClientMessage;

    try {
      message = JSON.parse(raw) as ClientMessage;
    } catch {
      console.warn("Ignored invalid JSON message from Studio.");
      return;
    }

    if (!message || typeof message !== "object" || typeof message.type !== "string") {
      console.warn("Ignored invalid message from Studio.");
      return;
    }

    if (message.type === ClientMessageType.MessageChunk) {
      if (socket !== this.studioClient) return;
      if (!allowChunks) {
        this.rejectMessageChunks(socket, "Nested message chunks are not supported.");
        return;
      }
      this.receiveMessageChunk(socket, message);
      return;
    }
    if (this.pendingMessage?.socket === socket) {
      this.rejectMessageChunks(socket, "An individual message was interrupted before all its chunks arrived.");
      return;
    }
    this.handleMessage(socket, message);
  }

  private receiveMessageChunk(socket: WebSocket, message: Extract<ClientMessage, { type: "messageChunk" }>): void {
    if (typeof message.messageId !== "string" || message.messageId.length === 0 || message.messageId.length > 128
      || !Number.isSafeInteger(message.sequence) || message.sequence < 0
      || !Number.isSafeInteger(message.total) || message.total < 1
      || message.sequence >= message.total || typeof message.data !== "string"
      || message.data.length === 0 || Buffer.byteLength(message.data, "utf8") > 4096) {
      this.rejectMessageChunks(socket, "Invalid individual-message chunk.");
      return;
    }
    if (!this.pendingMessage && message.sequence === 0) {
      this.pendingMessage = { socket, id: message.messageId, total: message.total, bytes: 0, parts: [] };
    }
    const pending = this.pendingMessage;
    if (!pending || pending.socket !== socket || pending.id !== message.messageId
      || pending.total !== message.total || pending.parts.length !== message.sequence) {
      this.rejectMessageChunks(socket, "Individual-message chunks arrived out of order.");
      return;
    }
    pending.bytes += Buffer.byteLength(message.data, "utf8");
    if (pending.bytes > bufferConstants.MAX_STRING_LENGTH) {
      this.rejectMessageChunks(socket, "One individual script/message exceeds Node's string limit; split that script into modules.");
      return;
    }
    pending.parts.push(message.data);
    if (pending.parts.length === pending.total) {
      this.pendingMessage = null;
      // Only reassemble one individual source/update, never the entire snapshot.
      this.handleRawMessage(socket, pending.parts.join(""), false);
    }
  }

  private rejectMessageChunks(socket: WebSocket, error: string): void {
    this.failSnapshot(socket, undefined, error);
    socket.close(1008, "Invalid individual-message chunks");
  }

  private handleMessage(socket: WebSocket, message: ClientMessage): void {
    if (message.type !== ClientMessageType.Hello && this.studioClient !== socket) {
      return;
    }

    switch (message.type) {
      case ClientMessageType.Hello:
        if (this.studioClient && this.studioClient !== socket) {
          // Already paired with another Studio. Tell the newcomer so it can
          // discover a different daemon instead of stealing this one.
          console.warn("Rejected a second Studio connection; already paired.");
          this.sendTo(socket, { type: ServerMessageType.Busy });
          socket.close();
          return;
        }

        this.studioClient = socket;
        console.log("Studio connected.");
        this.sendTo(socket, { type: ServerMessageType.RequestSnapshot, snapshotBatches: true, messageChunks: true });
        console.log(
          `Studio hello: ${message.client} protocol v${message.protocolVersion}`,
        );
        break;

      case ClientMessageType.Snapshot:
        if (!Array.isArray(message.instances) || !message.instances.every(isInstanceRecord)) {
          this.failSnapshot(socket, undefined, "Invalid legacy snapshot records.");
          break;
        }
        this.discardSnapshot(socket);
        this.commitSnapshot(new Map(message.instances.map((instance) => [instance.guid, instance])));
        break;

      case ClientMessageType.SnapshotStart:
        if (typeof message.snapshotId !== "string" || message.snapshotId.length === 0 || message.snapshotId.length > 128) {
          this.failSnapshot(socket, undefined, "Invalid snapshot ID.");
          break;
        }
        this.pendingSnapshot = {
          socket,
          id: message.snapshotId,
          nextSequence: 0,
          instances: new Map(),
        };
        this.ackSnapshot(socket, message.snapshotId, -1);
        break;

      case ClientMessageType.SnapshotChunk:
        {
          const pending = this.pendingSnapshot;
          if (!pending || pending.socket !== socket || pending.id !== message.snapshotId) {
            this.failSnapshot(socket, message.snapshotId, "Snapshot chunk has no matching start.");
            break;
          }
          if (message.sequence !== pending.nextSequence || !Array.isArray(message.instances)) {
            this.failSnapshot(socket, message.snapshotId, "Snapshot chunks arrived out of order. Send a new snapshot.");
            break;
          }
          let invalid = false;
          for (const instance of message.instances) {
            if (!isInstanceRecord(instance) || pending.instances.has(instance.guid)) {
              invalid = true;
              break;
            }
            pending.instances.set(instance.guid, instance);
          }
          if (invalid) {
            this.failSnapshot(socket, message.snapshotId, "Snapshot contains an invalid or duplicate instance record.");
            break;
          }
          pending.nextSequence += 1;
          this.ackSnapshot(socket, pending.id, message.sequence);
        }
        break;

      case ClientMessageType.SnapshotEnd:
        {
          const pending = this.pendingSnapshot;
          if (!pending || pending.socket !== socket || pending.id !== message.snapshotId) {
            this.failSnapshot(socket, message.snapshotId, "Snapshot end has no matching start.");
            break;
          }
          if (message.chunks !== pending.nextSequence || message.instanceCount !== pending.instances.size) {
            this.failSnapshot(socket, pending.id, "Incomplete snapshot; existing sync files were kept. Send a new snapshot.");
            break;
          }
          this.pendingSnapshot = null;
          this.commitSnapshot(pending.instances);
          this.ackSnapshot(socket, pending.id, message.chunks);
          console.log(`Snapshot completed in ${message.chunks} batch(es).`);
        }
        break;

      case ClientMessageType.ScriptChanged:
        {
          const previousFilePath = this.guidToFilePath.get(message.guid);
          const instance = {
            guid: message.guid,
            className: message.className,
            name: message.path[message.path.length - 1] ?? "Script",
            path: message.path,
            source: message.source,
          };
          this.instances.set(message.guid, instance);
          this.fileWriter.writeScript(instance);
          this.indexSyncedScript(instance, previousFilePath);
        }
        console.log(`Script changed: ${message.path.join("/")}`);
        break;

      case ClientMessageType.InstanceChanged:
        {
          const previousFilePath = this.guidToFilePath.get(message.instance.guid);
          this.instances.set(message.instance.guid, message.instance);
          if (this.fileWriter.writeScript(message.instance)) {
            this.indexSyncedScript(message.instance, previousFilePath);
          } else {
            this.forgetSyncedScript(message.instance.guid);
          }
        }
        console.log(`Instance changed: ${message.instance.path.join("/")}`);
        break;

      case ClientMessageType.InstanceRemoved:
        this.instances.delete(message.guid);
        this.fileWriter.remove(message.guid);
        this.forgetSyncedScript(message.guid);
        console.log(`Instance removed: ${message.guid}`);
        break;

      case ClientMessageType.CopyToClipboard:
        void this.copyToClipboard(socket, message.text, message.requestId);
        break;

      case ClientMessageType.Pong:
        break;
    }
  }

  private discardSnapshot(socket: WebSocket): void {
    if (this.pendingMessage?.socket === socket) {
      this.pendingMessage = null;
    }
    if (this.pendingSnapshot?.socket === socket) {
      this.pendingSnapshot = null;
    }
  }

  private failSnapshot(socket: WebSocket, snapshotId: string | undefined, error: string): void {
    this.discardSnapshot(socket);
    console.warn(error);
    this.sendTo(socket, { type: ServerMessageType.SnapshotError, snapshotId, error });
  }

  private ackSnapshot(socket: WebSocket, snapshotId: string, sequence: number): void {
    this.sendTo(socket, { type: ServerMessageType.SnapshotAck, snapshotId, sequence });
  }

  private commitSnapshot(instances: Map<string, StudioInstanceRecord>): void {
    // Keep records as objects: never concatenate batches into one giant JSON string.
    // Pruning happens exactly once, after the complete snapshot has been validated.
    const written = this.fileWriter.writeSnapshot(instances.values());
    this.instances = instances;
    this.guidToFilePath.clear();
    this.filePathToGuid.clear();
    let scriptCount = 0;
    let sourceCount = 0;
    for (const instance of instances.values()) {
      this.indexSyncedScript(instance);
      if (this.isScript(instance)) scriptCount += 1;
      if (typeof instance.source === "string") sourceCount += 1;
    }
    if (sourceCount === 0 && scriptCount > 0) {
      console.log(`Snapshot indexed ${scriptCount} script path(s); waiting for script sources.`);
    } else {
      console.log(`Wrote ${written} script file(s) to sync folder.`);
    }
    console.log(`Snapshot received: ${instances.size} instances.`);
  }

  private send(message: ServerMessage): boolean {
    if (!this.studioClient || this.studioClient.readyState !== WebSocket.OPEN) {
      return false;
    }

    return this.sendTo(this.studioClient, message);
  }

  private sendTo(socket: WebSocket, message: ServerMessage): boolean {
    if (socket.readyState !== WebSocket.OPEN) {
      return false;
    }

    socket.send(JSON.stringify(message));
    return true;
  }

  private startFileWatcher(): void {
    if (this.fileWatcher) {
      return;
    }

    try {
      this.fileWatcher = fs.watch(
        this.fileWriter.getRootDir(),
        { recursive: true },
        (_, fileName) => {
          if (!fileName) {
            return;
          }

          this.scheduleFilePatch(
            path.join(this.fileWriter.getRootDir(), fileName.toString()),
          );
        },
      );

      this.fileWatcher.on("error", (error) => {
        console.warn("Sync folder watcher error:", error);
      });
    } catch (error) {
      console.warn("Could not watch sync folder for local edits:", error);
    }
  }

  private stopFileWatcher(): void {
    if (this.fileWatcher) {
      this.fileWatcher.close();
      this.fileWatcher = null;
    }

    for (const timer of this.pendingFileTimers.values()) {
      clearTimeout(timer);
    }
    this.pendingFileTimers.clear();
  }

  private scheduleFilePatch(filePath: string): void {
    const normalizedPath = this.normalizeFilePath(filePath);

    if (
      !this.filePathToGuid.has(normalizedPath) &&
      !this.fileWriter.parseScriptFilePath(normalizedPath)
    ) {
      return;
    }

    const existingTimer = this.pendingFileTimers.get(normalizedPath);
    if (existingTimer) {
      clearTimeout(existingTimer);
    }

    const timer = setTimeout(() => {
      this.pendingFileTimers.delete(normalizedPath);
      this.patchStudioFromFile(normalizedPath);
    }, 120);

    this.pendingFileTimers.set(normalizedPath, timer);
  }

  private patchStudioFromFile(filePath: string): void {
    const guid = this.filePathToGuid.get(filePath);
    if (!guid) {
      this.upsertStudioFromFile(filePath);
      return;
    }

    const instance = this.instances.get(guid);
    if (!instance) {
      this.forgetSyncedScript(guid);
      return;
    }

    if (!fs.existsSync(filePath)) {
      return;
    }

    const source = fs.readFileSync(filePath, "utf8");
    if (instance.source === source) {
      return;
    }

    const sent = this.send({
      type: ServerMessageType.PatchScript,
      guid,
      source,
    });

    if (!sent) {
      console.warn(
        `Local edit detected, but no Studio client is connected: ${path.relative(process.cwd(), filePath)}`,
      );
      return;
    }

    instance.source = source;
    console.log(`Patched Studio script from file: ${path.relative(process.cwd(), filePath)}`);
  }

  private upsertStudioFromFile(filePath: string): void {
    const scriptFile = this.fileWriter.parseScriptFilePath(filePath);
    if (!scriptFile || !fs.existsSync(filePath)) {
      return;
    }

    const stat = fs.statSync(filePath);
    if (!stat.isFile()) {
      return;
    }

    const source = fs.readFileSync(filePath, "utf8");
    const sent = this.send({
      type: ServerMessageType.UpsertScript,
      path: scriptFile.path,
      className: scriptFile.className,
      source,
    });

    if (!sent) {
      console.warn(
        `Local script file detected, but no Studio client is connected: ${path.relative(process.cwd(), filePath)}`,
      );
      return;
    }

    console.log(`Sent local script file to Studio: ${scriptFile.path.join("/")}`);
  }

  private indexSyncedScript(instance: StudioInstanceRecord, previousFilePath?: string): void {
    if (!this.isScript(instance) || typeof instance.source !== "string") {
      this.forgetSyncedScript(instance.guid);
      return;
    }

    if (previousFilePath) {
      this.filePathToGuid.delete(this.normalizeFilePath(previousFilePath));
    }

    const filePath = this.normalizeFilePath(this.fileWriter.getFilePath(instance));
    this.guidToFilePath.set(instance.guid, filePath);
    this.filePathToGuid.set(filePath, instance.guid);
  }

  private forgetSyncedScript(guid: string): void {
    const filePath = this.guidToFilePath.get(guid);
    if (filePath) {
      this.filePathToGuid.delete(filePath);
    }
    this.guidToFilePath.delete(guid);
  }

  private normalizeFilePath(filePath: string): string {
    return path.normalize(path.resolve(filePath));
  }

  private isScript(instance: StudioInstanceRecord): boolean {
    return (
      instance.className === "Script" ||
      instance.className === "LocalScript" ||
      instance.className === "ModuleScript"
    );
  }

  private async copyToClipboard(socket: WebSocket, text: string, requestId?: string): Promise<void> {
    if (text.length === 0) {
      this.sendTo(socket, {
        type: ServerMessageType.ClipboardResult,
        ok: false,
        requestId,
        error: "No text was provided.",
      });
      return;
    }

    try {
      await writeClipboardText(text);
      console.log("Copied selected Studio path(s) to clipboard.");
      this.sendTo(socket, {
        type: ServerMessageType.ClipboardResult,
        ok: true,
        requestId,
      });
    } catch (error) {
      console.warn("Could not copy selected Studio path(s) to clipboard:", error);
      this.sendTo(socket, {
        type: ServerMessageType.ClipboardResult,
        ok: false,
        requestId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }
}

function isInstanceRecord(value: unknown): value is StudioInstanceRecord {
  if (!value || typeof value !== "object") return false;
  const record = value as StudioInstanceRecord;
  return typeof record.guid === "string" && record.guid.length > 0
    && typeof record.className === "string"
    && typeof record.name === "string"
    && Array.isArray(record.path) && record.path.length > 0
    && record.path.every((segment) => typeof segment === "string")
    && (record.source === undefined || typeof record.source === "string");
}

interface ClipboardCommand {
  command: string;
  args: string[];
}

function getClipboardCommands(): ClipboardCommand[] {
  if (process.platform === "win32") {
    return [{ command: "clip.exe", args: [] }];
  }

  if (process.platform === "darwin") {
    return [{ command: "pbcopy", args: [] }];
  }

  return [
    { command: "wl-copy", args: [] },
    { command: "xclip", args: ["-selection", "clipboard"] },
    { command: "xsel", args: ["--clipboard", "--input"] },
  ];
}

async function writeClipboardText(text: string): Promise<void> {
  const commands = getClipboardCommands();
  let lastError: unknown = null;

  for (const command of commands) {
    try {
      await runClipboardCommand(command, text);
      return;
    } catch (error) {
      lastError = error;
    }
  }

  throw lastError ?? new Error("No clipboard command is available.");
}

function runClipboardCommand(command: ClipboardCommand, text: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(command.command, command.args, {
      stdio: ["pipe", "ignore", "pipe"],
      windowsHide: true,
    });

    let stderr = "";

    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => {
      stderr += chunk;
    });

    child.once("error", reject);
    child.once("close", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(stderr.trim() || `${command.command} exited with ${code}`));
      }
    });

    child.stdin.end(text);
  });
}
