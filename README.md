# Tailscale & Mullvad Plugin for Noctalia v5

A full-featured Tailscale and Mullvad Exit Node manager plugin for [Noctalia v5](https://docs.noctalia.dev/).

## Features

- **Interactive Shell Panel (`panel.luau`)**
  - Browse, search, and filter Tailscale and Mullvad VPN exit nodes by country, city, hostname, or IP
  - View connected Tailnet devices, online/offline status, OS, and one-click IP copy
  - Pin favorite exit nodes and Tailnet devices to the top of the list
  - Set a **Quick Connect** exit node with one click (`bolt` button)
  - Toggle **Allow LAN Access** (`--exit-node-allow-lan-access`) directly from the panel
  - Start/stop Tailscale and disconnect active exit nodes
  - Fast background indexing (`service.luau` + `python3`) so large Mullvad relay lists (800+ nodes) never hit Luau's CPU budget

- **Customizable Bar Widget (`widget.luau`)**
  - Multiple label modes:
    - **Active Exit Node / IP**
    - **Custom Text (e.g. `VPN On` / `VPN Off`)**
    - **Tailscale IPv4 Address**
    - **Online Peer Count**
    - **Connection Status**
    - **Compact (Exit Node Only)**
    - **Icon Only (No Text)**
  - Custom icons (`type = "glyph"`) for every state:
    - Exit Node Active (default: `shield-lock`)
    - Connected / No Exit Node (default: `network`)
    - Tailscale Disconnected / Down (default: `shield-off`)
    - Login Required (default: `alert-triangle`)
  - Custom text overrides for active exit node, connected (no exit node), and disconnected states
  - Configurable right-click action (Quick Connect/Disconnect Exit Node, Toggle Tailscale, Disconnect Exit Node, Open Settings)

- **Control Center Shortcuts**
  - **Tailscale Toggle (`shortcut.luau`)**: Toggle Tailscale up/down from Control Center; right-click to open the panel
  - **Quick Exit Node (`quick_exit_shortcut.luau`)**: One-click toggle for your selected Quick Connect exit node

## Requirements

- Noctalia v5 (`plugin_api = 28`)
- `tailscale` CLI
- `python3`

> **Tip:** To switch exit nodes and toggle Tailscale without a Polkit password prompt every time, grant your user Tailscale operator permissions once:
> ```bash
> sudo tailscale set --operator=$USER
> ```

## Installation

1. Clone this repository into your Noctalia plugins folder:
   ```bash
   git clone https://github.com/MaveDX/NoctaliaTailscale ~/.local/share/noctalia/plugins/NoctaliaTailscale
   ```
2. In Noctalia, open **Settings → Plugins**, add `/home/<user>/.local/share/noctalia/plugins/NoctaliaTailscale` as a local path source (or enable **Tailscale & Mullvad**), and add the **Tailscale** widget to your bar in **Settings → Bar**.
