--!nonstrict

local Protocol = {}

Protocol.ClientMessage = {
	HELLO = "hello",
	SNAPSHOT = "snapshot",
	SCRIPT_CHANGED = "scriptChanged",
	INSTANCE_CHANGED = "instanceChanged",
	INSTANCE_REMOVED = "instanceRemoved",
	COPY_TO_CLIPBOARD = "copyToClipboard",
	PONG = "pong",
}

Protocol.ServerMessage = {
	REQUEST_SNAPSHOT = "requestSnapshot",
	PATCH_SCRIPT = "patchScript",
	CLIPBOARD_RESULT = "clipboardResult",
	PING = "ping",
	DISCONNECT = "disconnect",
	BUSY = "busy",
}

return Protocol
