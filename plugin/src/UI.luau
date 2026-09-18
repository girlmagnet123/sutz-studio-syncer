--!nonstrict


local HttpService = game:GetService("HttpService")
local InsertService = game:GetService("InsertService")
local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")
local UserInputService = game:GetService("UserInputService")

local Config = require(script.Parent.Config)
local Protocol = require(script.Parent.Protocol)
local WebSocketClient = require(script.Parent.WebSocketClient)

local UI = {}
UI.__index = UI

local WS_URL_SETTING = "SutzStudioSyncer_WsUrl"
local ICON = "rbxassetid://117603874582847"

local COLORS = {
	bg = Color3.fromRGB(10, 11, 14),
	bgStreak = Color3.fromRGB(44, 65, 86),
	panel = Color3.fromRGB(18, 20, 25),
	panelSoft = Color3.fromRGB(28, 32, 39),
	field = Color3.fromRGB(21, 23, 29),
	fieldFocused = Color3.fromRGB(30, 33, 43),
	border = Color3.fromRGB(54, 60, 72),
	text = Color3.fromRGB(238, 241, 248),
	muted = Color3.fromRGB(150, 158, 176),
	accent = Color3.fromRGB(70, 150, 232),
	accentSoft = Color3.fromRGB(134, 194, 255),
	success = Color3.fromRGB(78, 205, 145),
	danger = Color3.fromRGB(224, 92, 116),
	warning = Color3.fromRGB(236, 180, 88),
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

local function resolveFusion(pluginScript)
	local candidates = {
		script.Parent and script.Parent:FindFirstChild("Fusion") or nil,
		pluginScript and pluginScript:FindFirstChild("Fusion") or nil,
		script:FindFirstChild("Fusion"),
	}

	for _, mod in ipairs(candidates) do
		if mod then
			local ok, fusion = pcall(require, mod)
			if ok then
				return fusion
			end
			warn("[Sutz Syncer] Found Fusion but failed to require it:", fusion)
		end
	end

	error("[Sutz Syncer] Fusion ModuleScript not found. Place 'Fusion' next to Main or UI.")
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

local function isCopyPathShortcut(input)
	if input.KeyCode ~= Enum.KeyCode.C then
		return false
	end
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)
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

local function makePanel(parent, titleText, order)
	local panel = Instance.new("Frame")
	panel.Name = titleText
	panel.BackgroundColor3 = COLORS.panel
	panel.BorderSizePixel = 0
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.Size = UDim2.new(1, 0, 0, 0)
	panel.LayoutOrder = order
	panel.Parent = parent
	corner(panel, 10)
	stroke(panel, COLORS.border, 0.5)
	padding(panel, 12)

	local panelGradient = Instance.new("UIGradient")
	panelGradient.Color = ColorSequence.new(Color3.fromRGB(30, 33, 42), Color3.fromRGB(18, 19, 25))
	panelGradient.Rotation = 90
	panelGradient.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = panel

	local title = makeText(panel, "SectionTitle", titleText, 13, COLORS.text, Enum.Font.GothamBold)
	title.Size = UDim2.new(1, 0, 0, 18)

	return panel
end



function UI.new(plugin, pluginScript, session)
	local self = setmetatable({}, UI)
	self.plugin = plugin
	self.pluginScript = pluginScript
	self.session = session
	self.activePage = "Overview"
	self.connections = {}
	self.activityLines = {}
	self.maxActivityLines = 80
	self.wasConnected = false

	self:loadSavedSettings()
	self.session:setBaseUrl(Config.WS_URL)

	local Fusion = resolveFusion(pluginScript)
	self.Fusion = Fusion
	local scope = Fusion:scoped()
	self.scope = scope

	self.state = {
		activePage = scope:Value("Overview"),
		statusText = scope:Value("Idle"),
		statusColor = scope:Value(COLORS.muted),
		connected = scope:Value(false),
		debug = scope:Value(Config.DEBUG),
		streakT = scope:Value(0), 
		pulse = scope:Value(0), 
		entrance = scope:Value(0.95), 
	}

	self.session:onActivity(function(text)
		self:addActivity(text)
	end)
	self.session:onStateChanged(function(running, errorMessage, url)
		self:onSessionStateChanged(running, errorMessage, url)
	end)

	self.widget = self:createWidget()
	self:build()
	self:wire()
	self:startAmbient()
	self:switchPage("Overview")
	self:updateConnectionVisuals()
	self:addActivity("Run `sutz` in a terminal, then connect from here.")

	return self
