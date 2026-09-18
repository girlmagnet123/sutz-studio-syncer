--!nonstrict

local Config = {
	PROTOCOL_VERSION = 1,
	WS_URL = "ws://127.0.0.1:8181",
	DEBUG = true,

	-- How many ports to probe upward from the WS_URL port when auto-discovering
	-- a free daemon. Each `sutz` instance binds the next free port, so this lets
	-- multiple Studios each pair with their own daemon automatically.
	PORT_SCAN_COUNT = 10,
	WS_CONNECT_TIMEOUT = 1.5,
	SNAPSHOT_ACK_TIMEOUT = 30,
	SNAPSHOT_MAX_BYTES = 48 * 1024,
	SNAPSHOT_MAX_RECORDS = 200,

	-- Keep the first version conservative. We can make this user-configurable
	-- after the daemon and installer are in place.
	SYNC_SERVICES = {
		Workspace = true,
		ReplicatedFirst = true,
		ReplicatedStorage = true,
		ServerScriptService = true,
		ServerStorage = true,
		StarterGui = true,
		StarterPack = true,
		StarterPlayer = true,
	},
}

return Config
