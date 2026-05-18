import { createServer, type Server } from "node:http";
import { WebSocket, WebSocketServer } from "ws";
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
}

export class SutzDaemon {
  private readonly port: number;
  private readonly host: string;
  private httpServer: Server | null = null;
  private socketServer: WebSocketServer | null = null;
  private studioClient: WebSocket | null = null;
  private instances = new Map<string, StudioInstanceRecord>();

  public constructor(options: DaemonOptions) {
    this.port = options.port;
    this.host = options.host;
  }

  public async start(): Promise<void> {
    if (this.httpServer || this.socketServer) {
      return;
    }

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
  }

  public async stop(): Promise<void> {
    this.send({ type: ServerMessageType.Disconnect });

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
    if (this.studioClient) {
      console.warn("Replacing existing Studio connection.");
      this.studioClient.close();
    }

    this.studioClient = socket;
    console.log("Studio connected.");
    this.send({ type: ServerMessageType.RequestSnapshot });

    socket.on("message", (raw) => {
      this.handleRawMessage(raw.toString());
    });

    socket.on("close", () => {
      if (this.studioClient === socket) {
        this.studioClient = null;
      }
      console.log("Studio disconnected.");
    });

    socket.on("error", (error) => {
      console.error("Studio socket error:", error);
    });
  }

  private handleRawMessage(raw: string): void {
    let message: ClientMessage;

    try {
      message = JSON.parse(raw) as ClientMessage;
    } catch {
      console.warn("Ignored invalid JSON message from Studio.");
      return;
    }

    this.handleMessage(message);
  }

  private handleMessage(message: ClientMessage): void {
    switch (message.type) {
      case ClientMessageType.Hello:
        console.log(
          `Studio hello: ${message.client} protocol v${message.protocolVersion}`,
        );
        break;

      case ClientMessageType.Snapshot:
        this.instances.clear();
        for (const instance of message.instances) {
          this.instances.set(instance.guid, instance);
        }
        console.log(`Snapshot received: ${message.instances.length} instances.`);
        break;

      case ClientMessageType.ScriptChanged:
        this.instances.set(message.guid, {
          guid: message.guid,
          className: message.className,
          name: message.path[message.path.length - 1] ?? "Script",
          path: message.path,
          source: message.source,
        });
        console.log(`Script changed: ${message.path.join("/")}`);
        break;

      case ClientMessageType.InstanceChanged:
        this.instances.set(message.instance.guid, message.instance);
        console.log(`Instance changed: ${message.instance.path.join("/")}`);
        break;

      case ClientMessageType.InstanceRemoved:
        this.instances.delete(message.guid);
        console.log(`Instance removed: ${message.guid}`);
        break;

      case ClientMessageType.Pong:
        break;
    }
  }

  private send(message: ServerMessage): boolean {
    if (!this.studioClient || this.studioClient.readyState !== WebSocket.OPEN) {
      return false;
    }

    this.studioClient.send(JSON.stringify(message));
    return true;
  }
}
