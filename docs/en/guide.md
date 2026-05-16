# Source Server Manager — User Guide

## Table of contents

1. [Requirements](#requirements)
2. [Installation](#installation)
3. [First launch](#first-launch)
4. [Main menu](#main-menu)
5. [Creating a server](#creating-a-server)
6. [Managing a server](#managing-a-server)
7. [Starting and stopping](#starting-and-stopping)
8. [Mods — MetaMod:Source and SourceMod](#mods)
9. [SourceMod admin management](#sourcemod-admin-management)
10. [Firewall](#firewall)
11. [Server settings](#server-settings)
12. [Configuration file](#configuration-file)
13. [Adding a language](#adding-a-language)
14. [Status icons](#status-icons)
15. [FAQ](#faq)

---

## Requirements

- Windows 10 or 11
- PowerShell 5.1 (pre-installed on all modern Windows systems)
- Internet connection (for SteamCMD download and server installation)
- ~20 GB of free disk space per server

No additional software needs to be installed manually. SteamCMD is downloaded automatically on first use.

---

## Installation

Download or clone the repository to any folder on your machine, then run:

```powershell
.\main.ps1
```

The tool is portable — it works from any path and stores all data relative to its own folder.

---

## First launch

On first launch you will be prompted to select a language. The choice is saved automatically to `config/default_config.json` and will not be asked again on subsequent launches.

To change the language later: **Settings → Change language** from the main menu, or set `"Language": ""` in the config file to trigger the selection again on next start.

---

## Main menu

| Option | When visible |
|--------|-------------|
| Create server | Always |
| Full server list | Only when servers exceed the header display limit |
| Manage server | Always |
| Resume installation | Greyed out when no server has an incomplete installation |
| Settings | Always |
| Exit | Always |

The header at the top of the main menu shows a summary of registered servers with their current status. Up to 5 servers are shown by default (configurable via `HeaderServerLimit`).

---

## Creating a server

From the main menu, select **Create server**:

1. Enter a server name (letters, numbers and hyphens — no spaces or special characters)
2. Enter an installation path, or leave it empty to use the default from the configuration file

The tool validates the name and path before proceeding. If the destination folder already exists and is not empty, a warning is shown — you can continue anyway (SteamCMD will verify and overwrite as needed) or cancel.

SteamCMD is downloaded automatically on first use, then the L4D2 Dedicated Server is installed at the chosen path. Installation time depends on connection speed and is typically 10–30 minutes.

---

## Managing a server

From the main menu, select **Manage server**, then choose a server from the list.

A status box shows the current state of the selected server before displaying the action menu.

### Available actions

| Option | Description |
|--------|-------------|
| Rename | Rename the server and its folder on disk |
| Move | Move all server files to a new path |
| Update | Re-verify and update files via SteamCMD |
| Delete | Remove the server from the registry (files on disk are not deleted) |
| Configure | First-time setup: choose map and game mode |
| Change map/gamemode | Update map or game mode after initial configuration |
| Start / Stop | Start or stop the server |
| Restart | Restart the server (stop then start) |
| Firewall | Manage the Windows Firewall rule for this server |
| Mods | Install, verify and manage MetaMod:Source and SourceMod |
| Manage admins | Manage SourceMod admin list |
| Server settings | Set RCON password and other per-server options |
| Open folder | Open the server folder in Windows Explorer |
| Back | Return to the main menu |

Options that are not available in the current state are shown greyed out and cannot be selected (for example, Restart is greyed out when the server is not running).

---

## Starting and stopping

### Start modes

When starting a server, two modes are available:

**Normal start**
The server opens in its own window. If it crashes, it does not restart automatically.

**Auto-restart**
A separate monitor process watches the server. If it crashes or closes unexpectedly, it is restarted automatically. The monitor retries up to 100 times with a 5-second delay between attempts.

### Tracking server state

Server state is tracked via a `.running` file inside the server folder. This file contains the process ID and start time. The tool checks this file each time you open the manage menu and detects automatically if the server has stopped.

### Stopping

Select **Stop server** from the manage menu. The tool terminates the server process (and the monitor process, if auto-restart mode was active).

---

## Mods

From the server manage menu, select **Mods**.

The mod menu shows the current installation status of MetaMod:Source and SourceMod, including version numbers when installed.

### Install recommended versions

Fetches the latest stable versions of MetaMod:Source and SourceMod from their respective download pages and installs them directly into the server folder. No manual download or extraction is needed.

After installation, a restart prompt appears if the server is currently running.

### Install custom version

Displays a list of available versions for each mod (up to 5 per mod) so you can select a specific one. This is useful if a particular game version requires an older mod build.

### Verify mods via RCON

While the server is running and RCON is configured, this option sends `meta version` and `sm version` to the server console and displays the responses. This confirms whether the mods are actually loaded, not just present on disk.

> Mods are loaded at server startup. If you just installed them, restart the server before verifying.

### Remove mods

Removes MetaMod:Source and SourceMod from the server folder. Requires confirmation before deleting.

---

## SourceMod admin management

From **Mods → Manage admins**.

This menu manages the `admins_simple.ini` file that SourceMod reads on startup to determine which players have elevated permissions.

### Adding an admin

Three ways to add an admin:

| Method | Description |
|--------|-------------|
| From known players | Pick from players found in SourceMod logs (requires Scan logs first) |
| From connected players | Pick from currently connected players via RCON (server must be running) |
| Manual Steam ID | Enter a Steam ID directly (format: `STEAM_1:0:12345678`) |

After selecting a player, choose a permission level:

| Level | Flags | Access |
|-------|-------|--------|
| Root | `z` | Full access to all SourceMod commands |
| Moderator | `bcd` | Kick, ban, change map |
| Custom | user-defined | Any combination of SourceMod permission flags |

### Removing an admin

Select an admin from the current list to remove them. Confirmation is required before deletion.

### Scan logs

Scans SourceMod log files to build a list of players who have previously connected to the server. This list is stored locally and used to populate the player picker when adding admins.

### Applying changes

Changes to `admins_simple.ini` take effect on the next server start. If the server is currently running and RCON is configured, the tool automatically sends `sm admins rebuild` to apply changes without a restart.

---

## Firewall

From the server manage menu, select **Firewall**.

This option adds or removes a Windows Firewall inbound rule that opens port 27015 (the default Source Engine game port).

> Firewall management requires administrator privileges. If the option reports a permission error, restart PowerShell as Administrator.

The status box in the manage menu shows whether a firewall rule is currently present for the server.

---

## Server settings

From the server manage menu, select **Server settings**.

Currently available settings:

**RCON Password**
Sets the remote console password for the server. The password is written to `server.cfg` and enables the tool to send commands to the running server (mod verification, admin reload, player list).

The status box shows `[OK] ***` when a password is set, or `[--] Not set` when it is not.

---

## Configuration file

`config/default_config.json` controls global tool behaviour:

| Field | Type | Description |
|-------|------|-------------|
| `Language` | string | Interface language code (`en`, `it`). Set to `""` to prompt on next start |
| `DefaultInstallRoot` | string | Default path for new server installations |
| `EnableLogging` | bool | Write session logs to `logs/manager.log` |
| `DefaultMaxPlayers` | int | Default max players value for new servers |
| `HeaderServerLimit` | int | Number of servers shown in the main menu header (default: 5) |

`config/servers_registry.json` holds the list of registered servers. This file is excluded from source control because it contains machine-specific paths.

---

## Adding a language

1. Copy `locale/en.json` to `locale/{code}.json` (e.g. `locale/de.json`)
2. Translate all string values — keep the JSON keys unchanged
3. Set the `LanguageName` field to the native name of the language (e.g. `"Deutsch"`)
4. The language appears automatically in **Settings → Change language** on next launch

---

## Status icons

### Server list

| Icon | Color | Meaning |
|------|-------|---------|
| `[OK]` | Green | Server found on disk and registry |
| `[>>]` | Cyan | Installation in progress |
| `[!!]` | Yellow | Incomplete install or unrecognised state |
| `[--]` | Red | Path not found on disk |

### Status box (manage menu)

| Field | States |
|-------|--------|
| Installation | Installed / Installing / Missing / Corrupted |
| Configuration | Configured / Not configured |
| MetaMod / SourceMod | Active / Not loaded / Not installed |
| Firewall | Rule present / No rule |
| Status | Running / Not running |
| RCON | Active (with player count) / Configured / Unreachable / Password not set |

---

## FAQ

**Can I move the server folder manually?**
Yes. Afterwards, use **Manage → Move** to update the registry to the new path.

**Delete removed the server but files are still on disk — is that correct?**
Yes. Delete only removes the entry from the registry. Files on disk are never deleted automatically. Remove them manually if needed.

**The Firewall option reports a permission error.**
The tool must be run as Administrator to add or remove Windows Firewall rules. Right-click PowerShell and select "Run as administrator".

**I installed mods but they are not active.**
Mods are loaded at server startup. Restart the server after installation. Use **Mods → Verify** to confirm they are loaded.

**How do I reset the language selection?**
Set `"Language": ""` in `config/default_config.json`, or use **Settings → Change language** from inside the tool.

**Auto-restart keeps restarting a crashing server — how do I stop it?**
Use **Manage → Stop server** from the tool menu. It terminates both the server process and the monitor process.

**The server registry shows a server as Missing but the files are there.**
The path stored in the registry does not match the actual folder location. Use **Manage → Move** and enter the correct path to re-link them.
