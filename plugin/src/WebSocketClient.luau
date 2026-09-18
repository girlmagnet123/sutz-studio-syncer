--!nonstrict

local HttpService = game:GetService("HttpService")
local Protocol = require(script.Parent.Protocol)

local MAX_WIRE_BYTES = 48 * 1024
local MESSAGE_FRAGMENT_BYTES = 4 * 1024

local WebSocketClient = {}
WebSocketClient.__index = WebSocketClient

function WebSocketClient.new(url, logger)
	local self = setmetatable({}, WebSocketClient)

	self.url = url
	self.logger = logger
	self.socket = nil
	self.connected = false
	self.messageChunks = false
	self.messageHandlers = {}
	self.closeHandlers = {}
	self.errorHandlers = {}

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

function WebSocketClient:connect()
	if type(HttpService.CreateWebStreamClient) ~= "function" then
		for _, callback in ipairs(self.errorHandlers) do
			callback("HttpService:CreateWebStreamClient is unavailable in this Studio session")
		end
		return false
	end

	local ok, socketOrError = pcall(function()
		return HttpService:CreateWebStreamClient(Enum.WebStreamClientType.WebSocket, {
			Url = self.url,
		})
	end)

	if not ok then
		for _, callback in ipairs(self.errorHandlers) do
			callback(socketOrError)
		end
		return false
	end

	self.socket = socketOrError
	self.connected = true

	self.socket.MessageReceived:Connect(function(raw)
		local decodedOk, message = pcall(function()
			return HttpService:JSONDecode(raw)
		end)

		if not decodedOk then
			for _, callback in ipairs(self.errorHandlers) do
				callback("Invalid JSON from daemon")
			end
			return
		end

		for _, callback in ipairs(self.messageHandlers) do
			callback(message)
		end
	end)

	local hasClosedSignal, closedSignal = pcall(function()
		return self.socket.Closed
	end)

	if hasClosedSignal and closedSignal then
		closedSignal:Connect(function()
			self.connected = false
			for _, callback in ipairs(self.closeHandlers) do
				callback()
			end
		end)
	end

	return true
end

function WebSocketClient:reportError(err)
	for _, callback in ipairs(self.errorHandlers) do
		callback(tostring(err))
	end
end

function WebSocketClient:encode(message)
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(message)
	end)
	if not ok then
		local err = "Could not encode outgoing " .. tostring(message.type) .. ": " .. tostring(encoded)
		self:reportError(err)
		return nil, err
	end
	return encoded
end

-- Snapshot chunks are already encoded so their exact byte size can be checked
-- before transmission, without joining the complete snapshot into one string.
function WebSocketClient:sendEncoded(encoded)
	if not self.connected or not self.socket then
		return false, "Daemon connection is closed."
	end

	local ok, err = pcall(function()
		self.socket:Send(encoded)
	end)
	if not ok then
		local message = "Could not send " .. tostring(#encoded) .. " bytes: " .. tostring(err)
		self:reportError(message)
		return false, message
	end
	return true, nil, #encoded
end

function WebSocketClient:send(message)
	local encoded, err = self:encode(message)
	if not encoded then
		return false, err
	end
	if #encoded <= MAX_WIRE_BYTES then
		return self:sendEncoded(encoded)
	end
	if not self.messageChunks then
		local failure = "Daemon does not support fragmented messages. Rebuild/restart sutz and reconnect."
		self:reportError(failure)
		return false, failure
	end

	-- Fragment only this individual message (usually one script's source).
	-- Snapshot metadata already uses independently parsed bounded batches.
	-- Keep each fragment valid UTF-8 so JSONEncode cannot corrupt a character.
	local fragments = {}
	local offset = 1
	while offset <= #encoded do
		local last = math.min(offset + MESSAGE_FRAGMENT_BYTES - 1, #encoded)
		if last < #encoded then
			local nextByte = string.byte(encoded, last + 1)
			while nextByte and nextByte >= 0x80 and nextByte <= 0xBF do
				last -= 1
				nextByte = string.byte(encoded, last + 1)
			end
		end
		table.insert(fragments, string.sub(encoded, offset, last))
		offset = last + 1
	end

	local messageId = HttpService:GenerateGUID(false)
	-- No task.wait here: fragments of one logical message must stay together.
	for index, data in ipairs(fragments) do
		local frame, frameError = self:encode({
			type = Protocol.ClientMessage.MESSAGE_CHUNK,
			messageId = messageId,
			sequence = index - 1,
			total = #fragments,
			data = data,
		})
		if not frame then
			return false, frameError
		end
		if #frame > MAX_WIRE_BYTES then
			local failure = "Encoded message fragment exceeded the 48 KiB wire limit."
			self:reportError(failure)
			return false, failure
		end
		local sent, sendError = self:sendEncoded(frame)
		if not sent then
			return false, sendError
		end
	end
	return true, nil, #encoded
end

function WebSocketClient:close()
	if not self.socket then
		return
	end

	pcall(function()
		self.socket:Close()
	end)

	self.connected = false
	self.socket = nil
end

return WebSocketClient
