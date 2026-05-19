--!nonstrict

local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(script.Parent.Config)
local Protocol = require(script.Parent.Protocol)
local WebSocketClient = require(script.Parent.WebSocketClient)

local UI = {}
UI.__index = UI

local COLORS = {
	background = Color3.fromRGB(22, 24, 29),
	panel = Color3.fromRGB(31, 34, 42),
	panelSoft = Color3.fromRGB(39, 43, 52),
	field = Color3.fromRGB(45, 49, 60),
	fieldFocused = Color3.fromRGB(54, 60, 74),
	border = Color3.fromRGB(68, 75, 92),
	text = Color3.fromRGB(242, 245, 251),
	muted = Color3.fromRGB(164, 172, 190),
	accent = Color3.fromRGB(86, 139, 255),
	accentSoft = Color3.fromRGB(116, 165, 255),
	success = Color3.fromRGB(83, 202, 142),
	danger = Color3.fromRGB(213, 88, 110),
}

local SERVICES = {
	"Workspace",
	"ReplicatedFirst",
	"ReplicatedStorage",
	"ServerScriptService",
	"ServerStorage",
	"StarterGui",
	"StarterPack",
	"StarterPlayer",
}

local function tween(instance, properties, duration)
	local info = TweenInfo.new(duration or 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local animation = TweenService:Create(instance, info, properties)
	animation:Play()
	return animation
end

local function corner(parent, radius)
	local item = Instance.new("UICorner")
	item.CornerRadius = UDim.new(0, radius or 8)
	item.Parent = parent
	return item
end

local function stroke(parent, color, transparency)
	local item = Instance.new("UIStroke")
	item.Color = color or COLORS.border
	item.Transparency = transparency or 0.42
	item.Thickness = 1
	item.Parent = parent
	return item
end

local function padding(parent, value)
	local item = Instance.new("UIPadding")
	item.PaddingTop = UDim.new(0, value)
	item.PaddingRight = UDim.new(0, value)
	item.PaddingBottom = UDim.new(0, value)
	item.PaddingLeft = UDim.new(0, value)
	item.Parent = parent
	return item
end

local function makeText(parent, name, text, size, color, font)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = font or Enum.Font.Gotham
	label.Text = text
	label.TextColor3 = color or COLORS.text
	label.TextSize = size or 13
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Parent = parent
	return label
end

local function makeButton(parent, text, backgroundColor)
	local button = Instance.new("TextButton")
	button.AutoButtonColor = false
	button.BackgroundColor3 = backgroundColor or COLORS.accent
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.Text = text
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.TextSize = 14
	button.Size = UDim2.new(1, 0, 0, 36)
	button.Parent = parent
	corner(button, 7)

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = button

	button.MouseEnter:Connect(function()
		tween(button, {
			BackgroundColor3 = backgroundColor == COLORS.danger and Color3.fromRGB(231, 103, 124) or COLORS.accentSoft,
		})
		tween(scale, { Scale = 1.015 }, 0.12)
	end)

	button.MouseLeave:Connect(function()
		tween(button, { BackgroundColor3 = backgroundColor or COLORS.accent })
		tween(scale, { Scale = 1 }, 0.12)
	end)

	button.MouseButton1Down:Connect(function()
		tween(scale, { Scale = 0.985 }, 0.08)
	end)

	button.MouseButton1Up:Connect(function()
		tween(scale, { Scale = 1.015 }, 0.08)
	end)

	return button
end

local function makeField(parent, text)
	local box = Instance.new("TextBox")
	box.BackgroundColor3 = COLORS.field
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.Font = Enum.Font.Code
	box.PlaceholderColor3 = Color3.fromRGB(118, 128, 146)
	box.Text = text or ""
	box.TextColor3 = COLORS.text
	box.TextSize = 13
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Size = UDim2.new(1, 0, 0, 32)
	box.Parent = parent
	corner(box, 6)
	padding(box, 8)

	box.Focused:Connect(function()
		tween(box, { BackgroundColor3 = COLORS.fieldFocused }, 0.12)
	end)

	box.FocusLost:Connect(function()
		tween(box, { BackgroundColor3 = COLORS.field }, 0.12)
	end)

	return box
end

local function joinServices()
	local enabled = {}
	for _, name in ipairs(SERVICES) do
		if Config.SYNC_SERVICES[name] then
			table.insert(enabled, name)
		end
	end
	return table.concat(enabled, ", ")
end

local function applyServiceText(text)
	local nextServices = {}
	for item in string.gmatch(text, "([^,]+)") do
		local serviceName = string.gsub(item, "^%s*(.-)%s*$", "%1")
		if serviceName ~= "" then
			nextServices[serviceName] = true
		end
	end
	Config.SYNC_SERVICES = nextServices
end

local function isIdentifier(value)
	return string.match(value, "^[%a_][%w_]*$") ~= nil
end

local function quoteSegment(value)
	return string.format("%q", value)
end

local function formatPathSegment(value, isFirst)
	if isIdentifier(value) then
		return isFirst and value or "." .. value
	end

	return "[" .. quoteSegment(value) .. "]"
end

local function getInstancePath(instance)
	local segments = {}
	local current = instance

	while current and current ~= game do
		table.insert(segments, 1, current.Name)
		current = current.Parent
	end

	if current ~= game or #segments == 0 then
		return nil
	end

	local path = ""
	for index, segment in ipairs(segments) do
		path ..= formatPathSegment(segment, index == 1)
	end

	return path
end

local function getSelectedPaths()
	local paths = {}

	for _, instance in ipairs(Selection:Get()) do
		local path = getInstancePath(instance)
		if path then
			table.insert(paths, path)
		end
	end

	return paths
end

function UI.new(plugin, pluginScript, session)
	local self = setmetatable({}, UI)
	self.plugin = plugin
	self.pluginScript = pluginScript
	self.session = session
	self.fusionCleanup = nil
	self.panelScaleGoal = nil
	self.activePage = "Overview"
	self.pages = {}
	self.pageScales = {}
	self.navButtons = {}
	self.connections = {}

	self.widget = self:createWidget()
	self:createContents()
	self:wire()
	self:switchPage("Overview", false)

	return self
end

function UI:createWidget()
	local info = DockWidgetPluginGuiInfo.new(
		Enum.InitialDockState.Right,
		false,
		false,
		400,
		500,
		330,
		360
	)

	local widget = self.plugin:CreateDockWidgetPluginGui("SutzStudioSyncerWidget", info)
	widget.Title = "Sutz Studio Syncer"
	return widget
end

function UI:createContents()
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundColor3 = COLORS.background
	root.BorderSizePixel = 0
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = self.widget
	self.root = root

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = root
	self.rootScale = scale
	self:tryAttachFusionScale(scale)

	padding(root, 14)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 12)
	layout.Parent = root

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 56)
	header.LayoutOrder = 1
	header.Parent = root

	local title = makeText(header, "Title", "Sutz Studio Syncer", 20, COLORS.text, Enum.Font.GothamBold)
	title.Size = UDim2.new(1, 0, 0, 26)

	self.statusLabel = makeText(header, "Status", "Idle", 13, COLORS.muted, Enum.Font.GothamMedium)
	self.statusLabel.Position = UDim2.fromOffset(0, 32)
	self.statusLabel.Size = UDim2.new(1, 0, 0, 20)

	self.nav = Instance.new("Frame")
	self.nav.Name = "Nav"
	self.nav.BackgroundColor3 = COLORS.panel
	self.nav.BorderSizePixel = 0
	self.nav.Size = UDim2.new(1, 0, 0, 42)
	self.nav.LayoutOrder = 2
	self.nav.Parent = root
	corner(self.nav, 8)
	stroke(self.nav, COLORS.border, 0.55)
	padding(self.nav, 5)

	local navLayout = Instance.new("UIListLayout")
	navLayout.FillDirection = Enum.FillDirection.Horizontal
	navLayout.SortOrder = Enum.SortOrder.LayoutOrder
	navLayout.Padding = UDim.new(0, 6)
	navLayout.Parent = self.nav

	self:createNavButton("Overview", 1)
	self:createNavButton("Settings", 2)
	self:createNavButton("Output", 3)

	local pageHost = Instance.new("Frame")
	pageHost.Name = "PageHost"
	pageHost.BackgroundTransparency = 1
	pageHost.Size = UDim2.new(1, 0, 1, -122)
	pageHost.LayoutOrder = 3
	pageHost.ClipsDescendants = true
	pageHost.Parent = root
	self.pageHost = pageHost

	self:createOverviewPage()
	self:createSettingsPage()
	self:createOutputPage()
