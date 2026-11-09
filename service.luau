--!nonstrict
-- Background singleton service for Tailscale & Mullvad Noctalia v5 plugin.
-- Polls `tailscale status --json` via Python to pre-digest large Mullvad peer lists
-- into small JSON caches inside pluginDataDir() so Luau UI callbacks never exceed CPU budgets.

local PLUGIN_ID = "mave/tailscale"
local isPolling = false

local PY_POLL_SCRIPT = [[
import json, os, subprocess, sys

data_dir = sys.argv[1]
max_visible = int(sys.argv[2]) if len(sys.argv) > 2 else 40
os.makedirs(data_dir, exist_ok=True)

state_path = os.path.join(data_dir, "state.json")
state = {}
if os.path.exists(state_path):
    try:
        with open(state_path, "r", encoding="utf-8") as f:
            state = json.load(f)
    except Exception:
        state = {}

pinned_nodes = state.get("pinnedNodes") if isinstance(state.get("pinnedNodes"), dict) else {}
quick_node = str(state.get("quickConnectNode") or "").strip().rstrip(".").lower()

try:
    proc = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=8)
    raw = proc.stdout if proc.returncode == 0 else ""
except Exception:
    raw = ""

if not raw:
    sys.exit(1)

try:
    data = json.loads(raw)
except Exception:
    sys.exit(1)

def strip_dot(s):
    return s[:-1] if isinstance(s, str) and s.endswith(".") else (s or "")

backend_state = str(data.get("BackendState") or "Unknown")
running = (backend_state == "Running")
self_node = data.get("Self") if isinstance(data.get("Self"), dict) else {}
self_host = str(self_node.get("HostName") or "localhost")
self_os = str(self_node.get("OS") or "")
self_ips = self_node.get("TailscaleIPs") if isinstance(self_node.get("TailscaleIPs"), list) else []
self_ipv4 = str(self_ips[0]) if self_ips else "No IP"

exit_status_id = None
if isinstance(data.get("ExitNodeStatus"), dict) and data["ExitNodeStatus"].get("ID"):
    exit_status_id = data["ExitNodeStatus"]["ID"]
elif isinstance(self_node.get("ExitNodeStatus"), dict) and self_node["ExitNodeStatus"].get("ID"):
    exit_status_id = self_node["ExitNodeStatus"]["ID"]

online_peers = 0
total_peers = 0
exit_node_count = 0
mullvad_node_count = 0

active_exit_node = None
personal_exit_nodes = []
pinned_exit_nodes = []
devices = []
mullvad_by_country = {}
country_names = {}
mullvad_all = []
resolved_quick_label = ""
label_map = {}

peers = data.get("Peer") if isinstance(data.get("Peer"), dict) else {}
for _, peer in peers.items():
    if not isinstance(peer, dict):
        continue
    dns = strip_dot(peer.get("DNSName"))
    host = str(peer.get("HostName") or dns or "peer")
    ips = peer.get("TailscaleIPs") if isinstance(peer.get("TailscaleIPs"), list) else []
    ipv4 = str(ips[0]) if ips else ""
    target = dns or ipv4 or host
    is_mullvad = "mullvad.ts.net" in dns.lower()
    is_exit_capable = bool(peer.get("ExitNodeOption")) or bool(peer.get("ExitNode"))
    is_active_exit = bool(peer.get("ExitNode")) or (exit_status_id is not None and peer.get("ID") == exit_status_id)
    online = bool(peer.get("Online"))
    os_name = str(peer.get("OS") or "")

    loc = peer.get("Location") if isinstance(peer.get("Location"), dict) else None
    country = str(loc.get("Country") or "") if loc else ""
    cc = str(loc.get("CountryCode") or "").upper() if loc else ""
    city = str(loc.get("City") or "") if loc else ""
    city_code = str(loc.get("CityCode") or "") if loc else ""

    if loc and city:
        title = f"{city}, {country}" if country else (f"{city} ({cc})" if cc else city)
        subtitle = f"{host} · {ipv4}" if ipv4 else host
        short_label = f"{cc}-{city_code}" if (cc and city_code) else (f"{cc} · {city}" if cc else host)
        friendly_label = f"{city} ({cc})" if cc else city
        full_label = f"{'Mullvad: ' if is_mullvad else ''}{city}, {country or cc} ({host})"
    else:
        title = host
        subtitle = f"{ipv4} · {dns}" if (dns and ipv4) else (ipv4 or dns)
        short_label = host
        friendly_label = host
        full_label = f"{host} ({dns})" if dns else host

    label_map[target.lower()] = friendly_label
    if dns:
        label_map[dns.lower()] = friendly_label
    if host:
        label_map[host.lower()] = friendly_label
    if ipv4:
        label_map[ipv4.lower()] = friendly_label

    if quick_node and quick_node in (target.lower(), dns.lower(), host.lower(), ipv4.lower()):
        resolved_quick_label = friendly_label

    entry = {
        "target": target,
        "host": host,
        "dns": dns,
        "ipv4": ipv4,
        "os": os_name,
        "online": online,
        "isMullvad": is_mullvad,
        "isExitCapable": is_exit_capable,
        "isActiveExit": is_active_exit,
        "country": country,
        "countryCode": cc or "OTHER",
        "city": city,
        "cityCode": city_code,
        "title": title,
        "subtitle": subtitle,
        "shortLabel": short_label,
        "friendlyLabel": friendly_label,
        "fullLabel": full_label,
    }

    if is_active_exit:
        active_exit_node = entry

    if is_exit_capable:
        exit_node_count += 1
        if pinned_nodes.get(target) is True:
            pinned_exit_nodes.append(entry)
        if is_mullvad:
            mullvad_node_count += 1
            c_key = cc or "OTHER"
            country_names[c_key] = country or c_key
            mullvad_by_country.setdefault(c_key, []).append(entry)
            mullvad_all.append(entry)
        else:
            personal_exit_nodes.append(entry)

    if not is_mullvad:
        total_peers += 1
        if online:
            online_peers += 1
        devices.append(entry)

personal_exit_nodes.sort(key=lambda x: (not x["online"], x["title"].lower()))
pinned_exit_nodes.sort(key=lambda x: (not x["online"], x["title"].lower()))
devices.sort(key=lambda x: (not x["online"], x["host"].lower()))
mullvad_all.sort(key=lambda x: (x["country"], x["city"], x["host"]))

countries = []
for c_key, nodes in mullvad_by_country.items():
    nodes.sort(key=lambda x: (not x["online"], x["city"], x["host"]))
    countries.append({
        "code": c_key,
        "name": country_names.get(c_key, c_key),
        "count": len(nodes),
    })
    c_path = os.path.join(data_dir, f"country_{c_key}.json.tmp")
    with open(c_path, "w", encoding="utf-8") as f:
        json.dump({"total": len(nodes), "nodes": nodes[:max_visible]}, f)
    os.replace(c_path, os.path.join(data_dir, f"country_{c_key}.json"))

countries.sort(key=lambda x: x["name"])

# Representative Mullvad sample (one online node per city up to max_visible)
mullvad_default = []
seen_cities = set()
for node in mullvad_all:
    city_key = (node["countryCode"], node["city"] or node["host"])
    if city_key not in seen_cities and node["online"]:
        seen_cities.add(city_key)
        mullvad_default.append(node)
        if len(mullvad_default) >= max_visible:
            break

all_path = os.path.join(data_dir, "mullvad_all.json.tmp")
with open(all_path, "w", encoding="utf-8") as f:
    json.dump(mullvad_all, f)
os.replace(all_path, os.path.join(data_dir, "mullvad_all.json"))

labels_path = os.path.join(data_dir, "labels.json.tmp")
with open(labels_path, "w", encoding="utf-8") as f:
    json.dump(label_map, f)
os.replace(labels_path, os.path.join(data_dir, "labels.json"))

summary = {
    "backendState": backend_state,
    "running": running,
    "selfHost": self_host,
    "selfIpv4": self_ipv4,
    "selfOs": self_os,
    "onlinePeers": online_peers,
    "totalPeers": total_peers,
    "exitNodeCount": exit_node_count,
    "mullvadNodeCount": mullvad_node_count,
    "hasExit": active_exit_node is not None,
    "activeExitNode": active_exit_node,
    "activeExitTarget": active_exit_node["target"] if active_exit_node else "",
    "activeExitShort": active_exit_node["shortLabel"] if active_exit_node else "",
    "activeExitFull": active_exit_node["fullLabel"] if active_exit_node else "None (Direct traffic)",
    "activeExitLabel": active_exit_node["friendlyLabel"] if active_exit_node else "",
    "resolvedQuickLabel": resolved_quick_label,
    "personalExitNodes": personal_exit_nodes[:max_visible],
    "pinnedExitNodes": pinned_exit_nodes[:max_visible],
    "devices": devices[:max_visible],
    "countries": countries,
    "mullvadDefault": mullvad_default,
    "mullvadDefaultTotal": len(mullvad_all),
}

sum_tmp = os.path.join(data_dir, "summary.json.tmp")
with open(sum_tmp, "w", encoding="utf-8") as f:
    json.dump(summary, f)
os.replace(sum_tmp, os.path.join(data_dir, "summary.json"))
]]

