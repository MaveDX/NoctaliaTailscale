--!nonstrict
-- Interactive Panel for Tailscale & Mullvad Noctalia v5 plugin.
-- Uses pre-digested summary.json and per-country caches from service.luau,
-- keeping decoded tables in memory so tab switches and UI interactions never
-- decode large JSON files or exceed Luau's CPU budget.

local PLUGIN_ID = "mave/tailscale"

local activeTab = "exit_nodes" -- "exit_nodes" | "devices"
local searchQuery = ""
local selectedCountry = "ALL"

local cachedState: { [string]: any } = {
    pinnedNodes = {},
    pinnedDevices = {},
    quickConnectNode = "",
    quickConnectLabel = "",
    allowLanAccess = true,
}

local cachedSummary: { [string]: any } = {
    backendState = "Unknown",
    running = false,
    selfHost = "localhost",
    selfIpv4 = "No IP",
    selfOs = "",
    onlinePeers = 0,
    totalPeers = 0,
    exitNodeCount = 0,
    mullvadNodeCount = 0,
    hasExit = false,
    activeExitNode = nil,
    activeExitTarget = "",
    activeExitShort = "",
    activeExitFull = "None (Direct traffic)",
    activeExitLabel = "",
    resolvedQuickLabel = "",
    personalExitNodes = {},
    pinnedExitNodes = {},
    devices = {},
    countries = {},
    mullvadDefault = {},
    mullvadDefaultTotal = 0,
}

local countryCache: { [string]: { total: number, nodes: { any } } } = {}
local searchCache: { query: string, country: string, total: number, nodes: { any } }? = nil

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

local function countryPath(cc: string): string
    return dataDir() .. "/country_" .. cc .. ".json"
end

local function searchResultsPath(): string
    return dataDir() .. "/search_results.json"
end

local function sendServiceMsg(event: string, payload: string?)
    local cmd = { "noctalia", "msg", "plugin", PLUGIN_ID .. ":service", "all", event }
    if payload and payload ~= "" then
        table.insert(cmd, payload)
    end
    noctalia.runAsync(cmd)
end

local function copyToClipboard(text: string, label: string)
    if text == "" then
        return
    end
    noctalia.runAsync({ "wl-copy", text }, function(res)
        if res.exitCode == 0 then
            noctalia.notify("Tailscale", "Copied " .. label .. ": " .. text)
        end
    end)
end

local function reloadFromDisk()
    local rawState = noctalia.readFile(statePath())
    if rawState and rawState ~= "" then
        local decoded = noctalia.json.decode(rawState)
        if type(decoded) == "table" then
            decoded.pinnedNodes = type(decoded.pinnedNodes) == "table" and decoded.pinnedNodes or {}
            decoded.pinnedDevices = type(decoded.pinnedDevices) == "table" and decoded.pinnedDevices or {}
            decoded.quickConnectNode = type(decoded.quickConnectNode) == "string" and decoded.quickConnectNode or ""
            decoded.quickConnectLabel = type(decoded.quickConnectLabel) == "string" and decoded.quickConnectLabel or ""
            cachedState = decoded
        end
    end

    local rawSum = noctalia.readFile(summaryPath())
    if rawSum and rawSum ~= "" then
        local decoded = noctalia.json.decode(rawSum)
        if type(decoded) == "table" then
            decoded.personalExitNodes = type(decoded.personalExitNodes) == "table" and decoded.personalExitNodes or {}
            decoded.pinnedExitNodes = type(decoded.pinnedExitNodes) == "table" and decoded.pinnedExitNodes or {}
            decoded.devices = type(decoded.devices) == "table" and decoded.devices or {}
            decoded.countries = type(decoded.countries) == "table" and decoded.countries or {}
            decoded.mullvadDefault = type(decoded.mullvadDefault) == "table" and decoded.mullvadDefault or {}
            cachedSummary = decoded
        end
    else
        sendServiceMsg("refresh")
    end

    countryCache = {}
    if selectedCountry ~= "ALL" then
        local rawCountry = noctalia.readFile(countryPath(selectedCountry))
        if rawCountry and rawCountry ~= "" then
            local decoded = noctalia.json.decode(rawCountry)
            if type(decoded) == "table" and type(decoded.nodes) == "table" then
                countryCache[selectedCountry] = decoded
            end
        end
    end
end