end

function UI:createNavButton(name, order)
	local button = Instance.new("TextButton")
	button.Name = name .. "Tab"
	button.AutoButtonColor = false
	button.BackgroundColor3 = COLORS.panelSoft
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.Text = name
	button.TextColor3 = COLORS.muted
	button.TextSize = 13
	button.Size = UDim2.new(1 / 3, -4, 1, 0)
	button.LayoutOrder = order
	button.Parent = self.nav
	corner(button, 6)

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = button

	button.MouseEnter:Connect(function()
		if self.activePage ~= name then
			tween(button, { BackgroundColor3 = Color3.fromRGB(48, 53, 65), TextColor3 = COLORS.text }, 0.12)
		end
		tween(scale, { Scale = 1.015 }, 0.12)
	end)

	button.MouseLeave:Connect(function()
		if self.activePage ~= name then
			tween(button, { BackgroundColor3 = COLORS.panelSoft, TextColor3 = COLORS.muted }, 0.12)
		end
		tween(scale, { Scale = 1 }, 0.12)
	end)

	button.MouseButton1Click:Connect(function()
		self:switchPage(name, true)
	end)

	self.navButtons[name] = button
	return button
end

function UI:createPage(name)
	local page = Instance.new("Frame")
	page.Name = name .. "Page"
	page.BackgroundTransparency = 1
	page.Size = UDim2.fromScale(1, 1)
	page.Visible = false
	page.Parent = self.pageHost

	local pageScale = Instance.new("UIScale")
	pageScale.Scale = 0.985
	pageScale.Parent = page

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 12)
	layout.Parent = page

	self.pages[name] = page
	self.pageScales[name] = pageScale
	return page
