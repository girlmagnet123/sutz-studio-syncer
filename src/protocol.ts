export const ClientMessageType = {
  Hello: "hello",
  Snapshot: "snapshot",
  ScriptChanged: "scriptChanged",
  InstanceChanged: "instanceChanged",
  InstanceRemoved: "instanceRemoved",
  CopyToClipboard: "copyToClipboard",
  Pong: "pong",
} as const;

export const ServerMessageType = {
  RequestSnapshot: "requestSnapshot",
  PatchScript: "patchScript",
  ClipboardResult: "clipboardResult",
  Ping: "ping",
  Disconnect: "disconnect",
  Busy: "busy",
} as const;

export interface StudioInstanceRecord {
  guid: string;
  className: string;
  name: string;
  path: string[];
  parentGuid?: string;
  source?: string;
}

export type ClientMessage =
  | {
      type: typeof ClientMessageType.Hello;
      protocolVersion: number;
      client: string;
    }
  | {
      type: typeof ClientMessageType.Snapshot;
      instances: StudioInstanceRecord[];
    }
  | {
      type: typeof ClientMessageType.ScriptChanged;
      guid: string;
      path: string[];
      className: string;
      source: string;
    }
  | {
      type: typeof ClientMessageType.InstanceChanged;
      instance: StudioInstanceRecord;
    }
  | {
      type: typeof ClientMessageType.InstanceRemoved;
      guid: string;
    }
  | {
      type: typeof ClientMessageType.CopyToClipboard;
      text: string;
      requestId?: string;
    }
  | {
      type: typeof ClientMessageType.Pong;
    };

export type ServerMessage =
  | {
      type: typeof ServerMessageType.RequestSnapshot;
    }
  | {
      type: typeof ServerMessageType.PatchScript;
      guid: string;
      source: string;
    }
  | {
      type: typeof ServerMessageType.ClipboardResult;
      ok: boolean;
      requestId?: string;
      error?: string;
    }
  | {
      type: typeof ServerMessageType.Ping;
    }
  | {
      type: typeof ServerMessageType.Disconnect;
    }
  | {
      type: typeof ServerMessageType.Busy;
    };