local PY_SEARCH_SCRIPT = [[
import json, os, sys

data_dir = sys.argv[1]
query = (sys.argv[2] if len(sys.argv) > 2 else "").strip().lower()
country = (sys.argv[3] if len(sys.argv) > 3 else "ALL").strip().upper()
max_visible = int(sys.argv[4]) if len(sys.argv) > 4 else 40

all_path = os.path.join(data_dir, "mullvad_all.json")
nodes = []
if os.path.exists(all_path):
    try:
        with open(all_path, "r", encoding="utf-8") as f:
            nodes = json.load(f)
    except Exception:
        nodes = []

matches = []
for n in nodes:
    if country != "ALL" and n.get("countryCode") != country:
        continue
    if query:
        hay = " ".join([
            str(n.get("title") or ""),
            str(n.get("host") or ""),
            str(n.get("dns") or ""),
            str(n.get("ipv4") or ""),
            str(n.get("country") or ""),
            str(n.get("countryCode") or ""),
            str(n.get("city") or ""),
        ]).lower()
        if query not in hay:
            continue
    matches.append(n)

out_tmp = os.path.join(data_dir, "search_results.json.tmp")
with open(out_tmp, "w", encoding="utf-8") as f:
    json.dump({"query": query, "country": country, "total": len(matches), "nodes": matches[:max_visible]}, f)
os.replace(out_tmp, os.path.join(data_dir, "search_results.json"))
]]