end

function UI:createOverviewPage()
	local page = self:createPage("Overview")

	local actions = self:makePanel(page, "Connection", 1)
	local uri = makeText(actions, "Uri", Config.WS_URL, 13, COLORS.muted, Enum.Font.Code)
	uri.Size = UDim2.new(1, 0, 0, 20)
	self.overviewUriLabel = uri
	self.connectButton = makeButton(actions, "Connect", COLORS.accent)
	self.snapshotButton = makeButton(actions, "Send Snapshot", COLORS.panelSoft)

	local quick = self:makePanel(page, "Quick Actions", 2)
	self.settingsButton = makeButton(quick, "Open Settings", COLORS.panelSoft)
	self.outputButton = makeButton(quick, "View Output", COLORS.panelSoft)
end

function UI:createSettingsPage()
	local page = self:createPage("Settings")

	local connection = self:makePanel(page, "Connection Settings", 1)
	makeText(connection, "UrlLabel", "WebSocket URI", 12, COLORS.muted, Enum.Font.GothamMedium).Size =
		UDim2.new(1, 0, 0, 18)
	self.urlField = makeField(connection, Config.WS_URL)

	local behavior = self:makePanel(page, "Behavior", 2)
	self.debugToggle = makeButton(behavior, Config.DEBUG and "Debug: On" or "Debug: Off", COLORS.panelSoft)
	self.debugToggle.Size = UDim2.new(1, 0, 0, 32)

	makeText(behavior, "ServicesLabel", "Service List", 12, COLORS.muted, Enum.Font.GothamMedium).Size =
		UDim2.new(1, 0, 0, 18)
	self.serviceField = makeField(behavior, joinServices())
	self.serviceField.TextWrapped = false

	local hint = makeText(
		behavior,
		"Hint",
		"Comma-separated services. Example: Workspace, ReplicatedStorage, ServerScriptService",
		12,
		COLORS.muted,
		Enum.Font.Gotham
	)
	hint.Size = UDim2.new(1, 0, 0, 44)

	local misc = self:makePanel(page, "Misc", 3)
	self.copyPathButton = makeButton(misc, "Copy Path", COLORS.panelSoft)
	self.copyPathButton.Size = UDim2.new(1, 0, 0, 32)
end

function UI:createOutputPage()
	local page = self:createPage("Output")

	local output = self:makePanel(page, "Sync Output", 1)
	self.outputLabel = makeText(output, "Output", "Run `sutz` in a terminal, then connect from here.", 13, COLORS.muted)
	self.outputLabel.Size = UDim2.new(1, 0, 0, 80)

	local outputActions = self:makePanel(page, "Output Actions", 2)
	self.backToOverviewButton = makeButton(outputActions, "Back to Overview", COLORS.panelSoft)
end

