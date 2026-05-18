--!nonstrict

local Config = {
	PROTOCOL_VERSION = 1,
	WS_URL = "ws://localhost:8181",
	DEBUG = true,

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
