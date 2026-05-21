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

## Status

Phase 1 (Recon & Skeleton). This scaffold establishes the repository layout;
runtime behaviour (chat command, spawning, countdown, checkpoints, HUD) lands in
the following sprint items.
