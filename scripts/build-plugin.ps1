param(
    [string]$TemplatePath = "$env:LOCALAPPDATA\Roblox\Plugins\SutzStudioSyncerPlugin.rbxmx"
)

$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskOutput = Join-Path $taskRoot 'dist\SutzStudioSyncerPlugin.rbxmx'
$taskTemplate = (Resolve-Path -LiteralPath $TemplatePath).Path
$taskXml = New-Object System.Xml.XmlDocument
$taskXml.PreserveWhitespace = $true
$taskXml.Load($taskTemplate)
$taskPlugins = $taskXml.SelectNodes('//Item[@class="Script"][Properties/string[@name="Name"]="SutzStudioSyncerPlugin"]')
if ($taskPlugins.Count -ne 1) { throw 'Template must contain exactly one SutzStudioSyncerPlugin Script.' }
$taskPlugin = $taskPlugins[0]
$taskSources = @{}

foreach ($taskFile in Get-ChildItem -LiteralPath (Join-Path $taskRoot 'plugin\src') -Filter '*.luau') {
    $taskItem = if ($taskFile.Name -eq 'Main.server.luau') {
        $taskPlugin
    } else {
        $taskPlugin.SelectSingleNode('Item[@class="ModuleScript"][Properties/string[@name="Name"]="' + $taskFile.BaseName + '"]')
    }
    if ($null -eq $taskItem) { throw "Missing module in template: $($taskFile.Name)" }
    $taskSource = $taskItem.SelectSingleNode('Properties/*[@name="Source"]')
    if ($null -eq $taskSource) { throw "Missing Source property: $($taskFile.Name)" }
    $taskText = [IO.File]::ReadAllText($taskFile.FullName).Replace("`r`n", "`n")
    $taskSource.InnerText = $taskText
    $taskSources[$taskFile.Name] = $taskText
}

# Keep the template's Fusion library, images, attributes and other plugin assets.
[IO.Directory]::CreateDirectory((Split-Path -Parent $taskOutput)) | Out-Null
$taskSettings = New-Object System.Xml.XmlWriterSettings
$taskSettings.Encoding = New-Object System.Text.UTF8Encoding($false)
$taskSettings.Indent = $false
$taskSettings.NewLineHandling = [System.Xml.NewLineHandling]::None
$taskSettings.NewLineChars = "`n"
$taskWriter = [System.Xml.XmlWriter]::Create($taskOutput, $taskSettings)
try { $taskXml.Save($taskWriter) } finally { $taskWriter.Dispose() }

$taskVerified = New-Object System.Xml.XmlDocument
$taskVerified.Load($taskOutput)
$taskVerifiedPlugin = $taskVerified.SelectSingleNode('//Item[@class="Script"][Properties/string[@name="Name"]="SutzStudioSyncerPlugin"]')
foreach ($taskName in $taskSources.Keys) {
    $taskItem = if ($taskName -eq 'Main.server.luau') {
        $taskVerifiedPlugin
    } else {
        $taskVerifiedPlugin.SelectSingleNode('Item[@class="ModuleScript"][Properties/string[@name="Name"]="' + [IO.Path]::GetFileNameWithoutExtension($taskName) + '"]')
    }
    if ($taskItem.SelectSingleNode('Properties/*[@name="Source"]').InnerText -cne $taskSources[$taskName]) {
        throw "Packaged source verification failed: $taskName"
    }
}
Write-Output "Packaged and verified $($taskSources.Count) scripts: $taskOutput"