local function stripTrailingDot(s: string?): string
    if not s then
        return ""
    end
    return (s:gsub("%.$", ""))
end

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

local function labelsPath(): string
    return dataDir() .. "/labels.json"
end

local function loadState(): { [string]: any }
    local raw = noctalia.readFile(statePath())
    if raw and raw ~= "" then
        local decoded = noctalia.json.decode(raw)
        if type(decoded) == "table" then
            decoded.pinnedNodes = type(decoded.pinnedNodes) == "table" and decoded.pinnedNodes or {}
            decoded.pinnedDevices = type(decoded.pinnedDevices) == "table" and decoded.pinnedDevices or {}
            decoded.quickConnectNode = type(decoded.quickConnectNode) == "string" and decoded.quickConnectNode or ""
            decoded.quickConnectLabel = type(decoded.quickConnectLabel) == "string" and decoded.quickConnectLabel or ""
            return decoded
        end
    end
    local defaultLan = noctalia.getConfig("allow_lan_access")
    if defaultLan == nil then
        defaultLan = true
    end
    return {
        pinnedNodes = {},
        pinnedDevices = {},
        quickConnectNode = tostring(noctalia.getConfig("default_quick_exit_node") or ""),
        quickConnectLabel = "",
        allowLanAccess = defaultLan == true,
        acceptRoutes = false,
        acceptDns = true,
        shieldsUp = false,
    }
end

local function saveState(st: { [string]: any })
    local encoded = noctalia.json.encode(st, true)
    if encoded then
        noctalia.writeFile(statePath(), encoded)
    end
end

local function loadSummary(): { [string]: any }?
    local raw = noctalia.readFile(summaryPath())
    if raw and raw ~= "" then
        local decoded = noctalia.json.decode(raw)
        if type(decoded) == "table" then
            return decoded
        end
    end
    return nil
end

local function resolveNodeLabel(target: string): string
    local cleanTarget = stripTrailingDot(target):lower()
    local raw = noctalia.readFile(labelsPath())
    if raw and raw ~= "" then
        local decoded = noctalia.json.decode(raw)
        if type(decoded) == "table" and type(decoded[cleanTarget]) == "string" and decoded[cleanTarget] ~= "" then
            return decoded[cleanTarget]
        end
    end
    return target
end

local function notifyIfEnabled(title: string, body: string)
    local enabled = noctalia.getConfig("notify_on_change")
    if enabled == nil or enabled == true then
        noctalia.notify(title, body)
    end
end

local function broadcastRefresh()
    noctalia.runAsync({ "noctalia", "msg", "plugin", PLUGIN_ID .. ":tailscale", "all", "refresh" })
    noctalia.runAsync({ "noctalia", "msg", "plugin", PLUGIN_ID .. ":panel", "all", "refresh" })
    noctalia.runAsync({ "noctalia", "msg", "plugin", PLUGIN_ID .. ":toggle", "all", "refresh" })
    noctalia.runAsync({ "noctalia", "msg", "plugin", PLUGIN_ID .. ":quick-exit", "all", "refresh" })
