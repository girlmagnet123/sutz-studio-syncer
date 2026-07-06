--!nonstrict

local ScriptEditorService = game:GetService("ScriptEditorService")
local HttpService = game:GetService("HttpService")

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
	self.lastError = nil
	self.connectedUrl = nil
	self.baseUrl = Config.WS_URL
	self.activityHandlers = {}
	self.stateHandlers = {}

	return self
end

local function stringifyList(...)
	local parts = {}
	for index = 1, select("#", ...) do
		table.insert(parts, tostring(select(index, ...)))
	end
	return table.concat(parts, " ")
end

local function trim(value)
	return string.gsub(tostring(value or ""), "^%s*(.-)%s*$", "%1")
end

local function preferIpv4Loopback(url)
	return (string.gsub(url, "^(wss?://)localhost([:/]?)", function(scheme, separator)
		return scheme .. "127.0.0.1" .. separator
	end))
end

local function makeWebSocketUrl(scheme, host, port)
	return string.format("%s://%s:%d", scheme or "ws", host or "127.0.0.1", port or 8181)
end

local function normalizeWebSocketUrl(url)
	local value = trim(url)

	if value == "" then
		return "ws://127.0.0.1:8181"
	end

	if string.match(value, "^%d+$") then
		return "ws://127.0.0.1:" .. value
	end

	local portOnly = string.match(value, "^:(%d+)$")
	if portOnly then
		return "ws://127.0.0.1:" .. portOnly
	end

	if string.match(value, "^https://") then
		return preferIpv4Loopback("wss://" .. string.sub(value, 9))
	end

	if string.match(value, "^http://") then
		return preferIpv4Loopback("ws://" .. string.sub(value, 8))
	end

	if string.match(value, "^wss?://") then
		return preferIpv4Loopback(value)
	end

	return preferIpv4Loopback("ws://" .. value)
end

local function parseUrl(url)
	local normalized = normalizeWebSocketUrl(url)
	local scheme, host, port = string.match(normalized, "^(wss?)://([^:/]+):(%d+)")

	if not host then
		scheme, host = string.match(normalized, "^(wss?)://([^:/]+)")
		port = nil
	end

	return host or "127.0.0.1", tonumber(port) or 8181, normalized, scheme or "ws"
end

function SyncSession.normalizeWebSocketUrl(url)
	return normalizeWebSocketUrl(url)
end

function SyncSession:setBaseUrl(url)
	self.baseUrl = normalizeWebSocketUrl(url)
	Config.WS_URL = self.baseUrl
	return self.baseUrl
end

function SyncSession:getBaseUrl()
	return self.baseUrl or Config.WS_URL
end

function SyncSession:getConnectedUrl()
	return self.connectedUrl
end

-- Probe http://host:port upward from the configured base port and return the
-- ws URL of the first daemon that has no Studio paired with it yet. This is how
-- a second Studio automatically lands on a second `sutz` instead of stealing
-- the first one.
function SyncSession:discoverFreeUrl(baseUrl)
	local host, basePort, _, wsScheme = parseUrl(baseUrl or self:getBaseUrl())
	local httpScheme = if wsScheme == "wss" then "https" else "http"
	local scanCount = math.max(1, Config.PORT_SCAN_COUNT or 1)
	local sawBusy = false
	local sawHttpResponse = false

	for offset = 0, scanCount - 1 do
		local port = basePort + offset
		local ok, body = pcall(function()
			return HttpService:GetAsync(string.format("%s://%s:%d/status", httpScheme, host, port))
		end)

		if ok then
			sawHttpResponse = true
			local decodedOk, status = pcall(function()
				return HttpService:JSONDecode(body)
			end)

			if decodedOk and type(status) == "table" and status.sutz then
				if status.paired then
					sawBusy = true
				else
					return makeWebSocketUrl(wsScheme, host, port), "ok"
				end
			end
		end
	end

	if sawBusy then
		return nil, "allBusy"
	end

	return nil, if sawHttpResponse then "none" else "probeFailed"
end

function SyncSession:getCandidateUrls(baseUrl)
	local host, basePort, _, wsScheme = parseUrl(baseUrl or self:getBaseUrl())
	local scanCount = math.max(1, Config.PORT_SCAN_COUNT or 1)
	local urls = {}

	for offset = 0, scanCount - 1 do
		table.insert(urls, makeWebSocketUrl(wsScheme, host, basePort + offset))
	end

	return urls
end

function SyncSession:isRunning()
	return self.running
end

function SyncSession:onActivity(callback)
	table.insert(self.activityHandlers, callback)
end

function SyncSession:onStateChanged(callback)
	table.insert(self.stateHandlers, callback)
end

function SyncSession:emitActivity(...)
	local text = stringifyList(...)
	for _, callback in ipairs(self.activityHandlers) do
		task.spawn(callback, text)
	end
end