end

function UI:loadSavedSettings()
	local ok, saved = pcall(function()
		return self.plugin:GetSetting(WS_URL_SETTING)
	end)
	if ok and type(saved) == "string" and saved ~= "" then
		Config.WS_URL = saved
	end
end

function UI:saveUrl(url)
	pcall(function()
		self.plugin:SetSetting(WS_URL_SETTING, url)
	end)
end

function UI:createWidget()
	local info = DockWidgetPluginGuiInfo.new(
		Enum.InitialDockState.Right,
		false,
		false,
		400,
		520,
		330,
		360
	)
	local widget = self.plugin:CreateDockWidgetPluginGui("SutzStudioSyncerWidget", info)
	widget.Title = "Sutz Studio Syncer"
	return widget
end



function UI:build()
	local scope = self.scope
	local Fusion = self.Fusion
	local state = self.state

	local function New(class)
		return scope:New(class)
	end
	local function Value(v)
		return scope:Value(v)
	end
	local function Computed(fn)
		return scope:Computed(fn)
	end
	local function Spring(goal, speed, damping)
		return scope:Spring(goal, speed, damping)
	end
	local Children = Fusion.Children
	local OnEvent = Fusion.OnEvent

	local function hoverTint(c)
		return c:Lerp(Color3.new(1, 1, 1), 0.14)
	end

	
	local function Button(props)
		local hovered = Value(false)
		local pressed = Value(false)
		local base = props.baseColor or COLORS.accent

		local scaleSpring = Spring(
			Computed(function(use)
				if use(pressed) then
					return 0.97
				elseif use(hovered) then
					return 1.03
				end
				return 1
			end),
			34,
			0.7
		)

		local colorSpring = Spring(
			Computed(function(use)
				local c = use(base)
				return if use(hovered) then hoverTint(c) else c
			end),
			26,
			1
		)

		local glowStroke = Spring(
			Computed(function(use)
				return if use(hovered) then 0.15 else 1
			end),
			26,
			1
		)

		return New("TextButton") {
			Name = props.name or "Button",
			AutoButtonColor = false,
			BackgroundColor3 = colorSpring,
			BorderSizePixel = 0,
			Text = "",
			Size = props.size or UDim2.new(1, 0, 0, 38),
			LayoutOrder = props.order,
			[OnEvent("MouseEnter")] = function()
				hovered:set(true)
			end,
			[OnEvent("MouseLeave")] = function()
				hovered:set(false)
				pressed:set(false)
			end,
			[OnEvent("MouseButton1Down")] = function()
				pressed:set(true)
			end,
			[OnEvent("MouseButton1Up")] = function()
				pressed:set(false)
			end,
			[Children] = {
				New("UICorner") { CornerRadius = UDim.new(0, 8) },
				New("UIScale") { Scale = scaleSpring },
				New("UIStroke") {
					Color = COLORS.accentSoft,
					Thickness = 1.4,
					Transparency = glowStroke,
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				},
				New("TextLabel") {
					Name = "Label",
					BackgroundTransparency = 1,
					Font = Enum.Font.GothamBold,
					Text = props.text or "",
					TextColor3 = props.textColor or Color3.fromRGB(255, 255, 255),
					TextSize = 14,
					Size = UDim2.fromScale(1, 1),
					ZIndex = 2,
					[Children] = {
						New("UIStroke") {
							Color = Color3.fromRGB(0, 0, 0),
							Thickness = 1.6,
							Transparency = 0.25,
							ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
							LineJoinMode = Enum.LineJoinMode.Round,
						},
					},
				},
			},
		}
	end

	
	local function NavTab(name, order)
		local hovered = Value(false)
		local isActive = Computed(function(use)
			return use(state.activePage) == name
		end)

		local bg = Spring(
			Computed(function(use)
				if use(isActive) then
					return COLORS.accent
				elseif use(hovered) then
					return hoverTint(COLORS.panelSoft)
				end
				return COLORS.panelSoft
			end),
			28,
			1
		)
		local txt = Spring(
			Computed(function(use)
				if use(isActive) then
					return Color3.fromRGB(255, 255, 255)
				elseif use(hovered) then
					return COLORS.text
				end
				return COLORS.muted
			end),
			28,
			1
		)
		local scl = Spring(
			Computed(function(use)
				return if use(hovered) then 1.02 else 1
			end),
			30,
			0.7
		)

		local tab = New("TextButton") {
			Name = name .. "Tab",
			AutoButtonColor = false,
			BackgroundColor3 = bg,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamBold,
			Text = name,
			TextColor3 = txt,
			TextSize = 13,
			Size = UDim2.new(1 / 3, -4, 1, 0),
			LayoutOrder = order,
			[OnEvent("MouseEnter")] = function()
				hovered:set(true)
			end,
			[OnEvent("MouseLeave")] = function()
				hovered:set(false)
			end,
			[Children] = {
				New("UICorner") { CornerRadius = UDim.new(0, 6) },
				New("UIScale") { Scale = scl },
			},
		}

		tab.MouseButton1Click:Connect(function()
			self:switchPage(name, true)
		end)
		return tab
	end


	local function Field(parent, text, placeholder)
		local focused = Value(false)

		local box = New("TextBox") {
			BackgroundColor3 = Spring(
				Computed(function(use)
					return if use(focused) then COLORS.fieldFocused else COLORS.field
				end),
				26,
				1
			),
			BorderSizePixel = 0,
			ClearTextOnFocus = false,
			Font = Enum.Font.Code,
			PlaceholderColor3 = Color3.fromRGB(110, 118, 138),
			PlaceholderText = placeholder or "",
			Text = text or "",
			TextColor3 = COLORS.text,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			Size = UDim2.new(1, 0, 0, 32),
			[OnEvent("Focused")] = function()
				focused:set(true)
			end,
			[OnEvent("FocusLost")] = function()
				focused:set(false)
			end,
			[Children] = {
				New("UICorner") { CornerRadius = UDim.new(0, 6) },
				New("UIPadding") {
					PaddingLeft = UDim.new(0, 8),
					PaddingRight = UDim.new(0, 8),
					PaddingTop = UDim.new(0, 6),
					PaddingBottom = UDim.new(0, 6),
				},
				New("UIStroke") {
					Color = COLORS.accent,
					Thickness = 1.2,
					Transparency = Spring(
						Computed(function(use)
							return if use(focused) then 0.25 else 0.75
						end),
						26,
						1
					),
				},
			},
		}
		box.Parent = parent
		return box
	end


	local function makePage(name)
		local isActive = Computed(function(use)
			return use(state.activePage) == name
		end)
		local scaleSpring = Spring(
			Computed(function(use)
				return if use(isActive) then 1 else 0.96
			end),
			30,
			0.82
		)

		local page = New("ScrollingFrame") {
			Name = name .. "Page",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			Visible = isActive,
			Active = true,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 5,
			ScrollBarImageColor3 = COLORS.accent,
			ScrollBarImageTransparency = 0.35,
			VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
			ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
			TopImage = "rbxasset://textures/ui/Scroll/scroll-middle.png",
			BottomImage = "rbxasset://textures/ui/Scroll/scroll-middle.png",
			[Children] = {
				New("UIScale") { Scale = scaleSpring },
				New("UIListLayout") {
					FillDirection = Enum.FillDirection.Vertical,
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 12),
				},
				New("UIPadding") {
					PaddingBottom = UDim.new(0, 6),
					PaddingRight = UDim.new(0, 2),
				},
			},
		}
		page.Parent = self.pageHost
		return page
	end


	local rootScale = Spring(state.entrance, 22, 0.8)

	local streakOffset = Computed(function(use)
		return Vector2.new((use(state.streakT) - 0.5) * 0.85, 0)
	end)

	local root = New("Frame") {
		Name = "Root",
		BackgroundColor3 = COLORS.bg,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1),
		[Children] = {
			New("UIScale") { Scale = rootScale },
			New("UIGradient") {
				Color = ColorSequence.new(Color3.fromRGB(20, 21, 27), Color3.fromRGB(7, 7, 10)),
				Rotation = 90,
			},
	
			New("Frame") {
				Name = "Streaks",
				BackgroundColor3 = COLORS.bgStreak,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1.6, 1.6),
				ZIndex = 0,
				[Children] = {
					New("UIGradient") {
						Rotation = 24,
						Offset = streakOffset,
						Transparency = NumberSequence.new({
							NumberSequenceKeypoint.new(0, 1),
							NumberSequenceKeypoint.new(0.26, 1),
							NumberSequenceKeypoint.new(0.32, 0.62),
							NumberSequenceKeypoint.new(0.38, 1),
							NumberSequenceKeypoint.new(0.63, 1),
							NumberSequenceKeypoint.new(0.69, 0.72),
							NumberSequenceKeypoint.new(0.75, 1),
							NumberSequenceKeypoint.new(1, 1),
						}),
					},
				},
			},
		},
	}
	root.Parent = self.widget
	self.root = root


	local content = New("Frame") {
		Name = "Content",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		[Children] = {
			New("UIPadding") {
				PaddingTop = UDim.new(0, 14),
				PaddingBottom = UDim.new(0, 14),
				PaddingLeft = UDim.new(0, 14),
				PaddingRight = UDim.new(0, 14),
			},
			New("UIListLayout") {
				FillDirection = Enum.FillDirection.Vertical,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 12),
			},
		},
	}
	content.Parent = root
	self.content = content

	local logoHover = Value(false)
	local statusColorSpring = Spring(state.statusColor, 24, 1)

	local header = New("Frame") {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 58),
		LayoutOrder = 1,
		ZIndex = 2,
		[Children] = {
			New("ImageButton") {
				Name = "Logo",
				BackgroundColor3 = COLORS.panel,
				BorderSizePixel = 0,
				AutoButtonColor = false,
				Image = ICON,
				ScaleType = Enum.ScaleType.Fit,
				Size = UDim2.fromOffset(50, 50),
				Position = UDim2.fromOffset(0, 4),
				[OnEvent("MouseEnter")] = function()
					logoHover:set(true)
				end,
				[OnEvent("MouseLeave")] = function()
					logoHover:set(false)
				end,
				[OnEvent("MouseButton1Click")] = function()
					self:switchPage("Overview", true)
				end,
				[Children] = {
					New("UICorner") { CornerRadius = UDim.new(0, 13) },
					New("UIScale") {
						Scale = Spring(
							Computed(function(use)
								return if use(logoHover) then 1.07 else 1
							end),
							30,
							0.55
						),
					},
					New("UIStroke") {
						Color = COLORS.accentSoft,
						Thickness = 1.5,
						Transparency = Spring(
							Computed(function(use)
								local floor = if use(logoHover) then 0.1 else 0.55
								return floor + 0.25 * (1 - use(state.pulse))
							end),
							20,
							1
						),
					},
				},
			},
			New("TextLabel") {
				Name = "Title",
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				Text = "Sutz Studio Syncer",
				TextColor3 = COLORS.text,
				TextSize = 19,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				Position = UDim2.fromOffset(62, 4),
				Size = UDim2.new(1, -62, 0, 24),
				[Children] = {
					New("UIGradient") {
						Color = ColorSequence.new(COLORS.text, COLORS.accentSoft),
						Rotation = 16,
						Offset = Computed(function(use)
							return Vector2.new(use(state.streakT) * 2 - 1, 0)
						end),
					},
				},
			},
			New("Frame") {
				Name = "StatusGlow",
				BackgroundColor3 = statusColorSpring,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(64 + 4, 40 + 4),
				Size = UDim2.fromOffset(18, 18),
				ZIndex = 1,
				BackgroundTransparency = Computed(function(use)
					if not use(state.connected) then
						return 1
					end
					return 0.45 + 0.4 * (1 - use(state.pulse))
				end),
				[Children] = {
					New("UICorner") { CornerRadius = UDim.new(1, 0) },
				},
			},
			New("Frame") {
				Name = "StatusDot",
				BackgroundColor3 = statusColorSpring,
				BorderSizePixel = 0,
				Size = UDim2.fromOffset(8, 8),
				Position = UDim2.fromOffset(62, 36),
				ZIndex = 2,
				[Children] = {
					New("UICorner") { CornerRadius = UDim.new(1, 0) },
				},
			},
			New("TextLabel") {
				Name = "Status",
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamMedium,
				Text = state.statusText,
				TextColor3 = statusColorSpring,
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				Position = UDim2.fromOffset(76, 32),
				Size = UDim2.new(1, -76, 0, 20),
			},
		},
	}
	header.Parent = content


	local nav = New("Frame") {
		Name = "Nav",
		BackgroundColor3 = COLORS.panel,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 42),
		LayoutOrder = 2,
		ZIndex = 2,
		[Children] = {
			New("UICorner") { CornerRadius = UDim.new(0, 9) },
			New("UIStroke") { Color = COLORS.border, Transparency = 0.5, Thickness = 1 },
			New("UIPadding") {
				PaddingTop = UDim.new(0, 5),
				PaddingBottom = UDim.new(0, 5),
				PaddingLeft = UDim.new(0, 5),
				PaddingRight = UDim.new(0, 5),
			},
			New("UIListLayout") {
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 6),
			},
		},
	}
	nav.Parent = content

	NavTab("Overview", 1).Parent = nav
	NavTab("Settings", 2).Parent = nav
	NavTab("Output", 3).Parent = nav


	local pageHost = New("Frame") {
		Name = "PageHost",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, -124),
		LayoutOrder = 3,
		ClipsDescendants = true,
		ZIndex = 2,
	}
	pageHost.Parent = content
	self.pageHost = pageHost

	do
		local page = makePage("Overview")

		local connectionPanel = makePanel(page, "Connection", 1)
		local uri = makeText(connectionPanel, "Uri", Config.WS_URL, 13, COLORS.muted, Enum.Font.Code)
		uri.Size = UDim2.new(1, 0, 0, 20)
		self.overviewUriLabel = uri

		self.connectButton = Button({
			name = "Connect",
			text = Computed(function(use)
				return if use(state.connected) then "Disconnect" else "Connect"
			end),
			baseColor = Computed(function(use)
				return if use(state.connected) then COLORS.danger else COLORS.accent
			end),
		})
		self.connectButton.Parent = connectionPanel

		self.snapshotButton = Button({ name = "Snapshot", text = "Send Snapshot", baseColor = COLORS.panelSoft })
		self.snapshotButton.Parent = connectionPanel

		local quickPanel = makePanel(page, "Quick Actions", 2)
		self.settingsButton = Button({ name = "OpenSettings", text = "Open Settings", baseColor = COLORS.panelSoft })
		self.settingsButton.Parent = quickPanel
		self.outputButton = Button({ name = "ViewOutput", text = "View Output", baseColor = COLORS.panelSoft })
		self.outputButton.Parent = quickPanel
	end

	do
		local page = makePage("Settings")

		local connection = makePanel(page, "Connection Settings", 1)
		makeText(connection, "UrlLabel", "WebSocket URI", 12, COLORS.muted, Enum.Font.GothamMedium).Size =
			UDim2.new(1, 0, 0, 18)
		self.urlField = Field(connection, Config.WS_URL)

		local behavior = makePanel(page, "Behavior", 2)
		self.debugToggle = Button({
			name = "DebugToggle",
			baseColor = COLORS.panelSoft,
			size = UDim2.new(1, 0, 0, 32),
			text = Computed(function(use)
				return if use(state.debug) then "Debug: On" else "Debug: Off"
			end),
		})
		self.debugToggle.Parent = behavior

		makeText(behavior, "ServicesLabel", "Service List", 12, COLORS.muted, Enum.Font.GothamMedium).Size =
			UDim2.new(1, 0, 0, 18)
		self.serviceField = Field(behavior, joinServices())
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

		local misc = makePanel(page, "Misc", 3)
		self.copyPathButton = Button({
			name = "CopyPath",
			text = "Copy Path",
			baseColor = COLORS.panelSoft,
			size = UDim2.new(1, 0, 0, 32),
		})
		self.copyPathButton.Parent = misc

		makeText(misc, "AssetIdLabel", "Asset ID", 12, COLORS.muted, Enum.Font.GothamMedium).Size =
			UDim2.new(1, 0, 0, 18)
		self.assetIdField = Field(misc, "", "Enter an asset id...")
		self.loadAssetButton = Button({
			name = "LoadAsset",
			text = "Load Asset",
			baseColor = COLORS.accent,
			size = UDim2.new(1, 0, 0, 32),
		})
		self.loadAssetButton.Parent = misc
	end

	do
		local page = makePage("Output")

		local output = makePanel(page, "Activity Log", 1)
		self.outputLabel = makeText(output, "Output", "", 12, COLORS.muted, Enum.Font.Code)
		self.outputLabel.AutomaticSize = Enum.AutomaticSize.Y
		self.outputLabel.Size = UDim2.new(1, 0, 0, 0)
		self.outputLabel.TextWrapped = true

		local outputActions = makePanel(page, "Output Actions", 2)
		self.backToOverviewButton = Button({ name = "BackToOverview", text = "Back to Overview", baseColor = COLORS.panelSoft })
		self.backToOverviewButton.Parent = outputActions
	end
