--!nonstrict

local StudioScanner = {}

local Config = require(script.Parent.Config)

local SCRIPT_CLASSES = { Script = true, LocalScript = true, ModuleScript = true }

local function isScript(instance)
	return SCRIPT_CLASSES[instance.ClassName] == true
end

local function getPath(instance)
	local path = {}
	local current = instance

	while current and current ~= game do
		table.insert(path, 1, current.Name)
		current = current.Parent
	end

	if current ~= game then
		return nil
	end

	return path
end

local function isIncluded(instance)
	local current = instance

	while current do
		if current.Parent == game then
			return Config.SYNC_SERVICES[current.Name] == true
		end

		current = current.Parent
	end

	return false
end

local function getGuid(instance)
	local ok, value = pcall(function()
		return instance:GetDebugId(0)
	end)

	if ok and type(value) == "string" and value ~= "" then
		return value
	end

	return nil
end

function StudioScanner.isScript(instance)
	return isScript(instance)
end

function StudioScanner.isIncluded(instance)
	return isIncluded(instance)
end

function StudioScanner.getGuid(instance)
	return getGuid(instance)
end

function StudioScanner.getPath(instance)
	return getPath(instance)
end

function StudioScanner.toRecord(instance, includeSource)
	if includeSource == nil then
		includeSource = true
	end

	-- Non-script objects are traversed for discovery, never serialized or indexed.
	if not isScript(instance) or not isIncluded(instance) then
		return nil
	end

	local path = getPath(instance)
	local guid = getGuid(instance)

	if not path or not guid then
		return nil
	end

	local record = {
		guid = guid,
		className = instance.ClassName,
		name = instance.Name,
		path = path,
	}

	if includeSource then
		record.source = instance.Source
	end

	return record
end

-- Visit one record at a time. A depth-first stack releases each parent's child
-- list when it is done; it never retains a list of every record in the place.
-- Returning false cancels the walk; "skip" skips an already-visited subtree.
function StudioScanner.visitInstances(visitor, root)
	local stack = { { children = if root then { root } else game:GetChildren(), index = 1 } }
	local visited = 0

	while #stack > 0 do
		local frame = stack[#stack]
		local instance = frame.children[frame.index]
		if not instance then
			table.remove(stack)
			continue
		end
		frame.index += 1

		if root or isIncluded(instance) then
			local result = visitor(instance)
			if result == false then
				return false
			end
			if result ~= "skip" then
				table.insert(stack, { children = instance:GetChildren(), index = 1 })
			end
		end

		visited += 1
		if visited % 300 == 0 then
			task.wait()
		end
	end

	return true
end

-- Enumerate each selected service once in native code, then cheaply filter by
-- class. Do not calculate paths/GUIDs or allocate a DFS frame for millions of
-- poses/parts. Arbitrary containers remain searchable, including animation data.
function StudioScanner.visitScripts(visitor, root, shouldContinue)
	local roots = {}
	if root then
		table.insert(roots, root)
	else
		for _, service in ipairs(game:GetChildren()) do
			if Config.SYNC_SERVICES[service.Name] then
				table.insert(roots, service)
			end
		end
	end

	for _, scanRoot in ipairs(roots) do
		if shouldContinue and not shouldContinue() then
			return false
		end
		if isScript(scanRoot) and visitor(scanRoot) == false then
			return false
		end
		local descendants = scanRoot:GetDescendants()
		for index, instance in ipairs(descendants) do
			if isScript(instance) and visitor(instance) == false then
				return false
			end
			if index % 10000 == 0 then
				task.wait()
				if shouldContinue and not shouldContinue() then
					return false
				end
			end
		end
	end
	return true
end

function StudioScanner.visit(includeSource, visitor, root)
	return StudioScanner.visitScripts(function(instance)
		local record = StudioScanner.toRecord(instance, includeSource)
		if record then
			return visitor(record, instance)
		end
		return true
	end, root)
end

function StudioScanner.snapshot(includeSource)
	local records = {}
	StudioScanner.visit(includeSource, function(record)
		table.insert(records, record)
	end)
	return records
end

return StudioScanner