function SyncSession:emitState()
	for _, callback in ipairs(self.stateHandlers) do
		task.spawn(callback, self.running, self.lastError, self.connectedUrl)
	end
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

	local snapshot = StudioScanner.snapshot(false)
	local scripts = {}

	for _, record in ipairs(snapshot) do
		local instance = self:findInstanceByPath(record.path)
		if instance then
			self.guidToInstance[record.guid] = instance
			self.instanceToGuid[instance] = record.guid
			if StudioScanner.isScript(instance) then
				table.insert(scripts, instance)
			end
		end
	end

	self:send({
		type = Protocol.ClientMessage.SNAPSHOT,
		instances = snapshot,
	})

	for index, instance in ipairs(scripts) do
		local record = StudioScanner.toRecord(instance, true)
		if record then
			self:send({
				type = Protocol.ClientMessage.SCRIPT_CHANGED,
				guid = record.guid,
				path = record.path,
				className = record.className,
				source = record.source,
			})
		end

		if index % 25 == 0 then
			task.wait()
		end
	end

	log("Snapshot sent:", #snapshot, "instances,", #scripts, "scripts")
	self:emitActivity("Snapshot sent:", #snapshot, "instances,", #scripts, "scripts")
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

local function isScriptClass(className)
	return className == "Script" or className == "LocalScript" or className == "ModuleScript"
end

function SyncSession:findOrCreateParent(path)
	if type(path) ~= "table" or #path < 2 then
		return nil, "Path must include a service and script name."
	end

	local ok, current = pcall(function()
		return game:GetService(path[1])
	end)

	if not ok or not current then
		return nil, string.format("Unknown service: %s", tostring(path[1]))
	end

	for index = 2, #path - 1 do
		local segment = path[index]
		if type(segment) ~= "string" or segment == "" then
			return nil, "Path contains an empty folder name."
		end

		local child = current:FindFirstChild(segment)
		if not child then
			child = Instance.new("Folder")
			child.Name = segment
			child.Parent = current
		end

		current = child
	end

	return current, nil
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
		warn(string.format("{Sutz Syncer} Updated: {%s}", instance:GetFullName()))
		debugLog("Patched script:", instance:GetFullName())
		self:emitActivity("Patched from file:", instance:GetFullName())
	else
		warn("[Sutz Syncer] Failed to patch script:", err)
		self:emitActivity("Patch failed:", tostring(err))
	end
end

function SyncSession:upsertScript(message)
	local scriptPath = message.path
	local className = message.className
	local source = message.source

	if type(scriptPath) ~= "table" or not isScriptClass(className) or type(source) ~= "string" then
		self:emitActivity("Ignored invalid upsertScript message.")
		return
	end

	local parent, parentError = self:findOrCreateParent(scriptPath)
	if not parent then
		warn("[Sutz Syncer] Could not create script from file:", parentError)
		self:emitActivity("Create from file failed:", parentError)
		return
	end

	local scriptName = scriptPath[#scriptPath]
	if type(scriptName) ~= "string" or scriptName == "" then
		self:emitActivity("Create from file failed: empty script name.")
		return
	end

	local instance = parent:FindFirstChild(scriptName)
	if instance and not StudioScanner.isScript(instance) then
		local messageText = string.format("Path already exists and is not a script: %s", instance:GetFullName())
		warn("[Sutz Syncer]", messageText)
		self:emitActivity("Create from file failed:", messageText)
		return
	end

	if instance and instance.ClassName ~= className then
		local messageText = string.format(
			"Path already exists as %s, not %s: %s",
			instance.ClassName,
			className,
			instance:GetFullName()
		)
		warn("[Sutz Syncer]", messageText)
		self:emitActivity("Create from file failed:", messageText)
		return
	end

	local created = false
	self.applyingPatch = true
	local ok, err = pcall(function()
		if not instance then
			instance = Instance.new(className)
			instance.Name = scriptName
			instance.Parent = parent
			created = true
		end

		ScriptEditorService:UpdateSourceAsync(instance, function()
			return source
		end)
	end)
	self.applyingPatch = false

	if not ok then
		warn("[Sutz Syncer] Failed to create script from file:", err)
		self:emitActivity("Create from file failed:", tostring(err))
		return
	end

	local record = StudioScanner.toRecord(instance, true)
	if record then
		self:indexInstance(instance)
		self:send({
			type = Protocol.ClientMessage.SCRIPT_CHANGED,
			guid = record.guid,
			path = record.path,
			className = record.className,
			source = record.source,
		})
	end

	local verb = created and "Created from file:" or "Updated from file:"
	self:emitActivity(verb, table.concat(scriptPath, "/"))
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
	self:emitActivity("Studio script changed:", table.concat(record.path, "/"))
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
	self:emitActivity("Instance changed:", table.concat(record.path, "/"))
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
		self:emitActivity("Daemon requested snapshot")
		self:sendSnapshot()
	elseif message.type == Protocol.ServerMessage.PATCH_SCRIPT then
		self:applyPatch(message)
	elseif message.type == Protocol.ServerMessage.UPSERT_SCRIPT then
		self:upsertScript(message)
	elseif message.type == Protocol.ServerMessage.PING then
		self:send({ type = Protocol.ClientMessage.PONG })
	elseif message.type == Protocol.ServerMessage.DISCONNECT then
		self:stop()
	elseif message.type == Protocol.ServerMessage.BUSY then
		self.lastError = "That daemon is already paired with another Studio. Reconnect to pair with a free one."
		warn("[Sutz Syncer]", self.lastError)
		self:stop()
	end
end

function SyncSession:connectToUrl(url)
	local client = WebSocketClient.new(url)
	local handshakeEvent = Instance.new("BindableEvent")
	local queuedMessages = {}
	local forwarding = false
	local resolved = false
	local accepted = false
	local failureReason = nil

	local function finish(ok, reason)
		if resolved then
			return
		end

		resolved = true
		accepted = ok == true
		failureReason = reason
		handshakeEvent:Fire()
	end

	client:onMessage(function(message)
		if not forwarding then
			if type(message) == "table" and message.type == Protocol.ServerMessage.BUSY then
				finish(false, "busy")
			else
				table.insert(queuedMessages, message)
				finish(true, "ok")
			end
			return
		end

		self:handleMessage(message)
	end)

	client:onClose(function()
		if not forwarding then
			finish(false, "closed")
		elseif self.running then
			log("Daemon connection closed")
			self.lastError = "Daemon connection closed."
			self:emitActivity(self.lastError)
			self:stop()
		end
	end)

	client:onError(function(err)
		if not forwarding then
			finish(false, tostring(err))
		else
			warn("[Sutz Syncer] WebSocket error:", err)
			self.lastError = tostring(err)
			self:emitActivity("WebSocket error:", tostring(err))
			if self.running then
				self:stop()
			else
				self:emitState()
			end
		end
	end)

	if not client:connect() then
		client:close()
		handshakeEvent:Destroy()
		return false, failureReason or "connectFailed"
	end

	local sent = client:send({
		type = Protocol.ClientMessage.HELLO,
		protocolVersion = Config.PROTOCOL_VERSION,
		client = "roblox-studio-plugin",
	})

	if not sent then
		client:close()
		handshakeEvent:Destroy()
		return false, "sendFailed"
	end

	task.delay(Config.WS_CONNECT_TIMEOUT or 1.5, function()
		finish(false, "timeout")
	end)

	handshakeEvent.Event:Wait()
	handshakeEvent:Destroy()

	if not accepted then
		client:close()
		return false, failureReason or "connectFailed"
	end

	self.client = client

	local function enableForwarding()
		forwarding = true
	end

	return true, "ok", queuedMessages, enableForwarding
end

function SyncSession:start(baseUrl)
	if self.running then
		return true
	end

	self.lastError = nil
	self.client = nil

	local configuredUrl = self:setBaseUrl(baseUrl or Config.WS_URL)
	local discoveredUrl, reason = self:discoverFreeUrl(configuredUrl)
	local candidateUrls = {}

	if discoveredUrl then
		table.insert(candidateUrls, discoveredUrl)
		for _, url in ipairs(self:getCandidateUrls(configuredUrl)) do
			if url ~= discoveredUrl then
				table.insert(candidateUrls, url)
			end
		end
	elseif reason == "allBusy" then
		self.lastError = "Every running `sutz` is already paired with a Studio. Run `sutz` again in another terminal, then connect."
		warn("[Sutz Syncer]", self.lastError)
		self.connectedUrl = nil
		self:emitState()
		return false
	else
		candidateUrls = self:getCandidateUrls(configuredUrl)
		debugLog("HTTP discovery failed; trying WebSocket ports directly.")
	end

	local connectedUrl = nil
	local queuedMessages = nil
	local enableForwarding = nil
	local sawBusy = false
	local lastFailure = reason

	for _, url in ipairs(candidateUrls) do
		log("Connecting to", url)
		self:emitActivity("Connecting to", url)

		local connected, failure, messages, forward = self:connectToUrl(url)
		if connected then
			connectedUrl = url
			queuedMessages = messages or {}
			enableForwarding = forward
			break
		else
			lastFailure = failure
			if failure == "busy" then
				sawBusy = true
				debugLog("Daemon busy:", url)
			else
				debugLog("Connection attempt failed:", url, tostring(failure))
			end
		end
	end

	if not connectedUrl then
		if sawBusy or reason == "allBusy" then
			self.lastError = "Every running `sutz` is already paired with a Studio. Run `sutz` again in another terminal, then connect."
		else
			self.lastError = "No `sutz` daemon found. Run `sutz` in a terminal first."
		end
		warn("[Sutz Syncer]", self.lastError)
		self.connectedUrl = nil
		self:emitState()
		return false
	end

	self.connectedUrl = connectedUrl
	self.running = true
	self:emitState()
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
			self:emitActivity("Instance removed:", guid)
		end
	end))

	if enableForwarding then
		enableForwarding()
	end

	for _, message in ipairs(queuedMessages or {}) do
		self:handleMessage(message)
	end

	log("Sync started")
	self:emitActivity("Sync started")
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
	self.connectedUrl = nil

	log("Sync stopped")
	self:emitActivity("Sync stopped")
	self:emitState()
end

return SyncSession
