--!nonstrict

local StudioScanner = {}

local Config = require(script.Parent.Config)

local function isScript(instance)
	return instance:IsA("Script") or instance:IsA("LocalScript") or instance:IsA("ModuleScript")
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

	if not isIncluded(instance) then
		return nil
	end

	local path = getPath(instance)
	local guid = getGuid(instance)

	if not path or not guid then
		return nil
	end

	local parentGuid = nil
	if instance.Parent and instance.Parent ~= game then
		parentGuid = getGuid(instance.Parent)
	elseif instance.Parent == game then
		parentGuid = "root"
	end

	local record = {
		guid = guid,
		className = instance.ClassName,
		name = instance.Name,
		path = path,
		parentGuid = parentGuid,
	}

	if includeSource and isScript(instance) then
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

function StudioScanner.visit(includeSource, visitor, root)
	return StudioScanner.visitInstances(function(instance)
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
