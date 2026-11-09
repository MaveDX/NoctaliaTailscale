--!nonstrict
-- Control Center Shortcut for one-click Quick Connect to the pre-selected Exit Node.
-- Reads lightweight summary.json pre-computed by service.luau.

local PLUGIN_ID = "mave/tailscale"

local function dataDir(): string
    local dir = noctalia.pluginDataDir()
    if not dir or dir == "" then
        return "/tmp"
    end
    return dir
end

local function statePath(): string
    return dataDir() .. "/state.json"
end

local function summaryPath(): string
    return dataDir() .. "/summary.json"
end

local function loadState(): { [string]: any }
    local raw = noctalia.readFile(statePath())
    if raw and raw ~= "" then
        local decoded = noctalia.json.decode(raw)
        if type(decoded) == "table" then
            return decoded
        end
    end
    return {
        quickConnectNode = tostring(noctalia.getConfig("default_quick_exit_node") or ""),
        quickConnectLabel = "",
    }
end

local function refreshShortcut()
    local glyphExitActive = tostring(noctalia.getConfig("glyph_exit_active") or "shield-lock")
    if glyphExitActive == "" then glyphExitActive = "shield-lock" end
    local customOn = tostring(noctalia.getConfig("text_exit_active") or "")
    local customOff = tostring(noctalia.getConfig("text_connected") or "")

    local st = loadState()
    local quickNode = tostring(st.quickConnectNode or "")
    if quickNode == "" then
        quickNode = tostring(noctalia.getConfig("default_quick_exit_node") or "")
    end
    local quickLabel = tostring(st.quickConnectLabel or "")

    local raw = noctalia.readFile(summaryPath())
    local sum = (raw and raw ~= "") and noctalia.json.decode(raw) or nil

    if quickLabel == "" and type(sum) == "table" and sum.resolvedQuickLabel and sum.resolvedQuickLabel ~= "" then
        quickLabel = tostring(sum.resolvedQuickLabel)
    end
    if quickLabel == "" then
        quickLabel = quickNode ~= "" and quickNode:gsub("%.mullvad%.ts%.net$", "") or "Set Exit Node"
    end

    if type(sum) ~= "table" or sum.running ~= true then
        shortcut.setGlyph("bolt")
        shortcut.setLabel(customOff ~= "" and customOff or ("Exit: " .. quickLabel))
        shortcut.setActive(false)
        return
    end

    if sum.hasExit == true then
        local activeExitLabel = tostring(sum.activeExitLabel or sum.activeExitShort or "Active")
        shortcut.setActive(true)
        shortcut.setGlyph(glyphExitActive)
        shortcut.setLabel(customOn ~= "" and customOn or ("Exit: " .. activeExitLabel))
    else
        shortcut.setActive(false)
        shortcut.setGlyph("bolt")
        shortcut.setLabel(customOff ~= "" and customOff or ("Quick: " .. quickLabel))
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
    noctalia.runAsync({ "noctalia", "msg", "plugin", PLUGIN_ID .. ":service", "all", "quick-connect" })
end

function onRightClick()
    noctalia.togglePanel(PLUGIN_ID .. ":panel")
end

function onIpc(event: string, _payload: any)
    if event == "refresh" then
        refreshShortcut()
    end
end
