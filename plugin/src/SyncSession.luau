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
	self.snapshotBatches = false
	self.snapshot = nil
	self.attachedInstances = {}

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

function SyncSession:isSnapshotCurrent(state)
	return self.running and self.client == state.client and state.client.connected
		and self.snapshot == state and not state.cancelled and not state.error
end

function SyncSession:failSnapshot(state, reason)
	state.error = tostring(reason)
	-- A cancelled worker must never close the replacement connection/snapshot.
	if self.snapshot ~= state or self.client ~= state.client then
		return false
	end
	self.lastError = "Snapshot failed: " .. state.error
	warn("[Sutz Syncer]", self.lastError)
	self:emitActivity(self.lastError)
	-- Closing also discards the daemon's incomplete transaction. It must not
	-- prune files or accept live edits against a half-received snapshot.
	self:stop()
	return false
end

function SyncSession:sendSnapshotStep(state, sequence, message, encoded)
	if not self:isSnapshotCurrent(state) then
		return false, state.error or "Snapshot cancelled."
	end
	state.waitingFor = sequence
	state.acknowledged = false
	local ok, err, bytes
	if encoded then
		ok, err, bytes = state.client:sendEncoded(encoded)
	else
		ok, err, bytes = state.client:send(message)
	end
	if not ok then
		return false, err or "Could not send snapshot."
	end
	state.totalBytes += bytes or 0
	debugLog("Snapshot message:", state.id, "sequence", sequence, bytes, "bytes")
	local deadline = os.clock() + (Config.SNAPSHOT_ACK_TIMEOUT or 30)
	while self:isSnapshotCurrent(state) and not state.acknowledged do
		if os.clock() >= deadline then
			return false, "Daemon did not acknowledge snapshot sequence " .. tostring(sequence)
				.. ". Rebuild/restart the daemon and reconnect."
		end
		task.wait(0.03)
	end
	if not self:isSnapshotCurrent(state) then
		return false, state.error or "Snapshot cancelled."
	end
	state.waitingFor = nil
	return true
end

function SyncSession:markSnapshotDirty(instance, includeDescendants)
	local state = self.snapshot
	if not state then
		return false
	end
	state.dirtyInstances[instance] = true
	if includeDescendants then
		state.dirtyRoots[instance] = true
	end
	return true
end

function SyncSession:reconcileSnapshot(state)
	-- Keep only an instance set, not a copy of every intermediate event/source.
	-- Events during a yield go into the next pass, which reads the latest state.
	while next(state.dirtyInstances) or next(state.dirtyRoots) do
		local dirtyInstances = state.dirtyInstances
		local dirtyRoots = state.dirtyRoots
		state.dirtyInstances = {}
		state.dirtyRoots = {}
		local sent = {}
		local count = 0
		local failure = nil
		local function reconcile(instance)
			if not self:isSnapshotCurrent(state) then
				failure = state.error or "Snapshot cancelled."
				return false
			end
			if sent[instance] then
				return "skip"
			end
			sent[instance] = true
			local record = StudioScanner.toRecord(instance, true)
			local message = nil
			if record then
				self:indexInstance(instance)
				message = { type = Protocol.ClientMessage.INSTANCE_CHANGED, instance = record }
			else
				local guid = self.instanceToGuid[instance]
				if guid then
					message = { type = Protocol.ClientMessage.INSTANCE_REMOVED, guid = guid }
					self.instanceToGuid[instance] = nil
					self.guidToInstance[guid] = nil
				end
			end
			if message then
				local ok, err = state.client:send(message)
				if not ok then
					failure = err or "Could not reconcile an instance changed during snapshot."
					return false
				end
			end
			count += 1
			if count % 25 == 0 then
				task.wait()
			end
			return true
		end
		for root in pairs(dirtyRoots) do
			if not StudioScanner.visitInstances(reconcile, root) then
				return false, failure
			end
		end
		for instance in pairs(dirtyInstances) do
			if not reconcile(instance) then
				return false, failure
			end
		end
	end
	return self:isSnapshotCurrent(state), state.error
end

