# Roadmap

## Current status

Core features are complete and working. The tool can install, configure, run and monitor L4D2 dedicated servers, manage MetaMod/SourceMod and handle SourceMod admins.

---

## Implemented

- Server install via SteamCMD with automatic download
- **Background installation** — runs in a separate window, main program stays responsive
- **Parallel multi-server install** — multiple servers can download simultaneously
- **Live download monitoring** — status updates automatically on every menu refresh
- Server registry (create, rename, move, delete)
- Initial configuration (map and game mode selection)
- Start / stop / restart with normal and auto-restart modes
- Crash detection and automatic restart
- MetaMod:Source and SourceMod install, verify and remove
- SourceMod admin management (add from logs, from RCON, or manually)
- Windows Firewall rule management
- RCON client (password configuration, command execution)
- Live server status box (installation, mods, RCON, player count)
- Context-aware menu (unavailable options shown as greyed N/A based on server state)
- Multilingual interface (EN / IT)

---

## Planned

### Networking
- 3-level diagnostics: Windows Firewall + UDP listening check + router instructions
- TCP rules for RCON alongside UDP

### Server configuration
- Advanced `server.cfg` editor (tickrate, MOTD, password, etc.)
- Configuration presets (casual, competitive)

### Modding
- Automatic mod update check
- SourceMod plugin manager (list, enable/disable, install)

### Multi-game support
- Generic Source Engine adapter
- Support for TF2, CS:Source, HL2DM and other Source games

### Distribution
- Packaged release with version management
- Self-update from GitHub releases
- PowerShell script signing

### Future ideas
- Log rotation
- Uptime and crash statistics
- Discord webhook notifications
- Automatic backup scheduler
- Workshop map/plugin manager
