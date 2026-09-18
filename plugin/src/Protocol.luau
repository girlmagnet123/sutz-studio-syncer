--!nonstrict

local Protocol = {}

Protocol.ClientMessage = {
	HELLO = "hello",
	SNAPSHOT = "snapshot",
	SNAPSHOT_START = "snapshotStart",
	SNAPSHOT_CHUNK = "snapshotChunk",
	SNAPSHOT_END = "snapshotEnd",
	MESSAGE_CHUNK = "messageChunk",
	SCRIPT_CHANGED = "scriptChanged",
	INSTANCE_CHANGED = "instanceChanged",
	INSTANCE_REMOVED = "instanceRemoved",
	COPY_TO_CLIPBOARD = "copyToClipboard",
	PONG = "pong",
}

Protocol.ServerMessage = {
	REQUEST_SNAPSHOT = "requestSnapshot",
	MESSAGE_ACK = "messageAck",
	SNAPSHOT_ACK = "snapshotAck",
	SNAPSHOT_ERROR = "snapshotError",
	PATCH_SCRIPT = "patchScript",
	UPSERT_SCRIPT = "upsertScript",
	CLIPBOARD_RESULT = "clipboardResult",
	PING = "ping",
	DISCONNECT = "disconnect",
	BUSY = "busy",
}

return Protocol