function UI:makePanel(parent, titleText, order)
	local panel = Instance.new("Frame")
	panel.Name = titleText
	panel.BackgroundColor3 = COLORS.panel
	panel.BorderSizePixel = 0
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.Size = UDim2.new(1, 0, 0, 0)
	panel.LayoutOrder = order
	panel.Parent = parent
	corner(panel, 8)
	stroke(panel, COLORS.border, 0.55)
	padding(panel, 12)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = panel

	local title = makeText(panel, "SectionTitle", titleText, 13, COLORS.text, Enum.Font.GothamBold)
	title.Size = UDim2.new(1, 0, 0, 18)

	return panel
end

function UI:tryAttachFusionScale(scale)
	local fusionModule = self.pluginScript:FindFirstChild("Fusion")
	if not fusionModule then
		return
	end

	local ok, Fusion = pcall(require, fusionModule)
	if not ok then
		warn("[Sutz Syncer] Fusion could not load:", Fusion)
		return
	end

	local scope = Fusion.scoped(Fusion)
	local goal = scope:Value(1)
	local spring = scope:Spring(goal, 24, 0.82)
	self.fusionCleanup = scope
	self.panelScaleGoal = goal

	local okHydrate = pcall(function()
		scope:Hydrate(scale) {
			Scale = spring,
		}
	end)

	if not okHydrate then
		self.panelScaleGoal = nil
	end
end

function UI:wire()
	table.insert(self.connections, self.widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		self:onVisibilityChanged()
	end))

	self.connectButton.MouseButton1Click:Connect(function()
		self:toggleConnection()
	end)

	self.snapshotButton.MouseButton1Click:Connect(function()
		if self.session:isRunning() then
			self.session:sendSnapshot()
			self:setStatus("Snapshot sent", COLORS.success)
			self.outputLabel.Text = "Snapshot pushed to the local daemon."
			self:switchPage("Output", true)
		else
			self:setStatus("Connect before sending a snapshot", COLORS.danger)
		end
	end)

	self.settingsButton.MouseButton1Click:Connect(function()
		self:switchPage("Settings", true)
	end)

	self.outputButton.MouseButton1Click:Connect(function()
		self:switchPage("Output", true)
	end)

	self.backToOverviewButton.MouseButton1Click:Connect(function()
		self:switchPage("Overview", true)
	end)

	self.urlField.FocusLost:Connect(function()
		local value = string.gsub(self.urlField.Text, "^%s*(.-)%s*$", "%1")
		if value ~= "" then
			Config.WS_URL = value
			self.overviewUriLabel.Text = value
			self:setStatus("URI updated", COLORS.success)
		else
			self.urlField.Text = Config.WS_URL
		end
	end)

	self.debugToggle.MouseButton1Click:Connect(function()
		Config.DEBUG = not Config.DEBUG
		self.debugToggle.Text = Config.DEBUG and "Debug: On" or "Debug: Off"
		self:setStatus(Config.DEBUG and "Debug logging enabled" or "Debug logging disabled", COLORS.muted)
	end)

	self.copyPathButton.MouseButton1Click:Connect(function()
		self:copySelectedPaths()
	end)

	self.serviceField.FocusLost:Connect(function()
		applyServiceText(self.serviceField.Text)
		self.serviceField.Text = joinServices()
		self:setStatus("Service list updated", COLORS.success)
	end)

	table.insert(self.connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or input.KeyCode ~= Enum.KeyCode.C then
			return
		end

		if UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt) then
			self:copySelectedPaths()
		end
	end))
end

