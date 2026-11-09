--!nonstrict
-- Control Center Shortcut for toggling Tailscale Up/Down and opening the panel.
-- Reads lightweight summary.json pre-computed by service.luau.

local PLUGIN_ID = "mave/tailscale"

local function dataDir(): string
    local dir = noctalia.pluginDataDir()
    if not dir or dir == "" then
        return "/tmp"
    end
    return dir
end

local function summaryPath(): string
    return dataDir() .. "/summary.json"
end

local function refreshShortcut()
    local glyphExitActive = tostring(noctalia.getConfig("glyph_exit_active") or "shield-lock")
    if glyphExitActive == "" then glyphExitActive = "shield-lock" end
    local glyphConnected = tostring(noctalia.getConfig("glyph_connected") or "network")
    if glyphConnected == "" then glyphConnected = "network" end
    local glyphDisconnected = tostring(noctalia.getConfig("glyph_disconnected") or "shield-off")
    if glyphDisconnected == "" then glyphDisconnected = "shield-off" end

    local customOn = tostring(noctalia.getConfig("text_exit_active") or "")
    local customOff = tostring(noctalia.getConfig("text_connected") or "")
    local customDown = tostring(noctalia.getConfig("text_disconnected") or "")

    local raw = noctalia.readFile(summaryPath())
    if not raw or raw == "" then
        shortcut.setGlyph(glyphDisconnected)
        shortcut.setLabel("Tailscale")
        shortcut.setActive(false)
        return
    end

    local sum = noctalia.json.decode(raw)
    if type(sum) ~= "table" then
        shortcut.setGlyph(glyphDisconnected)
        shortcut.setLabel("Tailscale")
        shortcut.setActive(false)
        return
    end

    local running = (sum.running == true)
    local hasExit = (sum.hasExit == true)
    local exitName = tostring(sum.activeExitShort or "")

    if running then
        shortcut.setActive(true)
        if hasExit and exitName ~= "" then
            shortcut.setGlyph(glyphExitActive)
            shortcut.setLabel(customOn ~= "" and customOn or ("Tailscale · " .. exitName))
        else
            shortcut.setGlyph(glyphConnected)
            shortcut.setLabel(customOff ~= "" and customOff or "Tailscale")
        end
    else
        shortcut.setActive(false)
        shortcut.setGlyph(glyphDisconnected)
        shortcut.setLabel((customDown ~= "" and customDown ~= "Down") and customDown or "Tailscale Off")
    end
end

function update()
    local intervalSec = tonumber(noctalia.getConfig("refresh_interval")) or 5
    if intervalSec < 2 then
        intervalSec = 2
    end
    noctalia.setUpdateInterval(intervalSec * 1000)
    refreshShortcut()
end

function onClick()
    noctalia.runAsync({ "noctalia", "msg", "plugin", PLUGIN_ID .. ":service", "all", "toggle-tailscale" })
end

function onRightClick()
    noctalia.togglePanel(PLUGIN_ID .. ":panel")
end

function onIpc(event: string, _payload: any)
    if event == "refresh" then
        refreshShortcut()
    end
end