local function loadCountryIfNeeded(cc: string)
    if cc == "ALL" or countryCache[cc] then
        return
    end
    local raw = noctalia.readFile(countryPath(cc))
    if raw and raw ~= "" then
        local decoded = noctalia.json.decode(raw)
        if type(decoded) == "table" and type(decoded.nodes) == "table" then
            countryCache[cc] = decoded
        end
    end
end

local function sectionLabel(text: string)
    return ui.label({
        text = text,
        fontSize = 11,
        fontWeight = "medium",
        color = "on_surface_variant",
    })
end

local function emptyLabel(text: string)
    return ui.label({
        text = text,
        fontSize = 12,
        color = "on_surface_variant",
    })
end

local function matchesSmallListQuery(node: { [string]: any }, q: string): boolean
    if q == "" then
        return true
    end
    local needle = q:lower()
    return tostring(node.title or ""):lower():find(needle, 1, true) ~= nil
        or tostring(node.host or ""):lower():find(needle, 1, true) ~= nil
        or tostring(node.ipv4 or ""):lower():find(needle, 1, true) ~= nil
        or tostring(node.os or ""):lower():find(needle, 1, true) ~= nil
end

local function buildExitNodeRow(node: { [string]: any }, keyPrefix: string)
    local target = tostring(node.target or "")
    local isPinned = cachedState.pinnedNodes[target] == true
    local quickNode = tostring(cachedState.quickConnectNode or "")
    local isQuick = quickNode ~= "" and (quickNode == target)
    local isActive = (node.isActiveExit == true) or (cachedSummary.activeExitTarget == target and target ~= "")

    local statusGlyph = "server"
    if isActive then
        statusGlyph = "shield-lock"
    elseif node.isMullvad then
        statusGlyph = "world"
    end

    return ui.row({ key = keyPrefix .. "-" .. target, gap = 8, align = "center" }, {
        ui.glyph({
            name = statusGlyph,
            size = 16,
            color = if isActive then "primary" elseif node.online then "on_surface" else "on_surface_variant",
        }),
        ui.column({ gap = 1, flexGrow = 1 }, {
            ui.label({
                text = tostring(node.title or target) .. (not node.online and " (offline)" or ""),
                fontSize = 13,
                fontWeight = isActive and "bold" or "normal",
                maxLines = 1,
            }),
            ui.label({
                text = tostring(node.subtitle or ""),
                fontSize = 11,
                color = "on_surface_variant",
                maxLines = 1,
            }),
        }),
        ui.button({
            key = keyPrefix .. "-quick-" .. target,
            glyph = "bolt",
            variant = isQuick and "secondary" or "ghost",
            controlSize = "sm",
            tooltip = isQuick and "Current Quick Connect exit node" or "Set as Quick Connect exit node",
            onClick = function()
                cachedState.quickConnectNode = target
                cachedState.quickConnectLabel = tostring(node.friendlyLabel or node.title or target)
                render()
                sendServiceMsg("set-quick-node", target)
            end,
        }),
        ui.button({
            key = keyPrefix .. "-pin-" .. target,
            glyph = isPinned and "pinned" or "pin",
            variant = isPinned and "secondary" or "ghost",
            controlSize = "sm",
            tooltip = isPinned and "Unpin exit node" or "Pin exit node",
            onClick = function()
                if cachedState.pinnedNodes[target] then
                    cachedState.pinnedNodes[target] = nil
                else
                    cachedState.pinnedNodes[target] = true
                end
                render()
                sendServiceMsg("pin-node", target)
            end,
        }),
        ui.button({
            key = keyPrefix .. "-connect-" .. target,
            text = isActive and "Disconnect" or "Connect",
            variant = isActive and "destructive" or "outline",
            controlSize = "sm",
            onClick = function()
                if isActive then
                    sendServiceMsg("disconnect-exit")
                else
                    sendServiceMsg("connect-exit", target)
                end
            end,
        }),
    })
end