end

local function isPermissionError(stderr: string?, stdout: string?): boolean
    local combined = ((stderr or "") .. " " .. (stdout or "")):lower()
    return combined:find("access denied", 1, true) ~= nil
        or combined:find("permission denied", 1, true) ~= nil
        or combined:find("operator", 1, true) ~= nil
        or combined:find("not allowed", 1, true) ~= nil
end

local function runTailscaleControl(args: { string }, onDone: ((boolean, string) -> ())?)
    local cmd = { "tailscale" }
    for _, a in ipairs(args) do
        table.insert(cmd, a)
    end

    noctalia.runAsync(cmd, function(res)
        if res.exitCode == 0 then
            if onDone then
                onDone(true, res.stdout or "")
            end
            return
        end

        local usePkexec = noctalia.getConfig("use_pkexec_fallback")
        if (usePkexec == nil or usePkexec == true)
            and isPermissionError(res.stderr, res.stdout)
            and noctalia.commandExists("pkexec")
        then
            local pkCmd = { "pkexec", "tailscale" }
            for _, a in ipairs(args) do
                table.insert(pkCmd, a)
            end
            noctalia.runAsync(pkCmd, function(pkRes)
                if onDone then
                    local msg = (pkRes.stderr ~= "" and pkRes.stderr) or pkRes.stdout or "Command failed"
                    onDone(pkRes.exitCode == 0, msg)
                end
            end)
        else
            if onDone then
                local msg = (res.stderr ~= "" and res.stderr) or res.stdout or "Command failed"
                onDone(false, msg)
            end
        end
    end)
end

local function pollStatus(onFinished: (() -> ())?)
    if isPolling then
        return
    end
    isPolling = true

    local maxVisible = tonumber(noctalia.getConfig("max_visible_nodes")) or 40
    if maxVisible < 10 then
        maxVisible = 10
    elseif maxVisible > 50 then
        maxVisible = 50
    end

    noctalia.runAsync({ "python3", "-c", PY_POLL_SCRIPT, dataDir(), tostring(maxVisible) }, function(_res)
        isPolling = false
        if onFinished then
            onFinished()
        end
    end)
end

local function connectExitNode(target: string, label: string?)
    local st = loadState()
    local allowLan = st.allowLanAccess
    if allowLan == nil then
        local cfgLan = noctalia.getConfig("allow_lan_access")
        allowLan = (cfgLan == nil) or (cfgLan == true)
    end

    local args = {
        "set",
        "--exit-node=" .. target,
        "--exit-node-allow-lan-access=" .. (allowLan and "true" or "false"),
    }

    runTailscaleControl(args, function(ok, err)
        if ok then
            notifyIfEnabled("Tailscale Exit Node", "Connected to exit node: " .. (label or target))
        else
            noctalia.notify("Tailscale Error", "Failed to connect exit node: " .. tostring(err))
        end
        pollStatus(broadcastRefresh)
    end)
end

local function disconnectExitNode()
    runTailscaleControl({ "set", "--exit-node=" }, function(ok, err)
        if ok then
            notifyIfEnabled("Tailscale Exit Node", "Disconnected from exit node (Direct traffic)")
        else
            noctalia.notify("Tailscale Error", "Failed to disconnect exit node: " .. tostring(err))
        end
        pollStatus(broadcastRefresh)
    end)
end

local function handleQuickConnect()
    local st = loadState()
    local quickTarget = st.quickConnectNode
    if not quickTarget or quickTarget == "" then
        quickTarget = tostring(noctalia.getConfig("default_quick_exit_node") or "")
    end

    if not quickTarget or quickTarget == "" then
        noctalia.notify(
            "Tailscale Quick Connect",
            "No Quick Connect exit node selected yet. Open the Tailscale panel and click the bolt icon on any exit node."
        )
        noctalia.togglePanel(PLUGIN_ID .. ":panel")
        return
    end

    local sum = loadSummary()
    local activeTarget = sum and tostring(sum.activeExitTarget or "") or ""

    local cleanQuick = stripTrailingDot(quickTarget):lower()
    local cleanActive = stripTrailingDot(activeTarget):lower()

    if cleanActive ~= "" and (cleanActive == cleanQuick or cleanActive:find(cleanQuick, 1, true) == 1) then
        disconnectExitNode()
    else
        local label = (st.quickConnectLabel and st.quickConnectLabel ~= "")
            and st.quickConnectLabel
            or resolveNodeLabel(quickTarget)
        connectExitNode(quickTarget, label)
    end
end

