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

function StudioScanner.snapshot(includeSource)
	local records = {}
	local queue = {}

	for _, service in ipairs(game:GetChildren()) do
		if isIncluded(service) then
			table.insert(queue, service)
		end
	end

	local index = 1
	while index <= #queue do
		local instance = queue[index]
		local record = StudioScanner.toRecord(instance, includeSource)

		if record then
			table.insert(records, record)
		end

		for _, child in ipairs(instance:GetChildren()) do
			if isIncluded(child) then
				table.insert(queue, child)
			end
		end

		if index % 300 == 0 then
			task.wait()
		end

		index += 1
	end

	return records
end

return StudioScanner
