--!nonstrict

local ScriptEditorService = game:GetService("ScriptEditorService")

local Config = require(script.Parent.Config)
local Protocol = require(script.Parent.Protocol)
local StudioScanner = require(script.Parent.StudioScanner)
local WebSocketClient = require(script.Parent.WebSocketClient)

local SyncSession = {}
SyncSession.__index = SyncSession

local function log(...)
	print("[Sutz Syncer]", ...)
end

local function debugLog(...)
	if Config.DEBUG then
		print("[Sutz Syncer:debug]", ...)
	end
end

function SyncSession.new()
	local self = setmetatable({}, SyncSession)

	self.client = nil
	self.running = false
	self.connections = {}
	self.guidToInstance = {}
	self.instanceToGuid = {}
	self.applyingPatch = false

	return self
end

function SyncSession:isRunning()
	return self.running
end

function SyncSession:send(message)
	if not self.client then
		return false
	end

	return self.client:send(message)
end

function SyncSession:indexInstance(instance)
	local guid = StudioScanner.getGuid(instance)
	if guid then
		self.guidToInstance[guid] = instance
		self.instanceToGuid[instance] = guid
	end

	return guid
end

function SyncSession:sendSnapshot()
	self.guidToInstance = {}
	self.instanceToGuid = {}

	local snapshot = StudioScanner.snapshot()

	for _, record in ipairs(snapshot) do
		local instance = self:findInstanceByPath(record.path)
		if instance then
			self.guidToInstance[record.guid] = instance
			self.instanceToGuid[instance] = record.guid
		end
	end

	self:send({
		type = Protocol.ClientMessage.SNAPSHOT,
		instances = snapshot,
	})

	log("Snapshot sent:", #snapshot, "instances")
end

function SyncSession:findInstanceByPath(path)
	local current = game

	for index, segment in ipairs(path) do
		local nextInstance = nil

		if index == 1 then
			local ok, service = pcall(function()
				return game:GetService(segment)
			end)
			if ok then
				nextInstance = service
			end
		end

		if not nextInstance then
			nextInstance = current:FindFirstChild(segment)
		end

		if not nextInstance then
			return nil
		end

		current = nextInstance
	end

	return current
end

function SyncSession:applyPatch(message)
	local guid = message.guid
	local source = message.source

	if type(guid) ~= "string" or type(source) ~= "string" then
		return
	end

	local instance = self.guidToInstance[guid]
	if not instance or not StudioScanner.isScript(instance) then
		warn("[Sutz Syncer] Cannot patch script; GUID not found:", guid)
		return
	end

	self.applyingPatch = true
	local ok, err = pcall(function()
		ScriptEditorService:UpdateSourceAsync(instance, function()
			return source
		end)
	end)
	self.applyingPatch = false

	if ok then
		debugLog("Patched script:", instance:GetFullName())
	else
		warn("[Sutz Syncer] Failed to patch script:", err)
	end
end

function SyncSession:onStudioScriptChanged(instance)
	if self.applyingPatch or not self.running then
		return
	end

	if not StudioScanner.isIncluded(instance) or not StudioScanner.isScript(instance) then
		return
	end

	local record = StudioScanner.toRecord(instance)
	if not record then
		return
	end

	self:indexInstance(instance)
	self:send({
		type = Protocol.ClientMessage.SCRIPT_CHANGED,
		guid = record.guid,
		path = record.path,
		className = record.className,
		source = record.source,
	})
end

function SyncSession:onInstanceChanged(instance)
	if self.applyingPatch or not self.running then
		return
	end

	local record = StudioScanner.toRecord(instance)
	if not record then
		return
	end

	self:indexInstance(instance)
	self:send({
		type = Protocol.ClientMessage.INSTANCE_CHANGED,
		instance = record,
	})
end

function SyncSession:attachInstance(instance)
	if not StudioScanner.isIncluded(instance) then
		return
	end

	self:indexInstance(instance)

	table.insert(self.connections, instance:GetPropertyChangedSignal("Name"):Connect(function()
		self:onInstanceChanged(instance)
	end))

	table.insert(self.connections, instance:GetPropertyChangedSignal("Parent"):Connect(function()
		if instance.Parent then
			self:onInstanceChanged(instance)
		end
	end))

	if StudioScanner.isScript(instance) then
		table.insert(self.connections, instance:GetPropertyChangedSignal("Source"):Connect(function()
			self:onStudioScriptChanged(instance)
		end))
	end
end

function SyncSession:attachExistingListeners()
	for _, descendant in ipairs(game:GetDescendants()) do
		self:attachInstance(descendant)
	end
end

function SyncSession:handleMessage(message)
	if type(message) ~= "table" or type(message.type) ~= "string" then
		return
	end

	debugLog("Received:", message.type)

	if message.type == Protocol.ServerMessage.REQUEST_SNAPSHOT then
		self:sendSnapshot()
	elseif message.type == Protocol.ServerMessage.PATCH_SCRIPT then
		self:applyPatch(message)
	elseif message.type == Protocol.ServerMessage.PING then
		self:send({ type = Protocol.ClientMessage.PONG })
	elseif message.type == Protocol.ServerMessage.DISCONNECT then
		self:stop()
	end
end

function SyncSession:start()
	if self.running then
		return true
	end

	log("Connecting to", Config.WS_URL)

	self.client = WebSocketClient.new(Config.WS_URL)
	self.client:onMessage(function(message)
		self:handleMessage(message)
	end)
	self.client:onClose(function()
		if self.running then
			log("Daemon connection closed")
			self:stop()
		end
	end)
	self.client:onError(function(err)
		warn("[Sutz Syncer] WebSocket error:", err)
	end)

	if not self.client:connect() then
		warn("[Sutz Syncer] Could not connect. Is the daemon running?")
		self.client = nil
		return false
	end

	self.running = true
	self:attachExistingListeners()

	table.insert(self.connections, game.DescendantAdded:Connect(function(instance)
		self:attachInstance(instance)
		self:onInstanceChanged(instance)
	end))

	table.insert(self.connections, game.DescendantRemoving:Connect(function(instance)
		local guid = self.instanceToGuid[instance]
		if guid then
			self:send({
				type = Protocol.ClientMessage.INSTANCE_REMOVED,
				guid = guid,
			})
		end
	end))

	self:send({
		type = Protocol.ClientMessage.HELLO,
		protocolVersion = Config.PROTOCOL_VERSION,
		client = "roblox-studio-plugin",
	})

	self:sendSnapshot()
	log("Sync started")
	return true
end

function SyncSession:stop()
	if not self.running and not self.client then
		return
	end

	self.running = false

	for _, connection in ipairs(self.connections) do
		connection:Disconnect()
	end
	self.connections = {}

	if self.client then
		self.client:close()
	end

	self.client = nil
	self.guidToInstance = {}
	self.instanceToGuid = {}

	log("Sync stopped")
end

return SyncSession
