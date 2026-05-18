--!nonstrict

local RunService = game:GetService("RunService")

if RunService:IsRunning() then
	return
end

local SyncSession = require(script.SyncSession)
local UI = require(script.UI)

local toolbar = plugin:CreateToolbar("Sutz Syncer")
local toggleButton = toolbar:CreateButton(
	"Sutz Sync",
	"Open Sutz Studio Syncer",
	""
)

toggleButton.ClickableWhenViewportHidden = true

local session = SyncSession.new()
local ui = UI.new(plugin, script, session)

toggleButton.Click:Connect(function()
	ui:toggle()
	toggleButton:SetActive(ui.widget.Enabled)
end)

ui.widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(ui.widget.Enabled)
end)

plugin.Unloading:Connect(function()
	ui:destroy()
end)

print("[Sutz Syncer] Plugin loaded")
