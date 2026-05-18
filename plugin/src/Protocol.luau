--!nonstrict

local Protocol = {}

Protocol.ClientMessage = {
	HELLO = "hello",
	SNAPSHOT = "snapshot",
	SCRIPT_CHANGED = "scriptChanged",
	INSTANCE_CHANGED = "instanceChanged",
	INSTANCE_REMOVED = "instanceRemoved",
	PONG = "pong",
}

Protocol.ServerMessage = {
	REQUEST_SNAPSHOT = "requestSnapshot",
	PATCH_SCRIPT = "patchScript",
	PING = "ping",
	DISCONNECT = "disconnect",
}

return Protocol
