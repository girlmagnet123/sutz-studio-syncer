--!nonstrict

local HttpService = game:GetService("HttpService")

local WebSocketClient = {}
WebSocketClient.__index = WebSocketClient

function WebSocketClient.new(url, logger)
	local self = setmetatable({}, WebSocketClient)

	self.url = url
	self.logger = logger
	self.socket = nil
	self.connected = false
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
	if type(WebSocket) ~= "table" or type(WebSocket.connect) ~= "function" then
		for _, callback in ipairs(self.errorHandlers) do
			callback("WebSocket API is unavailable in this Studio session")
		end
		return false
	end

	local ok, socketOrError = pcall(function()
		return WebSocket.connect(self.url)
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

	self.socket.Closed:Connect(function()
		self.connected = false
		for _, callback in ipairs(self.closeHandlers) do
			callback()
		end
	end)

	return true
end

function WebSocketClient:send(message)
	if not self.connected or not self.socket then
		return false
	end

	local encoded = HttpService:JSONEncode(message)
	local ok = pcall(function()
		self.socket:Send(encoded)
	end)

	return ok
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
