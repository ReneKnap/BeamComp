# BeamComp

Turn BeamNG.drive singleplayer time-trial races into real BeamMP multiplayer races.

A server admin starts a race via a chat command; all present players spawn fresh
vehicles at the start positions, a synchronised countdown locks movement, and
during the race every player sees their checkpoints, position, and live time,
with final standings on finish.

## Repository layout

| Path | What it is | Deploys to |
|------|------------|------------|
| `server/` | BeamMP server plugin (Lua) | `Resources/Server/BeamComp/` |
| `client/` | BeamNG client mod -- mirrors the mod-zip tree | `Resources/Client/BeamComp.zip` |
| `shared/` | Cross-side message envelope + vendored race definitions | copied into both at deploy |
| `scripts/` | Build / deploy tooling | -- |

`client/` mirrors a BeamNG mod's internal structure so it zips directly:

```
client/
  lua/ge/extensions/beamcomp/        GE (Game-Engine) extensions
  lua/vehicle/extensions/beamcomp/   VE (Vehicle-Engine) extensions
  ui/modules/apps/BeamCompHud/       HUD UI app (AngularJS)
```

The server (BeamMP Lua) and client GE (BeamNG LuaJIT) run in **isolated Lua
states** and cannot share code at runtime, so `shared/envelope.lua` is the single
source of the message contract and is **copied into both payloads at deploy
time** (duplicated only in the built output, never in the committed tree).

## Dev -> deploy workflow

1. Edit sources under `server/`, `client/`, `shared/`.
2. Deploy to a BeamMP server:

   ```powershell
   .\scripts\deploy.ps1 -Target 'C:\path\to\BeamMP-Server'
   ```

   This zips `client/` (plus the shared envelope) to
   `<Target>\Resources\Client\BeamComp.zip` and copies `server/` (plus the
   shared envelope) to `<Target>\Resources\Server\BeamComp\`. The script is
   idempotent and never modifies the committed `client/` or `server/` trees.

3. (Re)start the BeamMP server. Joining BeamNG clients receive the client mod
   automatically.

## Race admin: who may start races

Starting and aborting races, saving and deleting grids and presets, and running the
championship/tournament are **admin-gated**. `server/beamcomp.config.json` offers two ways to be an
admin, and they work side by side:

- **`racePassword`** — the practical one. Set it to any string; a player types `/raceui`, the setup
  panel opens showing a password box, and entering the password makes him a race admin **until he
  leaves the server**. Nothing is stored on the client, so every player enters it once per session.
  Five wrong tries start a 60-second cooldown, and every attempt is logged with the player's name —
  never with what he typed.
- **`raceAdmins`** — a list of BeamMP display names. **This does not work while BeamMP account login is
  broken:** everyone connects as a guest, and the guest name changes on *every game start*
  (`guest2787141`, then `guest1124408`, …), so an entry will not match the same person tomorrow. It is
  kept for the day logins come back.

**With neither set, every connected player may do all of the above** — the deliberate, non-breaking
default. The server logs a boxed warning at startup when that is the case.

Three things to know about the file itself:

- **You cannot comment in it.** JSON has no comment syntax, and `Util.JsonDecode` rejects every form of
  it — `//`, `/* */`, `#`, `--` and a trailing comma all make the file invalid. It is invalid as a
  *whole*, so one commented-out line silently disables **every** setting in it, including a password you
  thought was protecting the server. The `"_"`-prefixed keys (`_note`, `_raceAdmins`, `_racePassword`)
  are the notes instead; the plugin ignores them. If you do break the file, the server says so at
  startup, names this as the likely cause, and warns that no password is in effect.
- It is read **at server start only**. Change the password, restart the server.
- It is **tracked in git and not preserved by the deploy**: `scripts/deploy.ps1` wipes and recopies
  `Resources/Server/BeamComp/` from the repo (only `beamcomp.grids.json`, `beamcomp.runs.jsonl` and
  `beamcomp.presets.json` are carried across). A password set on the server is gone after the next
  deploy, and one committed to the repo travels with the release. Set it on the server after deploying,
  or accept that it ships.

## Server config requirement (AI races)

BeamMP's `MaxCars` (in the server's `ServerConfig.toml`) caps **all** vehicles one
player (the race host) may have synced — and a race spawns, host-owned, the host's
own car **plus the track's prop/cone vehicles plus the AI cars**. If
`own + props + AI` exceeds `MaxCars`, BeamMP silently deletes the overflow (the
last-spawned AI), so only the first few AI appear. Set `MaxCars` high enough to
cover the worst case (e.g. **64** = 1 own + ~40 prop vehicles + 16 AI). The AI
count itself is capped at 16 in the plugin; `MaxCars` must simply stay well above
`own + props + 16`.

## Status

Phase 1 (Recon & Skeleton). This scaffold establishes the repository layout;
runtime behaviour (chat command, spawning, countdown, checkpoints, HUD) lands in
the following sprint items.