function SyncSession:sendSnapshot()
	if not self.running or not self.client then
		return false
	end
	if not self.snapshotBatches or not self.client.messageChunks then
		self.lastError = "This daemon does not support snapshot batches and message fragments. Run npm run build, restart sutz, and reconnect."
		self:emitActivity(self.lastError)
		self:stop()
		return false
	end

	if self.snapshot then
		self.snapshot.cancelled = true
	end
	local state = {
		id = HttpService:GenerateGUID(false),
		client = self.client,
		dirtyInstances = {},
		dirtyRoots = {},
		totalBytes = 0,
	}
	self.snapshot = state
	local completed, result = pcall(function()
		local ok, err = self:sendSnapshotStep(state, -1, {
			type = Protocol.ClientMessage.SNAPSHOT_START,
			snapshotId = state.id,
		})
		if not ok then
			return self:failSnapshot(state, err)
		end

		local maxBytes = math.min(Config.SNAPSHOT_MAX_BYTES or 48 * 1024, 48 * 1024)
		local maxRecords = math.min(Config.SNAPSHOT_MAX_RECORDS or 200, 200)
		local records = {}
		local recordBytes = 0
		local sequence = 0
		local instanceCount = 0
		local scripts = {}
		local seen = {}
		local prefix = ""
		local function updatePrefix()
			local header = HttpService:JSONEncode({
				type = Protocol.ClientMessage.SNAPSHOT_CHUNK,
				snapshotId = state.id,
				sequence = sequence,
			})
			prefix = string.sub(header, 1, -2) .. ',"instances":['
		end
		updatePrefix()
		local function flush()
			if #records == 0 then
				return true
			end
			local encoded = prefix .. table.concat(records, ",") .. "]}"
			assert(#encoded <= maxBytes, "Snapshot chunk exceeded its byte limit.")
			local sent, sendError = self:sendSnapshotStep(state, sequence, nil, encoded)
			if not sent then
				err = sendError
				return false
			end
			instanceCount += #records
			sequence += 1
			records = {}
			recordBytes = 0
			updatePrefix()
			return true
		end

		local scanned = StudioScanner.visit(false, function(record, instance)
			if not self:isSnapshotCurrent(state) then
				err = state.error or "Snapshot cancelled."
				return false
			end
			-- A reparent during traversal can expose the same instance twice.
			if seen[record.guid] then
				self:markSnapshotDirty(instance, true)
				return true
			end
			seen[record.guid] = true
			self.guidToInstance[record.guid] = instance
			self.instanceToGuid[instance] = record.guid
			if StudioScanner.isScript(instance) then
				scripts[instance] = true
			end
			local encoded = HttpService:JSONEncode(record)
			local separatorBytes = if #records > 0 then 1 else 0
			if #records >= maxRecords or #prefix + recordBytes + separatorBytes + #encoded + 2 > maxBytes then
				if not flush() then
					return false
				end
			end
			if #prefix + #encoded + 2 > maxBytes then
				err = "Instance metadata cannot fit in a 48 KiB snapshot batch: " .. table.concat(record.path, "/")
					.. " (" .. tostring(#encoded) .. " bytes). Shorten its name/path and retry."
				return false
			end
			if #records > 0 then
				recordBytes += 1
			end
			table.insert(records, encoded)
			recordBytes += #encoded
			return true
		end)
		if not scanned or not flush() then
			return self:failSnapshot(state, err or "Snapshot traversal failed.")
		end
		ok, err = self:sendSnapshotStep(state, sequence, {
			type = Protocol.ClientMessage.SNAPSHOT_END,
			snapshotId = state.id,
			chunks = sequence,
			instanceCount = instanceCount,
		})
		if not ok then
			return self:failSnapshot(state, err)
		end

		local scriptCount = 0
		for instance in pairs(scripts) do
			if not self:isSnapshotCurrent(state) then
				return self:failSnapshot(state, state.error or "Snapshot cancelled.")
			end
			local record = StudioScanner.toRecord(instance, true)
			if record then
				local sent, sendError, bytes = state.client:send({
					type = Protocol.ClientMessage.SCRIPT_CHANGED,
					guid = record.guid,
					path = record.path,
					className = record.className,
					source = record.source,
				})
				if not sent then
					return self:failSnapshot(state, sendError)
				end
				scriptCount += 1
				debugLog("Snapshot script:", table.concat(record.path, "/"), bytes, "bytes")
			end
			if scriptCount % 25 == 0 then
				task.wait()
			end
		end
		ok, err = self:reconcileSnapshot(state)
		if not ok then
			return self:failSnapshot(state, err or "Snapshot cancelled.")
		end
		self.snapshot = nil
		log("Snapshot sent:", instanceCount, "instances in", sequence, "batches;", scriptCount, "scripts")
		self:emitActivity("Snapshot sent:", instanceCount, "instances in", sequence, "batches;", scriptCount,
			"scripts;", state.totalBytes, "metadata bytes")
		return true
	end)
	if not completed then
		return self:failSnapshot(state, result)
	end
	return result
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
		self:markSnapshotDirty(instance, false)
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
		if self:markSnapshotDirty(instance, false) then
			-- Parent folders can also have been created while patch callbacks were
			-- suppressed. Reconcile those records after the snapshot commits.
			local ancestor = instance.Parent
			while ancestor and ancestor ~= game do
				self:markSnapshotDirty(ancestor, false)
				ancestor = ancestor.Parent
			end
		else
			self:send({
				type = Protocol.ClientMessage.SCRIPT_CHANGED,
				guid = record.guid,
				path = record.path,
				className = record.className,
				source = record.source,
			})
		end
	end

	local verb = created and "Created from file:" or "Updated from file:"
	self:emitActivity(verb, table.concat(scriptPath, "/"))
end

function SyncSession:onStudioScriptChanged(instance)
	if not self.running then
		return
	end
	if self:markSnapshotDirty(instance, false) or self.applyingPatch then
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
	if not self.running then
		return
	end
	if self:markSnapshotDirty(instance, true) or self.applyingPatch then
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
	if not StudioScanner.isIncluded(instance) or self.attachedInstances[instance] then
		return
	end
	self.attachedInstances[instance] = true

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
	local client = self.client
	StudioScanner.visitInstances(function(instance)
		if not self.running or self.client ~= client then
			return false
		end
		self:attachInstance(instance)
		return true
	end)
end

function SyncSession:handleMessage(message)
	if type(message) ~= "table" or type(message.type) ~= "string" then
		return
	end

	debugLog("Received:", message.type)

	if message.type == Protocol.ServerMessage.REQUEST_SNAPSHOT then
		self.snapshotBatches = message.snapshotBatches == true
		if self.client then
			self.client.messageChunks = message.messageChunks == true
		end
		self:emitActivity("Daemon requested snapshot")
		local client = self.client
		task.spawn(function()
			if self.client == client then
				self:sendSnapshot()
			end
		end)
	elseif message.type == Protocol.ServerMessage.SNAPSHOT_ACK then
		local state = self.snapshot
		if state and message.snapshotId == state.id and message.sequence == state.waitingFor then
			state.acknowledged = true
		end
	elseif message.type == Protocol.ServerMessage.SNAPSHOT_ERROR then
		local state = self.snapshot
		if state and (message.snapshotId == nil or message.snapshotId == state.id) then
			state.error = tostring(message.error or "Daemon rejected the snapshot.")
		end
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

		if self.client == client then
			self:handleMessage(message)
		end
	end)

	client:onClose(function()
		if not forwarding then
			finish(false, "closed")
		elseif self.running and self.client == client then
			log("Daemon connection closed")
			self.lastError = "Daemon connection closed."
			self:emitActivity(self.lastError)
			self:stop()
		end
	end)

	client:onError(function(err)
		if not forwarding then
			finish(false, tostring(err))
		elseif self.client == client then
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

	if not resolved then
		handshakeEvent.Event:Wait()
	end
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
	self.snapshotBatches = false

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

	table.insert(self.connections, game.DescendantAdded:Connect(function(instance)
		self:attachInstance(instance)
		self:onInstanceChanged(instance)
	end))

	table.insert(self.connections, game.DescendantRemoving:Connect(function(instance)
		if self:markSnapshotDirty(instance, true) then
			return
		end
		local client = self.client
		-- DescendantRemoving runs before Parent has actually changed.
		task.defer(function()
			if not self.running or self.client ~= client then
				return
			end
			if self:markSnapshotDirty(instance, true) then
				return
			end
			if StudioScanner.isIncluded(instance) then
				self:onInstanceChanged(instance)
				return
			end
			local guid = self.instanceToGuid[instance]
			if guid then
				if self:send({ type = Protocol.ClientMessage.INSTANCE_REMOVED, guid = guid }) then
					self:emitActivity("Instance removed:", guid)
				end
				self.instanceToGuid[instance] = nil
				self.guidToInstance[guid] = nil
			end
		end)
	end))
	self:attachExistingListeners()

	if enableForwarding then
		enableForwarding()
	end

	for _, message in ipairs(queuedMessages or {}) do
		self:handleMessage(message)
	end
	if not self.running then
		return false
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
	if self.snapshot then
		self.snapshot.cancelled = true
	end
	self.snapshot = nil
	self.snapshotBatches = false

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
	self.attachedInstances = {}
	self.connectedUrl = nil

	log("Sync stopped")
	self:emitActivity("Sync stopped")
	self:emitState()
end

return SyncSession