local function buildDeviceRow(node: { [string]: any })
    local target = tostring(node.target or "")
    local host = tostring(node.host or target)
    local ipv4 = tostring(node.ipv4 or "")
    local osName = tostring(node.os or "")
    local online = node.online == true
    local isPinned = cachedState.pinnedDevices[target] == true

    local metaParts = {}
    if ipv4 ~= "" then
        table.insert(metaParts, ipv4)
    end
    if osName ~= "" then
        table.insert(metaParts, osName)
    end
    table.insert(metaParts, online and "Online" or "Offline")

    local rowChildren = {
        ui.glyph({
            name = online and "device-desktop" or "device-desktop-off",
            size = 16,
            color = online and "on_surface" or "on_surface_variant",
        }),
        ui.column({ gap = 1, flexGrow = 1 }, {
            ui.label({
                text = host,
                fontSize = 13,
                fontWeight = online and "medium" or "normal",
                maxLines = 1,
            }),
            ui.label({
                text = table.concat(metaParts, " · "),
                fontSize = 11,
                color = "on_surface_variant",
                maxLines = 1,
            }),
        }),
    }

    if node.isExitCapable then
        local isActive = (node.isActiveExit == true) or (cachedSummary.activeExitTarget == target and target ~= "")
        table.insert(
            rowChildren,
            ui.button({
                key = "dev-exit-" .. target,
                glyph = "shield-lock",
                variant = isActive and "primary" or "ghost",
                controlSize = "sm",
                tooltip = isActive and "Disconnect exit node" or "Use as exit node",
                onClick = function()
                    if isActive then
                        sendServiceMsg("disconnect-exit")
                    else
                        sendServiceMsg("connect-exit", target)
                    end
                end,
            })
        )
    end

    if ipv4 ~= "" then
        table.insert(
            rowChildren,
            ui.button({
                key = "dev-copy-" .. target,
                glyph = "copy",
                variant = "ghost",
                controlSize = "sm",
                tooltip = "Copy IP (" .. ipv4 .. ")",
                onClick = function()
                    copyToClipboard(ipv4, host)
                end,
            })
        )
    end

    table.insert(
        rowChildren,
        ui.button({
            key = "dev-pin-" .. target,
            glyph = isPinned and "pinned" or "pin",
            variant = isPinned and "secondary" or "ghost",
            controlSize = "sm",
            tooltip = isPinned and "Unpin device" or "Pin device",
            onClick = function()
                if cachedState.pinnedDevices[target] then
                    cachedState.pinnedDevices[target] = nil
                else
                    cachedState.pinnedDevices[target] = true
                end
                render()
                sendServiceMsg("pin-device", target)
            end,
        })
    )

    return ui.row({ key = "dev-" .. target, gap = 8, align = "center" }, rowChildren)
end