function UI:copySelectedPaths()
	local paths = getSelectedPaths()

	if #paths == 0 then
		self:setStatus("Select something first", COLORS.danger)
		self.outputLabel.Text = "Select one or more instances in Explorer or the viewport, then copy their paths."
		return
	end

	local text = table.concat(paths, "\n")
	local copied, errorMessage = self:copyTextWithDaemon(text)

	if not copied then
		self:setStatus("Clipboard copy failed", COLORS.danger)
		self.outputLabel.Text = (errorMessage or "Run `sutz`, then copy again.") .. "\n" .. text
		return
	end

	local suffix = #paths == 1 and "path" or "paths"
	self:setStatus(string.format("Copied %d %s", #paths, suffix), COLORS.success)
	self.outputLabel.Text = text
end

function UI:copyTextWithDaemon(text)
	local requestId = HttpService:GenerateGUID(false)
	local resultEvent = Instance.new("BindableEvent")
	local client = WebSocketClient.new(Config.WS_URL)
	local finished = false

	local function finish(ok, errorMessage)
		if finished then
			return
		end

		finished = true
		resultEvent:Fire(ok, errorMessage)
	end

	client:onMessage(function(message)
		if
			type(message) == "table"
			and message.type == Protocol.ServerMessage.CLIPBOARD_RESULT
			and message.requestId == requestId
		then
			finish(message.ok == true, message.error)
		end
	end)

	client:onClose(function()
		finish(false, "Connection closed before clipboard confirmation.")
	end)

	client:onError(function(err)
		finish(false, tostring(err))
	end)

	if not client:connect() then
		resultEvent:Destroy()
		return false, "Could not connect to `sutz`. Run `sutz`, then copy again."
	end

	local sent = client:send({
		type = Protocol.ClientMessage.COPY_TO_CLIPBOARD,
		text = text,
		requestId = requestId,
	})

	if not sent then
		client:close()
		resultEvent:Destroy()
		return false, "Could not send clipboard request to `sutz`."
	end

	task.delay(2, function()
		finish(false, "Timed out waiting for clipboard confirmation.")
	end)

	local ok, errorMessage = resultEvent.Event:Wait()
	client:close()
	resultEvent:Destroy()

	return ok, errorMessage
end

function UI:switchPage(name, animated)
	if not self.pages[name] then
		return
	end

	self.activePage = name

	for pageName, page in pairs(self.pages) do
		local isActive = pageName == name
		page.Visible = isActive
		if isActive then
			local pageScale = self.pageScales[pageName]
			if pageScale then
				pageScale.Scale = animated and 0.975 or 1
				tween(pageScale, { Scale = 1 }, 0.16)
			end
		end
	end

	for pageName, button in pairs(self.navButtons) do
		local isActive = pageName == name
		tween(button, {
			BackgroundColor3 = isActive and COLORS.accent or COLORS.panelSoft,
			TextColor3 = isActive and Color3.fromRGB(255, 255, 255) or COLORS.muted,
		}, animated and 0.14 or 0)
	end
end

function UI:onVisibilityChanged()
	if self.widget.Enabled then
		if self.panelScaleGoal then
			self.panelScaleGoal:set(0.965)
			task.defer(function()
				if self.panelScaleGoal then
					self.panelScaleGoal:set(1)
				end
			end)
		else
			self.rootScale.Scale = 0.965
			tween(self.rootScale, { Scale = 1 }, 0.18)
		end
	end

	self:updateConnectionVisuals()
end

function UI:toggle()
	self.widget.Enabled = not self.widget.Enabled
end

function UI:toggleConnection()
	if self.session:isRunning() then
		self.session:stop()
		self:setStatus("Disconnected", COLORS.muted)
		self.outputLabel.Text = "The daemon connection is closed."
	else
		Config.WS_URL = self.urlField.Text
		self.overviewUriLabel.Text = Config.WS_URL
		self:setStatus("Connecting...", COLORS.accentSoft)
		local connected = self.session:start()
		if connected then
			self:setStatus("Connected", COLORS.success)
			self.outputLabel.Text = "Connected. Studio changes can now be sent to the daemon."
		else
			self:setStatus("Failed to connect. Check Output.", COLORS.danger)
			self.outputLabel.Text = "Make sure `sutz` is running and HTTP requests are enabled."
			self:switchPage("Output", true)
		end
	end

	self:updateConnectionVisuals()
end

function UI:updateConnectionVisuals()
	if self.session:isRunning() then
		self.connectButton.Text = "Disconnect"
		tween(self.connectButton, { BackgroundColor3 = COLORS.danger }, 0.12)
	else
		self.connectButton.Text = "Connect"
		tween(self.connectButton, { BackgroundColor3 = COLORS.accent }, 0.12)
	end
end

function UI:setStatus(text, color)
	self.statusLabel.Text = text
	tween(self.statusLabel, { TextColor3 = color or COLORS.muted }, 0.12)
end

function UI:destroy()
	if self.session then
		self.session:stop()
	end

	for _, connection in ipairs(self.connections) do
		connection:Disconnect()
	end
	self.connections = {}

	if self.fusionCleanup then
		local ok, Fusion = pcall(require, self.pluginScript.Fusion)
		if ok and Fusion.doCleanup then
			Fusion.doCleanup(self.fusionCleanup)
		end
	end
end

return UI
