--!nonstrict

local HttpService = game:GetService("HttpService")
local Config = require(script.Parent.Config)
local Protocol = require(script.Parent.Protocol)

local MAX_WIRE_BYTES = 48 * 1024
-- Leave room to append transportSequence without re-encoding the object.
local MAX_MESSAGE_BYTES = MAX_WIRE_BYTES - 64
local MESSAGE_FRAGMENT_BYTES = 4 * 1024
local MAX_PENDING_BYTES = 64 * 1024 * 1024
local MAX_SEQUENCE = 9007199254740991

local WebSocketClient = {}
WebSocketClient.__index = WebSocketClient

local function fragmentEnd(encoded, offset)
	local last = math.min(offset + MESSAGE_FRAGMENT_BYTES - 1, #encoded)
	if last < #encoded then
		local nextByte = string.byte(encoded, last + 1)
		while nextByte and nextByte >= 0x80 and nextByte <= 0xBF do
			last -= 1
			nextByte = string.byte(encoded, last + 1)
		end
	end
	return last
end

function WebSocketClient.new(url, logger)
	local self = setmetatable({}, WebSocketClient)
	self.url = url
	self.logger = logger
	self.socket = nil
	self.connected = false
	self.messageChunks = false
	self.messageAcks = false
	self.messageHandlers = {}
	self.closeHandlers = {}
	self.errorHandlers = {}
	self.connections = {}
	self.generation = 0
	self.transportSequence = 0
	self.queue = {}
	self.queueHead = 1
	self.queueTail = 0
	self.pendingBytes = 0
	return self
end

function WebSocketClient:onMessage(callback)
	table.insert(self.messageHandlers, callback)
end

function WebSocketClient:onClose(callback)
	table.insert(self.closeHandlers, callback)
end

function WebSocketClient:onError(callback)
	table.insert(self.errorHandlers, callback)
end

function WebSocketClient:reportError(err)
	for _, callback in ipairs(self.errorHandlers) do
		callback(tostring(err))
	end
end

function WebSocketClient:finishRequest(request, ok, err, releaseBytes)
	if request.done then
		return
	end
	request.done = true
	request.ok = ok
	request.error = err
	request.encoded = nil
	if releaseBytes ~= false then
		self.pendingBytes -= request.bytes
	end
	request.event:Fire()
end

function WebSocketClient:finishWire(pending, err)
	if pending.done then
		return
	end
	pending.done = true
	pending.error = err
	if self.pendingWire == pending then
		self.pendingWire = nil
	end
	if pending.timeout then
		pcall(task.cancel, pending.timeout)
		pending.timeout = nil
	end
	pending.event:Fire()
end

function WebSocketClient:disconnect(reason, notifyError, notifyClose)
	local socket = self.socket
	local pendingWire = self.pendingWire
	local activeRequest = self.activeRequest
	local queue, queueHead, queueTail = self.queue, self.queueHead, self.queueTail
	self.socket = nil
	self.connected = false
	self.messageChunks = false
	self.messageAcks = false
	self.generation += 1
	local generation = self.generation
	self.workerGeneration = nil
	for _, connection in ipairs(self.connections) do
		connection:Disconnect()
	end
	self.connections = {}
	self.pendingWire = nil
	self.activeRequest = nil
	self.queue = {}
	self.queueHead = 1
	self.queueTail = 0
	self.pendingBytes = 0
	-- Detach everything before firing events: an immediately resumed sender
	-- can close or reconnect this same client while its old queue is released.
	if pendingWire then
		self:finishWire(pendingWire, reason)
	end
	if activeRequest then
		self:finishRequest(activeRequest, false, reason, false)
	end
	for index = queueHead, queueTail do
		self:finishRequest(queue[index], false, reason, false)
	end
	if socket then
		pcall(function()
			socket:Close()
		end)
		if self.generation ~= generation then
			return
		end
		if notifyError then
			self:reportError(reason)
		elseif notifyClose then
			for _, callback in ipairs(self.closeHandlers) do
				callback()
			end
		end
	end
end

function WebSocketClient:connect()
	local generation = self.generation + 1
	self:close()
	if self.generation ~= generation then
		return false
	end
	if type(HttpService.CreateWebStreamClient) ~= "function" then
		self:reportError("HttpService:CreateWebStreamClient is unavailable in this Studio session")
		return false
	end
	local ok, socketOrError = pcall(function()
		return HttpService:CreateWebStreamClient(Enum.WebStreamClientType.WebSocket, {
			Url = self.url,
		})
	end)
	if not ok then
		if self.generation == generation then
			self:reportError(socketOrError)
		end
		return false
	end
	if self.generation ~= generation then
		pcall(function()
			socketOrError:Close()
		end)
		return false
	end
	self.socket = socketOrError
	self.connected = true
	self.transportSequence = 0
	local function isCurrent()
		return self.generation == generation and self.socket == socketOrError and self.connected
	end
	table.insert(self.connections, socketOrError.MessageReceived:Connect(function(raw)
		if not isCurrent() then
			return
		end
		local decodedOk, message = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if not decodedOk then
			self:disconnect("Invalid JSON from daemon", true, false)
			return
		end
		if type(message) == "table" then
			if message.type == Protocol.ServerMessage.MESSAGE_ACK then
				local pending = self.pendingWire
				if pending and message.sequence == pending.sequence then
					self:finishWire(pending)
				end
				return
			elseif message.type == Protocol.ServerMessage.REQUEST_SNAPSHOT then
				-- The handshake can queue this message before SyncSession handles it.
				self.messageChunks = message.messageChunks == true
				self.messageAcks = message.messageAcks == true
			end
		end
		for _, callback in ipairs(self.messageHandlers) do
			if not isCurrent() then
				return
			end
			callback(message)
		end
	end))
	local hasClosedSignal, closedSignal = pcall(function()
		return socketOrError.Closed
	end)
	if hasClosedSignal and closedSignal then
		table.insert(self.connections, closedSignal:Connect(function()
			if isCurrent() then
				self:disconnect("Daemon connection is closed.", false, true)
			end
		end))
	end
	local hasErrorSignal, errorSignal = pcall(function()
		return socketOrError.Error
	end)
	if hasErrorSignal and errorSignal then
		table.insert(self.connections, errorSignal:Connect(function(status, message)
			if isCurrent() then
				local reason = "Studio WebSocket error (status " .. tostring(status) .. "): " .. tostring(message or "")
				self:disconnect(reason, true, false)
			end
		end))
	end
	return true
end

function WebSocketClient:encode(message)
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(message)
	end)
	if not ok then
		local err = "Could not encode outgoing message: " .. tostring(encoded)
		self:reportError(err)
		return nil, err
	end
	return encoded
