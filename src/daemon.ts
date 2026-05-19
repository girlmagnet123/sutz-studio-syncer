import { createServer, type Server } from "node:http";
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
}

export class SutzDaemon {
  private readonly port: number;
  private readonly host: string;
  private httpServer: Server | null = null;
  private socketServer: WebSocketServer | null = null;
  private studioClient: WebSocket | null = null;
  private instances = new Map<string, StudioInstanceRecord>();
  private fileWriter: FileWriter;
  private fileWatcher: fs.FSWatcher | null = null;
  private readonly guidToFilePath = new Map<string, string>();
  private readonly filePathToGuid = new Map<string, string>();
  private readonly pendingFileTimers = new Map<string, NodeJS.Timeout>();

  public constructor(options: DaemonOptions) {
    this.port = options.port;
    this.host = options.host;
    this.fileWriter = new FileWriter({ rootDir: options.syncDir });
  }

  public async start(): Promise<void> {
    if (this.httpServer || this.socketServer) {
      return;
    }

    this.fileWriter.ensureRoot();
    this.startFileWatcher();

    this.httpServer = createServer((_, response) => {
      response.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
      response.end("Sutz Studio Syncer daemon is running.\n");
    });

    this.socketServer = new WebSocketServer({
      server: this.httpServer,
      maxPayload: 128 * 1024 * 1024,
    });

    this.socketServer.on("connection", (socket) => {
      this.handleConnection(socket);
    });

    await new Promise<void>((resolve, reject) => {
      this.httpServer!.once("error", reject);
      this.httpServer!.listen(this.port, this.host, () => {
        this.httpServer!.off("error", reject);
        resolve();
      });
    });

    console.log(`Sutz daemon listening on ws://${this.host}:${this.port}`);
    console.log(`Sync folder: ${path.relative(process.cwd(), this.fileWriter.getRootDir()) || "."}`);
  }

  public async stop(): Promise<void> {
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
      this.handleRawMessage(socket, raw.toString());
    });

    socket.on("close", () => {
      if (this.studioClient === socket) {
        this.studioClient = null;
        console.log("Studio disconnected.");
      }
    });

    socket.on("error", (error) => {
      console.error("Studio socket error:", error);
    });
  }

  private handleRawMessage(socket: WebSocket, raw: string): void {
    let message: ClientMessage;

    try {
      message = JSON.parse(raw) as ClientMessage;
    } catch {
      console.warn("Ignored invalid JSON message from Studio.");
      return;
    }

    this.handleMessage(socket, message);
  }

  private handleMessage(socket: WebSocket, message: ClientMessage): void {
    switch (message.type) {
      case ClientMessageType.Hello:
        if (this.studioClient && this.studioClient !== socket) {
          console.warn("Replacing existing Studio connection.");
          this.studioClient.close();
        }

        this.studioClient = socket;
        console.log("Studio connected.");
        this.sendTo(socket, { type: ServerMessageType.RequestSnapshot });
        console.log(
          `Studio hello: ${message.client} protocol v${message.protocolVersion}`,
        );
        break;

      case ClientMessageType.Snapshot:
        this.instances.clear();
        this.guidToFilePath.clear();
        this.filePathToGuid.clear();
        for (const instance of message.instances) {
          this.instances.set(instance.guid, instance);
        }
        {
          const written = this.fileWriter.writeSnapshot(message.instances);
          this.indexSyncedScripts(message.instances);
          console.log(`Wrote ${written} script file(s) to sync folder.`);
        }
        console.log(`Snapshot received: ${message.instances.length} instances.`);
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

    if (!this.filePathToGuid.has(normalizedPath)) {
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

  private indexSyncedScripts(instances: StudioInstanceRecord[]): void {
    for (const instance of instances) {
      this.indexSyncedScript(instance);
    }
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
