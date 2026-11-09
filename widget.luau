--!nonstrict
-- Bar Widget entry script for Tailscale & Mullvad Noctalia v5 plugin.
-- Reads the lightweight summary.json pre-computed by service.luau so UI callbacks
-- complete in < 0.1ms and never exceed Luau's CPU budget.

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

local function resolveGlyph(widgetKey: string, globalKey: string, fallback: string): string
    local wVal = tostring(noctalia.getConfig(widgetKey) or "")
    if wVal ~= "" then
        return wVal
    end
    local gVal = tostring(noctalia.getConfig(globalKey) or "")
    if gVal ~= "" then
        return gVal
    end
    return fallback
end

local function resolveText(widgetKey: string, globalKey: string): string
    local wVal = tostring(noctalia.getConfig(widgetKey) or "")
    if wVal ~= "" then
        return wVal
    end
    local gVal = tostring(noctalia.getConfig(globalKey) or "")
    if gVal ~= "" then
        return gVal
    end
    return ""
end

local function refreshWidget()
    local glyphExitActive = resolveGlyph("widget_glyph_exit_active", "glyph_exit_active", "shield-lock")
    local glyphConnected = resolveGlyph("widget_glyph_connected", "glyph_connected", "network")
    local glyphDisconnected = resolveGlyph("widget_glyph_disconnected", "glyph_disconnected", "shield-off")
    local glyphLogin = resolveGlyph("widget_glyph_login", "glyph_login", "alert-triangle")

    local customOn = resolveText("label_on", "text_exit_active")
    local customOff = resolveText("label_off", "text_connected")
    local widgetDown = tostring(noctalia.getConfig("label_down") or "")
    local globalDown = tostring(noctalia.getConfig("text_disconnected") or "")

    local raw = noctalia.readFile(summaryPath())
    if not raw or raw == "" then
        barWidget.setGlyph(glyphDisconnected)
        barWidget.setText("...")
        barWidget.setTooltip("Tailscale: Loading status...\nLeft-click: Open Panel")
        noctalia.runAsync({ "noctalia", "msg", "plugin", PLUGIN_ID .. ":service", "all", "refresh" })
        return
    end

    local sum = noctalia.json.decode(raw)
    if type(sum) ~= "table" then
        barWidget.setGlyph(glyphDisconnected)
        barWidget.setText("Offline")
        barWidget.setTooltip("Tailscale: Unable to read status\nLeft-click: Open Panel")
        return
    end

    local backendState = tostring(sum.backendState or "Unknown")
    local selfHost = tostring(sum.selfHost or "localhost")
    local selfIpv4 = tostring(sum.selfIpv4 or "No IP")
    local onlinePeers = tonumber(sum.onlinePeers) or 0
    local totalPeers = tonumber(sum.totalPeers) or 0
    local exitNodeCount = tonumber(sum.exitNodeCount) or 0
    local mullvadNodeCount = tonumber(sum.mullvadNodeCount) or 0
    local hasExit = sum.hasExit == true
    local exitShort = tostring(sum.activeExitShort or "")
    local exitFull = tostring(sum.activeExitFull or "None (Direct traffic)")

    local st = loadState()
    local quickTarget = tostring(st.quickConnectNode or "")
    if quickTarget == "" then
        quickTarget = tostring(noctalia.getConfig("default_quick_exit_node") or "")
    end
    local quickDisplay = tostring(st.quickConnectLabel or "")
    if quickDisplay == "" then
        quickDisplay = tostring(sum.resolvedQuickLabel or "")
    end
    if quickDisplay == "" then
        quickDisplay = quickTarget ~= "" and quickTarget or "Not set (select in panel)"
    end

    local displayMode = tostring(noctalia.getConfig("display_mode") or "exit_node")

    if backendState ~= "Running" then
        if backendState == "NeedsLogin" or backendState == "NeedsMachineAuth" then
            barWidget.setGlyph(glyphLogin)
            barWidget.setText((displayMode == "compact" or displayMode == "icon_only") and "" or "Login")
        else
            barWidget.setGlyph(glyphDisconnected)
            local downText = "Down"
            if displayMode == "compact" or displayMode == "icon_only" then
                downText = ""
            elseif widgetDown ~= "" then
                downText = widgetDown
            elseif displayMode == "custom" then
                if globalDown ~= "" and globalDown ~= "Down" then
                    downText = globalDown
                elseif customOff ~= "" then
                    downText = customOff
                else
                    downText = "VPN Off"
                end
            elseif globalDown ~= "" then
                downText = globalDown
            end
            barWidget.setText(downText)
        end
        barWidget.setTooltip(
            "Tailscale: " .. backendState
            .. "\nDevice: " .. selfHost
            .. "\nQuick Exit Node: " .. quickDisplay
            .. "\n\nLeft-click: Open Tailscale Panel"
            .. "\nRight-click: Quick Action"
        )
        return
    end

    if hasExit then
        barWidget.setGlyph(glyphExitActive)
    else
        barWidget.setGlyph(glyphConnected)
    end

    local activeLabel = (customOn ~= "") and customOn or exitShort
    local labelText = ""
    if displayMode == "icon_only" then
        labelText = ""
    elseif displayMode == "custom" then
        if hasExit then
            labelText = (customOn ~= "") and customOn or "VPN On"
        else
            labelText = (customOff ~= "") and customOff or "VPN Off"
        end
    elseif displayMode == "compact" then
        if hasExit then
            labelText = activeLabel
        else
            labelText = customOff
        end
    elseif displayMode == "ip" then
        local prefix = hasExit and activeLabel or customOff
        labelText = (prefix ~= "" and (prefix .. " · ") or "") .. selfIpv4
    elseif displayMode == "peers" then
        if hasExit and activeLabel ~= "" then
            labelText = activeLabel .. " (" .. tostring(onlinePeers) .. ")"
        elseif customOff ~= "" then
            labelText = customOff .. " (" .. tostring(onlinePeers) .. ")"
        else
            labelText = tostring(onlinePeers) .. "/" .. tostring(totalPeers) .. " peers"
        end
    elseif displayMode == "status" then
        if hasExit then
            labelText = (customOn ~= "") and customOn or ("Exit: " .. exitShort)
        else
            labelText = (customOff ~= "") and customOff or "Connected"
        end
    else
        if hasExit and activeLabel ~= "" then
            labelText = activeLabel
        elseif customOff ~= "" then
            labelText = customOff
        else
            labelText = selfIpv4
        end
    end

    barWidget.setText(labelText)

    local tooltipLines = {
        "Tailscale: Connected (" .. selfHost .. ")",
        "IPv4: " .. selfIpv4,
        "Exit Node: " .. exitFull,
        "Quick Connect Node: " .. quickDisplay,
        "Tailnet Devices: " .. tostring(onlinePeers) .. " online / " .. tostring(totalPeers) .. " total",
        "Available Exit Nodes: " .. tostring(exitNodeCount) .. (mullvadNodeCount > 0 and (" (" .. tostring(mullvadNodeCount) .. " Mullvad)") or ""),
        "",
        "Left-click: Open Tailscale & Mullvad Panel",
        "Right-click: Quick Connect / Custom Action",
    }
    barWidget.setTooltip(table.concat(tooltipLines, "\n"))