end

function WebSocketClient:sendWire(encoded, acknowledged, generation)
	if self.generation ~= generation or not self.connected or not self.socket then
		return false, "Daemon connection is closed."
	end
	local pending
	if acknowledged then
		if self.transportSequence >= MAX_SEQUENCE then
			return false, "WebSocket message sequence exhausted. Reconnect to the daemon."
		end
		self.transportSequence += 1
		local last = string.find(encoded, "}%s*$")
		if not last or not string.match(encoded, "^%s*{") then
			return false, "Outgoing WebSocket message must be a JSON object."
		end
		local separator = if string.match(encoded, "^%s*{%s*}%s*$") then "" else ","
		encoded = string.sub(encoded, 1, last - 1) .. separator .. '"transportSequence":'
			.. string.format("%.0f", self.transportSequence) .. string.sub(encoded, last)
	end
	if #encoded > MAX_WIRE_BYTES then
		return false, "Encoded message exceeded the 48 KiB wire limit."
	end
	if acknowledged then
		pending = {
			sequence = self.transportSequence,
			event = Instance.new("BindableEvent"),
		}
		self.pendingWire = pending
		pending.timeout = task.delay(Config.WS_SEND_ACK_TIMEOUT or 30, function()
			pending.timeout = nil
			if self.generation == generation and self.pendingWire == pending and not pending.done then
				self:disconnect("Daemon did not acknowledge WebSocket message " .. tostring(pending.sequence)
					.. ". Restart sutz and reconnect.", true, false)
			end
		end)
	end
	local socket = self.socket
	local ok, err = pcall(function()
		socket:Send(encoded)
	end)
	if not ok then
		local reason = "Could not send " .. tostring(#encoded) .. " bytes: " .. tostring(err)
		if self.generation == generation then
			self:disconnect(reason, true, false)
		end
		if pending then
			pending.event:Destroy()
		end
		return false, reason
	end
	if pending then
		if not pending.done then
			pending.event.Event:Wait()
		end
		pending.event:Destroy()
		if pending.error then
			return false, pending.error
		end
	end
	if self.generation ~= generation or not self.connected then
		return false, "Daemon connection is closed."
	end
	return true
end

function WebSocketClient:sendLogical(encoded, allowUnacknowledged, generation)
	local acknowledged = self.messageAcks
	if not acknowledged and not allowUnacknowledged then
		return false, "Daemon does not support acknowledged messages. Run npm run build, restart sutz, and reconnect."
	end
	if #encoded <= MAX_MESSAGE_BYTES then
		return self:sendWire(encoded, acknowledged, generation)
	end
	if not acknowledged or not self.messageChunks then
		return false, "Daemon does not support acknowledged message fragments. Run npm run build, restart sutz, and reconnect."
	end
	-- Count boundaries without retaining a second copy of the entire message.
	-- Each UTF-8 fragment is encoded and released before making the next one.
	local total = 0
	local offset = 1
	while offset <= #encoded do
		total += 1
		offset = fragmentEnd(encoded, offset) + 1
	end
	local messageId = HttpService:GenerateGUID(false)
	offset = 1
	for index = 1, total do
		local last = fragmentEnd(encoded, offset)
		local frame, frameError = self:encode({
			type = Protocol.ClientMessage.MESSAGE_CHUNK,
			messageId = messageId,
			sequence = index - 1,
			total = total,
			data = string.sub(encoded, offset, last),
		})
		if not frame then
			return false, frameError
		end
		local sent, sendError = self:sendWire(frame, true, generation)
		if not sent then
			return false, sendError
		end
		offset = last + 1
	end
	return true
end

function WebSocketClient:runQueue(generation)
	while self.generation == generation and self.connected and self.queueHead <= self.queueTail do
		local request = self.queue[self.queueHead]
		self.queue[self.queueHead] = nil
		self.queueHead += 1
		self.activeRequest = request
		local completed, sent, err = pcall(function()
			return self:sendLogical(request.encoded, request.allowUnacknowledged, generation)
		end)
		if not completed then
			err = "Could not send WebSocket message: " .. tostring(sent)
			sent = false
		end
		if self.generation ~= generation then
			return
		end
		if not sent then
			self:disconnect(err or "Could not send WebSocket message.", true, false)
			return
		end
		self.activeRequest = nil
		self:finishRequest(request, true)
	end
	if self.workerGeneration == generation then
		self.workerGeneration = nil
		self.queue = {}
		self.queueHead = 1
		self.queueTail = 0
	end
end

function WebSocketClient:enqueue(encoded, allowUnacknowledged)
	if not self.connected or not self.socket then
		return false, "Daemon connection is closed."
	end
	if type(encoded) ~= "string" then
		return false, "Outgoing WebSocket message must be an encoded JSON string."
	end
	if self.pendingBytes + #encoded > MAX_PENDING_BYTES then
		local err = "WebSocket send queue exceeded 64 MiB. Reconnect after the pending script changes settle."
		self:disconnect(err, true, false)
		return false, err
	end
	local request = {
		encoded = encoded,
		bytes = #encoded,
		allowUnacknowledged = allowUnacknowledged,
		event = Instance.new("BindableEvent"),
	}
	self.pendingBytes += request.bytes
	self.queueTail += 1
	self.queue[self.queueTail] = request
	if not self.workerGeneration then
		local generation = self.generation
		self.workerGeneration = generation
		task.spawn(function()
			self:runQueue(generation)
		end)
	end
	if not request.done then
		request.event.Event:Wait()
	end
	request.event:Destroy()
	if request.ok then
		return true, nil, request.bytes
	end
	return false, request.error
end

-- Both entry points queue complete logical messages. Yielding for fragment
-- acknowledgements cannot interleave a second script or a control message.
function WebSocketClient:sendEncoded(encoded)
	return self:enqueue(encoded, false)
end

function WebSocketClient:send(message)
	local encoded, err = self:encode(message)
	if not encoded then
		return false, err
	end
	return self:enqueue(encoded, type(message) == "table" and message.type == Protocol.ClientMessage.HELLO)
end

function WebSocketClient:close()
	self:disconnect("Daemon connection is closed.", false, false)
end

return WebSocketClient