local function handleToggleTailscale()
    local sum = loadSummary()
    local isRunning = sum and (sum.running == true) or false

    if isRunning then
        runTailscaleControl({ "down" }, function(ok, err)
            if ok then
                notifyIfEnabled("Tailscale", "Tailscale disconnected")
            else
                noctalia.notify("Tailscale Error", "Failed to stop Tailscale: " .. tostring(err))
            end
            pollStatus(broadcastRefresh)
        end)
    else
        runTailscaleControl({ "up" }, function(ok, err)
            if ok then
                notifyIfEnabled("Tailscale", "Tailscale connected")
            else
                noctalia.notify("Tailscale Error", "Failed to start Tailscale: " .. tostring(err))
            end
            pollStatus(broadcastRefresh)
        end)
    end
end

function update()
    local intervalSec = tonumber(noctalia.getConfig("refresh_interval")) or 5
    if intervalSec < 2 then
        intervalSec = 2
    end
    noctalia.setUpdateInterval(intervalSec * 1000)
    pollStatus(broadcastRefresh)
end

function onConfigChanged()
    local intervalSec = tonumber(noctalia.getConfig("refresh_interval")) or 5
    if intervalSec < 2 then
        intervalSec = 2
    end
    noctalia.setUpdateInterval(intervalSec * 1000)
    pollStatus(broadcastRefresh)
end

function onIpc(event: string, payload: any)
    local arg = tostring(payload or "")
    if event == "refresh" then
        pollStatus(broadcastRefresh)
    elseif event == "quick-connect" then
        handleQuickConnect()
    elseif event == "connect-exit" and arg ~= "" then
        connectExitNode(arg, resolveNodeLabel(arg))
    elseif event == "disconnect-exit" then
        disconnectExitNode()
    elseif event == "toggle-tailscale" then
        handleToggleTailscale()
    elseif event == "pin-node" and arg ~= "" then
        local st = loadState()
        local label = resolveNodeLabel(arg)
        if st.pinnedNodes[arg] then
            st.pinnedNodes[arg] = nil
            notifyIfEnabled("Tailscale Pin", "Unpinned exit node: " .. label)
        else
            st.pinnedNodes[arg] = true
            notifyIfEnabled("Tailscale Pin", "Pinned exit node: " .. label)
        end
        saveState(st)
        pollStatus(broadcastRefresh)
    elseif event == "pin-device" and arg ~= "" then
        local st = loadState()
        local label = resolveNodeLabel(arg)
        if st.pinnedDevices[arg] then
            st.pinnedDevices[arg] = nil
            notifyIfEnabled("Tailscale Pin", "Unpinned device: " .. label)
        else
            st.pinnedDevices[arg] = true
            notifyIfEnabled("Tailscale Pin", "Pinned device: " .. label)
        end
        saveState(st)
        broadcastRefresh()
    elseif event == "set-quick-node" and arg ~= "" then
        local st = loadState()
        local label = resolveNodeLabel(arg)
        st.quickConnectNode = arg
        st.quickConnectLabel = label
        saveState(st)
        notifyIfEnabled("Tailscale Quick Connect", "Quick Connect node set to: " .. label)
        broadcastRefresh()
    elseif event == "toggle-lan" then
        local st = loadState()
        local currentLan = st.allowLanAccess
        if currentLan == nil then
            local cfgLan = noctalia.getConfig("allow_lan_access")
            currentLan = (cfgLan == nil) or (cfgLan == true)
        end
        local nextLan = not currentLan
        st.allowLanAccess = nextLan
        saveState(st)
        runTailscaleControl({ "set", "--exit-node-allow-lan-access=" .. (nextLan and "true" or "false") }, function(ok, _err)
            if ok then
                notifyIfEnabled("Tailscale LAN Access", "Exit node LAN access " .. (nextLan and "enabled" or "disabled"))
            end
            pollStatus(broadcastRefresh)
        end)
    elseif event == "search-mullvad" then
        local sep = arg:find("|", 1, true)
        local country = "ALL"
        local query = arg
        if sep then
            country = arg:sub(1, sep - 1)
            query = arg:sub(sep + 1)
        end
        local maxVisible = tonumber(noctalia.getConfig("max_visible_nodes")) or 40
        if maxVisible < 10 then
            maxVisible = 10
        elseif maxVisible > 50 then
            maxVisible = 50
        end
        noctalia.runAsync(
            { "python3", "-c", PY_SEARCH_SCRIPT, dataDir(), query, country, tostring(maxVisible) },
            function(_res)
                noctalia.runAsync({ "noctalia", "msg", "plugin", PLUGIN_ID .. ":panel", "all", "search-ready" })
            end
        )
    end
end