end

function update()
    local intervalSec = tonumber(noctalia.getConfig("refresh_interval")) or 5
    if intervalSec < 2 then
        intervalSec = 2
    end
    noctalia.setUpdateInterval(intervalSec * 1000)
    refreshWidget()
end

function onConfigChanged()
    refreshWidget()
end

function onClick()
    noctalia.togglePanel(PLUGIN_ID .. ":panel")
end

function onRightClick()
    local action = tostring(noctalia.getConfig("right_click_action") or "quick_exit")
    if action == "quick_exit" then
        noctalia.runAsync({ "noctalia", "msg", "plugin", PLUGIN_ID .. ":service", "all", "quick-connect" })
    elseif action == "toggle_tailscale" then
        noctalia.runAsync({ "noctalia", "msg", "plugin", PLUGIN_ID .. ":service", "all", "toggle-tailscale" })
    elseif action == "disconnect_exit" then
        noctalia.runAsync({ "noctalia", "msg", "plugin", PLUGIN_ID .. ":service", "all", "disconnect-exit" })
    elseif action == "open_settings" then
        noctalia.openSettings()
    else
        noctalia.runAsync({ "noctalia", "msg", "plugin", PLUGIN_ID .. ":service", "all", "quick-connect" })
    end
end

function onIpc(event: string, _payload: any)
    if event == "refresh" then
        refreshWidget()
    end
end
