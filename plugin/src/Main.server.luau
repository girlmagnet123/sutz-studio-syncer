--!nonstrict

local RunService = game:GetService("RunService")

if RunService:IsRunning() then
	return
end

local SyncSession = require(script.SyncSession)

local toolbar = plugin:CreateToolbar("Sutz Syncer")
local toggleButton = toolbar:CreateButton(
	"Sutz Sync",
	"Open Sutz Studio Syncer",
	""
)

toggleButton.ClickableWhenViewportHidden = true

local session = SyncSession.new()

local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Right,
	false,
	false,
	320,
	220,
	260,
	180
)

local widget = plugin:CreateDockWidgetPluginGui("SutzStudioSyncerWidget", widgetInfo)
widget.Title = "Sutz Studio Syncer"

local root = Instance.new("Frame")
root.Name = "Root"
root.BackgroundColor3 = Color3.fromRGB(28, 30, 36)
root.BorderSizePixel = 0
root.Size = UDim2.fromScale(1, 1)
root.Parent = widget

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 14)
padding.PaddingRight = UDim.new(0, 14)
padding.PaddingBottom = UDim.new(0, 14)
padding.PaddingLeft = UDim.new(0, 14)
padding.Parent = root

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Vertical
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 10)
layout.Parent = root

local title = Instance.new("TextLabel")
title.Name = "Title"
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.Text = "Sutz Studio Syncer"
title.TextColor3 = Color3.fromRGB(245, 247, 255)
title.TextSize = 18
title.TextXAlignment = Enum.TextXAlignment.Left
title.Size = UDim2.new(1, 0, 0, 24)
title.LayoutOrder = 1
title.Parent = root

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "Status"
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.Gotham
statusLabel.Text = "Status: Idle"
statusLabel.TextColor3 = Color3.fromRGB(190, 198, 214)
statusLabel.TextSize = 14
statusLabel.TextWrapped = true
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextYAlignment = Enum.TextYAlignment.Top
statusLabel.Size = UDim2.new(1, 0, 0, 42)
statusLabel.LayoutOrder = 2
statusLabel.Parent = root

local urlLabel = Instance.new("TextLabel")
urlLabel.Name = "Url"
urlLabel.BackgroundTransparency = 1
urlLabel.Font = Enum.Font.Code
urlLabel.Text = "ws://localhost:8181"
urlLabel.TextColor3 = Color3.fromRGB(142, 224, 179)
urlLabel.TextSize = 13
urlLabel.TextXAlignment = Enum.TextXAlignment.Left
urlLabel.Size = UDim2.new(1, 0, 0, 20)
urlLabel.LayoutOrder = 3
urlLabel.Parent = root

local connectButton = Instance.new("TextButton")
connectButton.Name = "ConnectButton"
connectButton.AutoButtonColor = true
connectButton.BackgroundColor3 = Color3.fromRGB(67, 115, 214)
connectButton.BorderSizePixel = 0
connectButton.Font = Enum.Font.GothamBold
connectButton.Text = "Connect"
connectButton.TextColor3 = Color3.fromRGB(255, 255, 255)
connectButton.TextSize = 14
connectButton.Size = UDim2.new(1, 0, 0, 34)
connectButton.LayoutOrder = 4
connectButton.Parent = root

local connectCorner = Instance.new("UICorner")
connectCorner.CornerRadius = UDim.new(0, 6)
connectCorner.Parent = connectButton

local snapshotButton = Instance.new("TextButton")
snapshotButton.Name = "SnapshotButton"
snapshotButton.AutoButtonColor = true
snapshotButton.BackgroundColor3 = Color3.fromRGB(48, 52, 62)
snapshotButton.BorderSizePixel = 0
snapshotButton.Font = Enum.Font.GothamMedium
snapshotButton.Text = "Send Snapshot"
snapshotButton.TextColor3 = Color3.fromRGB(235, 239, 247)
snapshotButton.TextSize = 14
snapshotButton.Size = UDim2.new(1, 0, 0, 32)
snapshotButton.LayoutOrder = 5
snapshotButton.Parent = root

local snapshotCorner = Instance.new("UICorner")
snapshotCorner.CornerRadius = UDim.new(0, 6)
snapshotCorner.Parent = snapshotButton

local function updateButton()
	if session:isRunning() then
		toggleButton:SetActive(true)
		connectButton.Text = "Disconnect"
		connectButton.BackgroundColor3 = Color3.fromRGB(174, 74, 92)
		statusLabel.Text = "Status: Connected"
	else
		toggleButton:SetActive(false)
		connectButton.Text = "Connect"
		connectButton.BackgroundColor3 = Color3.fromRGB(67, 115, 214)
		statusLabel.Text = "Status: Idle"
	end
end

toggleButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
	updateButton()
end)

connectButton.MouseButton1Click:Connect(function()
	if session:isRunning() then
		session:stop()
	else
		statusLabel.Text = "Status: Connecting..."
		local connected = session:start()
		if not connected then
			statusLabel.Text = "Status: Failed to connect. Check Output."
		end
	end

	if session:isRunning() then
		updateButton()
	elseif connectButton.Text ~= "Connect" then
		updateButton()
	end
end)

snapshotButton.MouseButton1Click:Connect(function()
	if session:isRunning() then
		session:sendSnapshot()
		statusLabel.Text = "Status: Snapshot sent"
	else
		statusLabel.Text = "Status: Connect before sending a snapshot"
	end
end)

widget:GetPropertyChangedSignal("Enabled"):Connect(updateButton)

plugin.Unloading:Connect(function()
	session:stop()
end)

updateButton()
print("[Sutz Syncer] Plugin loaded")