local function buildExitNodesContent()
    local showMullvad = noctalia.getConfig("show_mullvad_nodes")
    if showMullvad == nil then
        showMullvad = true
    end

    local sections = {}

    -- 1. Pinned Exit Nodes
    local pinnedRows = {}
    for _, node in ipairs(cachedSummary.pinnedExitNodes) do
        if cachedState.pinnedNodes[node.target] == true and matchesSmallListQuery(node, searchQuery) then
            table.insert(pinnedRows, buildExitNodeRow(node, "pinned"))
        end
    end

    if #pinnedRows > 0 then
        local block = { sectionLabel("PINNED EXIT NODES (" .. tostring(#pinnedRows) .. ")") }
        for _, r in ipairs(pinnedRows) do
            table.insert(block, r)
        end
        table.insert(sections, ui.column({ gap = 6 }, block))
        table.insert(sections, ui.separator({}))
    end

    -- 2. Personal Tailnet Exit Nodes
    local personalRows = {}
    for _, node in ipairs(cachedSummary.personalExitNodes) do
        if matchesSmallListQuery(node, searchQuery) then
            table.insert(personalRows, buildExitNodeRow(node, "personal"))
        end
    end

    local personalBlock = { sectionLabel("TAILNET EXIT NODES (" .. tostring(#personalRows) .. ")") }
    if #personalRows == 0 then
        table.insert(personalBlock, emptyLabel("No personal exit nodes advertised on this tailnet."))
    else
        for _, r in ipairs(personalRows) do
            table.insert(personalBlock, r)
        end
    end
    table.insert(sections, ui.column({ gap = 6 }, personalBlock))

    -- 3. Mullvad Exit Nodes
    local mullvadTotal = tonumber(cachedSummary.mullvadNodeCount) or 0
    if showMullvad and mullvadTotal > 0 then
        table.insert(sections, ui.separator({}))

        local countryButtons = {
            ui.button({
                key = "cc-ALL",
                text = "Featured",
                variant = selectedCountry == "ALL" and "primary" or "outline",
                controlSize = "sm",
                tooltip = "One node per city across Mullvad locations",
                onClick = function()
                    selectedCountry = "ALL"
                    if searchQuery ~= "" then
                        sendServiceMsg("search-mullvad", "ALL|" .. searchQuery)
                    end
                    render()
                end,
            }),
        }

        for _, c in ipairs(cachedSummary.countries) do
            local code = tostring(c.code or "")
            local count = tonumber(c.count) or 0
            table.insert(
                countryButtons,
                ui.button({
                    key = "cc-" .. code,
                    text = code .. " (" .. tostring(count) .. ")",
                    variant = selectedCountry == code and "primary" or "outline",
                    controlSize = "sm",
                    tooltip = tostring(c.name or code),
                    onClick = function()
                        selectedCountry = code
                        loadCountryIfNeeded(code)
                        if searchQuery ~= "" then
                            sendServiceMsg("search-mullvad", code .. "|" .. searchQuery)
                        end
                        render()
                    end,
                })
            )
        end

        local nodesToDisplay = {}
        local totalMatching = 0

        if searchQuery ~= "" then
            if searchCache and searchCache.query == searchQuery:lower() and searchCache.country == selectedCountry then
                nodesToDisplay = searchCache.nodes
                totalMatching = searchCache.total
            else
                nodesToDisplay = {}
                totalMatching = 0
            end
        elseif selectedCountry == "ALL" then
            nodesToDisplay = cachedSummary.mullvadDefault
            totalMatching = mullvadTotal
        else
            local cData = countryCache[selectedCountry]
            if cData then
                nodesToDisplay = cData.nodes
                totalMatching = cData.total
            end
        end

        local headerTitle = "MULLVAD EXIT NODES ("
            .. (selectedCountry == "ALL" and searchQuery == ""
                and ("FEATURED CITIES · " .. tostring(mullvadTotal) .. " TOTAL")
                or (tostring(#nodesToDisplay) .. " SHOWN / " .. tostring(totalMatching) .. " MATCHING"))
            .. ")"

        local mullvadBlock = {
            sectionLabel(headerTitle),
            ui.scroll({ gap = 4 }, {
                ui.row({ gap = 4 }, countryButtons),
            }),
        }

        if #nodesToDisplay == 0 then
            if searchQuery ~= "" and (not searchCache or searchCache.query ~= searchQuery:lower()) then
                table.insert(mullvadBlock, emptyLabel("Searching Mullvad nodes..."))
            else
                table.insert(mullvadBlock, emptyLabel("No Mullvad exit nodes match the current filter."))
            end
        else
            local limit = math.min(#nodesToDisplay, 25)
            for i = 1, limit do
                table.insert(mullvadBlock, buildExitNodeRow(nodesToDisplay[i], "mullvad"))
            end
            if totalMatching > limit then
                table.insert(
                    mullvadBlock,
                    emptyLabel("Select a country above or use search to browse specific relays.")
                )
            end
        end

        table.insert(sections, ui.column({ gap = 6 }, mullvadBlock))
    end

    return ui.column({ gap = 10 }, sections)
end

local function buildDevicesContent()
    local pinnedRows = {}
    local otherRows = {}

    for _, dev in ipairs(cachedSummary.devices) do
        if matchesSmallListQuery(dev, searchQuery) then
            if cachedState.pinnedDevices[dev.target] == true then
                table.insert(pinnedRows, buildDeviceRow(dev))
            else
                table.insert(otherRows, buildDeviceRow(dev))
            end
        end
    end

    local sections = {}
    if #pinnedRows > 0 then
        local pinBlock = { sectionLabel("PINNED DEVICES (" .. tostring(#pinnedRows) .. ")") }
        for _, r in ipairs(pinnedRows) do
            table.insert(pinBlock, r)
        end
        table.insert(sections, ui.column({ gap = 6 }, pinBlock))
        table.insert(sections, ui.separator({}))
    end

    local devBlock = {
        sectionLabel(
            "TAILNET DEVICES ("
            .. tostring(cachedSummary.onlinePeers or 0)
            .. " ONLINE / "
            .. tostring(cachedSummary.totalPeers or 0)
            .. " TOTAL)"
        ),
    }
    if #otherRows == 0 and #pinnedRows == 0 then
        table.insert(devBlock, emptyLabel("No connected devices match the search query."))
    else
        for _, r in ipairs(otherRows) do
            table.insert(devBlock, r)
        end
    end
    table.insert(sections, ui.column({ gap = 6 }, devBlock))

    return ui.column({ gap = 10 }, sections)
end

function render()
    local running = cachedSummary.running == true
    local hasExit = cachedSummary.hasExit == true
    local selfHost = tostring(cachedSummary.selfHost or "localhost")
    local selfIpv4 = tostring(cachedSummary.selfIpv4 or "No IP")
    local backendState = tostring(cachedSummary.backendState or "Unknown")

    local quickNode = tostring(cachedState.quickConnectNode or "")
    if quickNode == "" then
        quickNode = tostring(noctalia.getConfig("default_quick_exit_node") or "")
    end
    local quickLabel = tostring(cachedState.quickConnectLabel or "")
    if quickLabel == "" then
        quickLabel = tostring(cachedSummary.resolvedQuickLabel or "")
    end
    if quickLabel == "" then
        quickLabel = quickNode ~= "" and quickNode or "None (click bolt on a node)"
    end

    local allowLan = cachedState.allowLanAccess
    if allowLan == nil then
        local cfgLan = noctalia.getConfig("allow_lan_access")
        allowLan = (cfgLan == nil) or (cfgLan == true)
    end

    local activeExitTitle = hasExit
        and tostring(cachedSummary.activeExitFull or cachedSummary.activeExitShort or "Active")
        or "Direct traffic (No exit node)"

    local glyphExitActive = tostring(noctalia.getConfig("glyph_exit_active") or "shield-lock")
    if glyphExitActive == "" then glyphExitActive = "shield-lock" end
    local glyphConnected = tostring(noctalia.getConfig("glyph_connected") or "network")
    if glyphConnected == "" then glyphConnected = "network" end
    local glyphDisconnected = tostring(noctalia.getConfig("glyph_disconnected") or "shield-off")
    if glyphDisconnected == "" then glyphDisconnected = "shield-off" end
    local glyphLogin = tostring(noctalia.getConfig("glyph_login") or "alert-triangle")
    if glyphLogin == "" then glyphLogin = "alert-triangle" end

    local headerGlyph = glyphConnected
    if not running then
        if backendState == "NeedsLogin" or backendState == "NeedsMachineAuth" then
            headerGlyph = glyphLogin
        else
            headerGlyph = glyphDisconnected
        end
    elseif hasExit then
        headerGlyph = glyphExitActive
    end

    local header = ui.row({ gap = 6, align = "center" }, {
        ui.glyph({
            name = headerGlyph,
            size = 18,
            color = running and "primary" or "on_surface_variant",
        }),
        ui.column({ gap = 1, flexGrow = 1 }, {
            ui.label({
                text = "Tailscale & Mullvad",
                fontSize = 15,
                fontWeight = "bold",
                maxLines = 1,
            }),
            ui.label({
                text = running and (selfHost .. " · " .. selfIpv4) or ("Status: " .. backendState),
                fontSize = 11,
                color = "on_surface_variant",
                maxLines = 1,
            }),
        }),
        ui.button({
            key = "copy-self-ip",
            glyph = "copy",
            variant = "ghost",
            controlSize = "sm",
            enabled = running and selfIpv4 ~= "No IP",
            tooltip = "Copy this device's Tailscale IP (" .. selfIpv4 .. ")",
            onClick = function()
                copyToClipboard(selfIpv4, selfHost)
            end,
        }),
        ui.button({
            key = "toggle-ts",
            text = running and "Stop" or "Start",
            variant = running and "outline" or "primary",
            controlSize = "sm",
            onClick = function()
                sendServiceMsg("toggle-tailscale")
            end,
        }),
        ui.button({
            key = "refresh-btn",
            glyph = "refresh",
            variant = "ghost",
            controlSize = "sm",
            tooltip = "Refresh Tailscale status",
            onClick = function()
                sendServiceMsg("refresh")
            end,
        }),
        ui.button({
            key = "settings-btn",
            glyph = "settings",
            variant = "ghost",
            controlSize = "sm",
            tooltip = "Plugin Settings",
            onClick = function()
                noctalia.openSettings()
            end,
        }),
        ui.button({
            key = "close-btn",
            glyph = "x",
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
                panel.close()
            end,
        }),
    })

    local summaryActions = {
        ui.button({
            key = "quick-connect-btn",
            glyph = "bolt",
            text = "Quick: " .. quickLabel,
            variant = hasExit and "secondary" or "outline",
            controlSize = "sm",
            flexGrow = 1,
            tooltip = "Toggle Quick Connect Exit Node",
            onClick = function()
                sendServiceMsg("quick-connect")
            end,
        }),
        ui.button({
            key = "lan-toggle-btn",
            glyph = allowLan and "home" or "home-off",
            text = allowLan and "LAN: On" or "LAN: Off",
            variant = allowLan and "secondary" or "outline",
            controlSize = "sm",
            tooltip = "Allow local network access while connected to an exit node",
            onClick = function()
                cachedState.allowLanAccess = not allowLan
                render()
                sendServiceMsg("toggle-lan")
            end,
        }),
    }

    if hasExit then
        table.insert(
            summaryActions,
            ui.button({
                key = "disconnect-active-exit",
                glyph = "plug-connected-x",
                text = "Disconnect",
                variant = "destructive",
                controlSize = "sm",
                tooltip = "Disconnect active exit node",
                onClick = function()
                    sendServiceMsg("disconnect-exit")
                end,
            })
        )
    end

    local statusSummary = ui.column({ gap = 6 }, {
        ui.row({ gap = 6, align = "center" }, {
            ui.glyph({
                name = hasExit and "shield-lock" or "arrows-left-right",
                size = 15,
                color = hasExit and "primary" or "on_surface_variant",
            }),
            ui.label({
                text = "Exit Node: " .. activeExitTitle,
                fontSize = 12,
                fontWeight = hasExit and "bold" or "normal",
                maxLines = 1,
                flexGrow = 1,
            }),
        }),
        ui.row({ gap = 6, align = "center" }, summaryActions),
    })

    local totalExitCount = tonumber(cachedSummary.exitNodeCount) or 0
    local totalDeviceCount = tonumber(cachedSummary.totalPeers) or 0

    local tabsAndSearch = ui.column({ gap = 6 }, {
        ui.row({ gap = 6 }, {
            ui.button({
                key = "tab-exit-nodes",
                glyph = "shield-lock",
                text = "Exit Nodes (" .. tostring(totalExitCount) .. ")",
                variant = activeTab == "exit_nodes" and "primary" or "outline",
                controlSize = "sm",
                flexGrow = 1,
                onClick = function()
                    activeTab = "exit_nodes"
                    render()
                end,
            }),
            ui.button({
                key = "tab-devices",
                glyph = "devices",
                text = "Devices (" .. tostring(totalDeviceCount) .. ")",
                variant = activeTab == "devices" and "primary" or "outline",
                controlSize = "sm",
                flexGrow = 1,
                onClick = function()
                    activeTab = "devices"
                    render()
                end,
            }),
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                key = "tailscale-search-input",
                value = searchQuery,
                placeholder = activeTab == "exit_nodes"
                    and "Search exit nodes by city, country, hostname, or IP..."
                    or "Search devices by hostname, IP, or OS...",
                flexGrow = 1,
                onChange = function(val: string)
                    searchQuery = tostring(val or "")
                    if activeTab == "exit_nodes" and searchQuery ~= "" then
                        sendServiceMsg("search-mullvad", selectedCountry .. "|" .. searchQuery)
                    end
                    render()
                end,
            }),
            if searchQuery ~= ""
                then ui.button({
                    key = "clear-search-btn",
                    glyph = "x",
                    variant = "ghost",
                    controlSize = "sm",
                    tooltip = "Clear search",
                    onClick = function()
                        searchQuery = ""
                        searchCache = nil
                        render()
                    end,
                })
                else ui.spacer({}),
        }),
    })

    local bodyContent = if activeTab == "exit_nodes"
        then buildExitNodesContent()
        else buildDevicesContent()

    panel.render(
        ui.column({ flexGrow = 1, gap = 10, padding = 12 }, {
            header,
            ui.separator({}),
            statusSummary,
            ui.separator({}),
            tabsAndSearch,
            ui.scroll({ flexGrow = 1, gap = 10 }, {
                bodyContent,
            }),
        })
    )
end

function onOpen(_context: any)
    reloadFromDisk()
    render()
end

function update()
    local intervalSec = tonumber(noctalia.getConfig("refresh_interval")) or 5
    if intervalSec < 2 then
        intervalSec = 2
    end
    noctalia.setUpdateInterval(intervalSec * 1000)
    reloadFromDisk()
    render()
end

function onConfigChanged()
    render()
end

function onIpc(event: string, _payload: any)
    if event == "refresh" then
        reloadFromDisk()
        render()
    elseif event == "search-ready" then
        local raw = noctalia.readFile(searchResultsPath())
        if raw and raw ~= "" then
            local decoded = noctalia.json.decode(raw)
            if type(decoded) == "table" and type(decoded.nodes) == "table" then
                searchCache = decoded
            end
        end
        render()
    end
end