end



function UI:startAmbient()
	local accum = 0
	local hb = RunService.Heartbeat:Connect(function(dt)
		accum += dt
		self.state.streakT:set((accum * 0.05) % 1) 
		self.state.pulse:set((math.sin(accum * 3.2) + 1) * 0.5)
	end)
	table.insert(self.connections, hb)
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
			self:setStatus("Sending snapshot batches...", COLORS.muted)
			if self.session:sendSnapshot() then
				self:setStatus("Snapshot sent", COLORS.success)
				self:addActivity("Snapshot pushed to the local daemon.")
			else
				self:setStatus(self.session.lastError or "Snapshot cancelled", COLORS.danger)
			end
			self:switchPage("Output", true)
		else
			self:setStatus("Connect before sending a snapshot", COLORS.danger)
			self:addActivity("Connect before sending a snapshot.")
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
			local url = self.session:setBaseUrl(value)
			self.overviewUriLabel.Text = url
			self.urlField.Text = url
			self:saveUrl(url)
			self:setStatus("URI updated", COLORS.success)
		else
			self.session:setBaseUrl(Config.WS_URL)
			self.urlField.Text = Config.WS_URL
		end
	end)

	self.debugToggle.MouseButton1Click:Connect(function()
		Config.DEBUG = not Config.DEBUG
		self.state.debug:set(Config.DEBUG)
		self:setStatus(Config.DEBUG and "Debug logging enabled" or "Debug logging disabled", COLORS.muted)
	end)

	self.copyPathButton.MouseButton1Click:Connect(function()
		self:copySelectedPaths()
	end)

	self.loadAssetButton.MouseButton1Click:Connect(function()
		self:loadAsset()
	end)

	self.assetIdField.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			self:loadAsset()
		end
	end)

	self.serviceField.FocusLost:Connect(function()
		applyServiceText(self.serviceField.Text)
		self.serviceField.Text = joinServices()
		self:setStatus("Service list updated", COLORS.success)
	end)

	table.insert(self.connections, UserInputService.InputBegan:Connect(function(input)
		if not isCopyPathShortcut(input) or UserInputService:GetFocusedTextBox() then
			return
		end
		self:copySelectedPaths()
	end))
