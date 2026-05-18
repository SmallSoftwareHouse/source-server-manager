# SourceMod Admin Commands Reference

## Admin Management (server console / RCON)

| Command | Description |
|---|---|
| `sm_reloadadmins` | Reload admin list from admins_simple.ini (no restart needed) |
| `sm_addadmin <steamid> <flags>` | Add admin at runtime (not persistent) |

## Player Management

| Command | Description |
|---|---|
| `sm_kick <target> [reason]` | Kick a player |
| `sm_ban <target> <minutes> [reason]` | Ban a player (0 = permanent) |
| `sm_unban <steamid>` | Unban a player |
| `sm_slay <target>` | Kill a player |
| `sm_slap <target> [damage]` | Slap a player |
| `sm_rename <target> <newname>` | Rename a player |
| `sm_silence <target>` | Mute + gag a player |
| `sm_mute <target>` | Mute voice |
| `sm_gag <target>` | Gag chat |

## Map / Game

| Command | Description |
|---|---|
| `sm_map <mapname>` | Change map |
| `changelevel <mapname>` | Change map (srcds native) |

## Targeting Syntax

| Target | Description |
|---|---|
| `@all` | All players |
| `@bots` | All bots |
| `@humans` | All human players |
| `@alive` | Alive players |
| `@dead` | Dead players |
| `@me` | Yourself |
| `#userid` | Specific userid (from `status`) |
| `STEAM_X:X:XXXXX` | Specific Steam ID |

## Admin Flags (admins_simple.ini)

| Flag | Permission |
|---|---|
| `z` | Root access (all permissions) |
| `a` | Reserved slot |
| `b` | Generic admin |
| `c` | Kick |
| `d` | Ban |
| `e` | Unban |
| `f` | Slay |
| `g` | Change map |
| `h` | Change cvars |
| `i` | Config execution |
| `j` | Chat |
| `k` | Vote |
| `l` | Password |
| `m` | RCON |
| `n` | Cheats |
| `o` | Custom flag 1 |

## admins_simple.ini Format

```
// Line format: "STEAM_ID" "flags[:immunity]" ["name"]
"STEAM_1:0:12345678" "z"          // root admin
"STEAM_1:0:12345678" "bcd"        // kick/ban moderator
"STEAM_1:0:12345678" "z:99"       // root + immunity level 99
```
