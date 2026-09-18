-- Invoked in Studio Edit mode with loadClient(httpService, config) injected.
-- The socket is a local mock: no network, game scripts, or play session is used.
local http = game:GetService("HttpService")
local cleanups = {}
local function waitUntil(predicate, label)
	local deadline = os.clock() + 3
	while not predicate() and os.clock() < deadline do task.wait() end
	assert(predicate(), "Timed out: " .. label)
end

local function fixture(timeout)
	local events = {}
	local sockets = {}
	local function signal()
		local event = Instance.new("BindableEvent")
		table.insert(events, event)
		return event
	end
	local fakeHttp = {
		JSONEncode = function(_, value) return http:JSONEncode(value) end,
		JSONDecode = function(_, value) return http:JSONDecode(value) end,
		GenerateGUID = function() return http:GenerateGUID(false) end,
	}
	function fakeHttp:CreateWebStreamClient()
		local incoming, closed, failed, opened = signal(), signal(), signal(), signal()
		local socket = {
			MessageReceived = incoming.Event, Closed = closed.Event,
			Error = failed.Event, Opened = opened.Event,
			ConnectionState = Enum.WebStreamClientState.Open,
			frames = {}, pending = nil, incoming = incoming, failed = failed,
		}
		function socket:Send(raw)
			local decoded = http:JSONDecode(raw)
			assert(#raw <= 48 * 1024, "Wire message exceeded 48 KiB")
			table.insert(self.frames, { raw = raw, message = decoded })
			if decoded.type == "hello" then
				task.defer(function()
					incoming:Fire(http:JSONEncode({ type = "requestSnapshot", snapshotBatches = true,
						messageChunks = true, messageAcks = true }))
				end)
			else
				assert(self.pending == nil, "More than one wire message was outstanding")
				assert(type(decoded.transportSequence) == "number", "Missing wire sequence")
				self.pending = decoded.transportSequence
				if self.autoAck then self:ack() end
			end
		end
		function socket:ack()
			assert(self.pending, "Nothing to acknowledge")
			local sequence = self.pending
			self.pending = nil
			incoming:Fire(http:JSONEncode({ type = "messageAck", sequence = sequence }))
		end
		function socket:Close()
			self.ConnectionState = Enum.WebStreamClientState.Closed
			closed:Fire()
		end
		table.insert(sockets, socket)
		return socket
	end
	local Client = loadClient(fakeHttp, { WS_SEND_ACK_TIMEOUT = timeout or 2 })
	local client = Client.new("ws://127.0.0.1:1")
	local errors = {}
	client:onError(function(err) table.insert(errors, err) end)
	client:onMessage(function(message)
		if message.type == "requestSnapshot" then client.messageChunks = true end
	end)
	assert(client:connect())
	assert(client:send({ type = "hello", protocolVersion = 1, client = "mock" }))
	waitUntil(function() return client.messageAcks end, "capability negotiation")
	local result = {
		client = client, socket = sockets[1], sockets = sockets, errors = errors,
		cleanup = function()
			client:close()
			for _, event in ipairs(events) do event:Destroy() end
		end,
	}
	table.insert(cleanups, result.cleanup)
	return result
end

local results = {}
local function check(name, run)
	local ok, err = pcall(run)
	for _, cleanup in ipairs(cleanups) do pcall(cleanup) end
	cleanups = {}
	assert(ok, name .. ": " .. tostring(err))
	table.insert(results, name)
end

check("UTF-8 fragments wait for acknowledgements and concurrent logical sends stay ordered", function()
	local f = fixture()
	local message = { type = "scriptChanged", guid = "large", className = "ModuleScript",
		path = { "ReplicatedStorage", "Large" }, source = string.rep("é🦊\n\"\\", 9000) }
	local original = http:JSONEncode(message)
	local first, second
	task.spawn(function() first = { f.client:send(message) } end)
	waitUntil(function() return f.socket.pending ~= nil end, "first fragment")
	task.spawn(function() second = { f.client:send({ type = "pong" }) } end)
	task.wait()
	assert(#f.socket.frames == 2, "A second Send happened before the first ACK")
	-- Unrelated/old ACKs must not release the active message.
	f.socket.incoming:Fire(http:JSONEncode({ type = "messageAck", sequence = 987654 }))
	task.wait()
	assert(#f.socket.frames == 2, "Unrelated ACK released the worker")
	local deadline = os.clock() + 8
	while (not first or not second) and os.clock() < deadline do
		if f.socket.pending then f.socket:ack() end
		task.wait()
	end
	assert(first and first[1] and second and second[1], "Queued sends did not complete")
	assert(first[3] == #original, "Reported original message length changed")
	local parts, id, count = {}, nil, 0
	for index = 2, #f.socket.frames - 1 do
		local chunk = f.socket.frames[index].message
		assert(chunk.type == "messageChunk", "Logical messages interleaved")
		id = id or chunk.messageId
		assert(chunk.messageId == id and chunk.sequence == count, "Chunk order changed")
		assert(#chunk.data <= 4096 and utf8.len(chunk.data), "Invalid UTF-8 fragment")
		table.insert(parts, chunk.data)
		count += 1
		assert(chunk.total >= count)
	end
	assert(table.concat(parts) == original, "Large message contents changed")
	assert(f.socket.frames[#f.socket.frames].message.type == "pong")
	assert(#f.errors == 0)
	f.cleanup()
end)

check("Pre-encoded metadata also waits for an ACK within the wire-size limit", function()
	local f = fixture()
	local raw = http:JSONEncode({ type = "snapshotChunk", data = string.rep("a", 48 * 1024 - 128) })
	local outcome
	task.spawn(function() outcome = { f.client:sendEncoded(raw) } end)
	waitUntil(function() return f.socket.pending ~= nil end, "metadata send")
	assert(outcome == nil)
	f.socket:ack()
	waitUntil(function() return outcome ~= nil end, "metadata ACK")
	assert(outcome[1] and outcome[3] == #raw)
	f.cleanup()
end)

for _, mode in ipairs({ "close", "nativeError", "timeout" }) do
	check(mode .. " releases both the active sender and queued senders", function()
		local f = fixture(if mode == "timeout" then 0.1 else 2)
		local first, second
		task.spawn(function() first = { f.client:send({ type = "pong" }) } end)
		waitUntil(function() return f.socket.pending ~= nil end, "active sender")
		task.spawn(function() second = { f.client:send({ type = "pong" }) } end)
		if mode == "close" then
			f.client:close()
		elseif mode == "nativeError" then
			f.socket.failed:Fire(500, "synthetic transport failure")
		end
		waitUntil(function() return first ~= nil and second ~= nil end, "cancelled senders")
		assert(first[1] == false and second[1] == false, "Cancelled send reported success")
		assert(not f.client.connected)
		if mode ~= "close" then assert(#f.errors >= 1, "Error was not reported") end
		f.cleanup()
	end)
end

check("An ACK received inside Send does not get lost before the wait starts", function()
	local f = fixture()
	f.socket.autoAck = true
	local ok, err = f.client:send({ type = "pong" })
	assert(ok, tostring(err))
	assert(f.socket.pending == nil and f.client.pendingWire == nil)
	f.cleanup()
end)

check("Reconnect from a cancelled sender survives old teardown and stale signals", function()
	local f = fixture()
	local cancelled, replacement, queued
	task.spawn(function()
		cancelled = { f.client:send({ type = "pong" }) }
		assert(not cancelled[1])
		assert(f.client:connect())
		assert(f.client:send({ type = "hello", protocolVersion = 1, client = "reconnect" }))
		waitUntil(function() return f.client.messageAcks end, "replacement capabilities")
		replacement = { f.client:send({ type = "pong" }) }
	end)
	waitUntil(function() return f.socket.pending ~= nil end, "old sender")
	task.spawn(function() queued = { f.client:send({ type = "pong" }) } end)
	f.client:close()
	waitUntil(function() return #f.sockets == 2 and f.sockets[2].pending ~= nil end, "replacement sender")
	local socket = f.sockets[2]
	f.socket.incoming:Fire(http:JSONEncode({ type = "messageAck", sequence = socket.pending }))
	f.socket.failed:Fire(500, "stale socket error")
	task.wait()
	assert(f.client.connected and replacement == nil, "Old socket affected the new connection")
	assert(queued and not queued[1], "Old queued sender was not cancelled")
	socket:ack()
	waitUntil(function() return replacement ~= nil end, "replacement ACK")
	assert(replacement[1], tostring(replacement[2]))
	f.cleanup()
end)

return http:JSONEncode({ passed = #results, checks = results })