end


function UI:copySelectedPaths()
	local paths = getSelectedPaths()

	if #paths == 0 then
		self:setStatus("Select something first", COLORS.danger)
		self:addActivity("Select one or more instances in Explorer or the viewport, then copy their paths.")
		return
	end

	local text = table.concat(paths, "\n")
	local copied, errorMessage = self:copyTextWithDaemon(text)

	if not copied then
		self:setStatus("Clipboard copy failed", COLORS.danger)
		self:addActivity((errorMessage or "Run `sutz`, then copy again.") .. "\n" .. text)
		return
	end

	local suffix = #paths == 1 and "path" or "paths"
	self:setStatus(string.format("Copied %d %s", #paths, suffix), COLORS.success)
	self:addActivity(text)
end

function UI:loadAsset()
	local raw = string.gsub(self.assetIdField.Text, "%s", "")
	local assetId = tonumber(raw)

	if not assetId then
		self:setStatus("Enter a valid asset id", COLORS.danger)
		self:addActivity("Asset ID must be a number. Example: 123456789")
		return
	end

	local ok, result = pcall(function()
		return InsertService:LoadAsset(assetId)
	end)

	if not ok then
		self:setStatus("Asset load failed", COLORS.danger)
		self:addActivity(string.format("Could not load asset %d:\n%s", assetId, tostring(result)))
		self:switchPage("Output", true)
		return
	end

	result.Parent = game.Workspace
	self:setStatus("Asset loaded", COLORS.success)
	self:addActivity(string.format("Loaded asset %d into Workspace.", assetId))
end

function UI:copyTextWithDaemon(text)
	local requestId = HttpService:GenerateGUID(false)
	local resultEvent = Instance.new("BindableEvent")
	local daemonUrl = self.session:getConnectedUrl() or Config.WS_URL
	local client = WebSocketClient.new(daemonUrl)
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


function UI:addActivity(text)
	local line = string.format("[%s] %s", os.date("%H:%M:%S"), tostring(text))
	table.insert(self.activityLines, line)

	while #self.activityLines > self.maxActivityLines do
		table.remove(self.activityLines, 1)
	end

	if self.outputLabel then
		self.outputLabel.Text = table.concat(self.activityLines, "\n")
	end
end

function UI:onSessionStateChanged(running, errorMessage, url)
	local displayUrl = if running and url and url ~= "" then url else Config.WS_URL
	self.overviewUriLabel.Text = displayUrl
	self.urlField.Text = Config.WS_URL

	self.state.connected:set(running)

	if running then
		self.wasConnected = true
		self:setStatus("Connected", COLORS.success)
	elseif self.wasConnected then
		self.wasConnected = false
		if errorMessage and errorMessage ~= "" then
			self:setStatus("Disconnected", COLORS.danger)
		else
			self:setStatus("Disconnected", COLORS.muted)
		end
	end
end


function UI:switchPage(name, _animated)
	if not (name == "Overview" or name == "Settings" or name == "Output") then
		return
	end
	self.activePage = name
	self.state.activePage:set(name)
end

function UI:onVisibilityChanged()
	if self.widget.Enabled then
		self.state.entrance:set(0.95)
		task.defer(function()
			if self.state then
				self.state.entrance:set(1)
			end
		end)
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
		self:addActivity("The daemon connection is closed.")
	else
		local baseUrl = Config.WS_URL
		local value = string.gsub(self.urlField.Text, "^%s*(.-)%s*$", "%1")
		if value ~= "" then
			baseUrl = self.session:setBaseUrl(value)
		else
			baseUrl = self.session:setBaseUrl(baseUrl)
		end
		self.urlField.Text = baseUrl
		self.overviewUriLabel.Text = baseUrl
		self:saveUrl(baseUrl)
		self:setStatus("Connecting...", COLORS.accentSoft)

		local connected = self.session:start(baseUrl)
		local connectedUrl = self.session:getConnectedUrl() or baseUrl
		self.overviewUriLabel.Text = connectedUrl
		if connected then
			self:setStatus("Connected", COLORS.success)
			self:addActivity(string.format("Paired with %s. Studio changes are now synced to that daemon.", connectedUrl))
		else
			self:setStatus("Failed to connect. Check Output.", COLORS.danger)
			self:addActivity(self.session.lastError or "Make sure `sutz` is running and HTTP requests are enabled.")
			self:switchPage("Output", true)
		end
	end

	self:updateConnectionVisuals()
end

function UI:updateConnectionVisuals()
	self.state.connected:set(self.session:isRunning())
end

function UI:setStatus(text, color)
	self.state.statusText:set(text)
	self.state.statusColor:set(color or COLORS.muted)
end


function UI:destroy()
	if self.session then
		self.session:stop()
	end

	for _, connection in ipairs(self.connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	self.connections = {}

	if self.scope and self.Fusion and self.Fusion.doCleanup then
		pcall(self.Fusion.doCleanup, self.scope)
	end
end

return UI
