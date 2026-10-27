# Developing BeamComp

This file is for working *on* BeamComp. To install and run it, see [README.md](README.md).

## Repository layout

| Path | What it is | Deploys to |
|------|------------|------------|
| `server/` | BeamMP server plugin (Lua) | `Resources/Server/BeamComp/` |
| `client/` | BeamNG client mod, laid out like the mod zip | `Resources/Client/BeamComp.zip` |
| `shared/` | Cross-side message envelope | copied into both at deploy |
| `scripts/` | Build / deploy tooling | not deployed |

`client/` mirrors a BeamNG mod's internal structure so it zips directly:

```
client/
  lua/ge/extensions/beamcomp/        GE (Game-Engine) extensions
  lua/vehicle/extensions/beamcomp/   VE (Vehicle-Engine) extensions
  ui/modules/apps/BeamCompHud/       race HUD (AngularJS)
  ui/modules/apps/BeamCompSetup/     race setup panel
  ui/modules/apps/BeamCompGridEditor/  grid editor panel
```

## `shared/` is copied, not required

The server (BeamMP Lua 5.3) and the client GE side (BeamNG LuaJIT) run in **isolated Lua states** and
cannot `require` a common file at runtime. So `shared/envelope.lua` is the single source of the message
contract. Every BeamComp message is `{ "type": <string>, "payload": <any> }`, JSON-encoded, and
`scripts/deploy.ps1` **copies it into both payloads** at build time:

- client zip: `lua/ge/extensions/beamcomp/envelope.lua`
- server: `Resources/Server/BeamComp/envelope.lua`

Edit it once here; the deploy propagates it. The committed tree holds no duplicate.

The two runtimes ship JSON helpers under different names (BeamNG `jsonEncode` / `jsonDecode`; BeamMP
`Util.JsonEncode` / `Util.JsonDecode`), so `envelope.lua` takes an injected codec. Each side wires its
own at load via `envelope.set_codec(encode_fn, decode_fn)`.

`shared/races/` holds no race files. BeamNG's stock time-trial races are bCDDL-licensed game content and
are deliberately **not** vendored into this repository; point the tooling at an installed race instead.

## Dev -> deploy workflow

1. Edit sources under `server/`, `client/`, `shared/`.
2. Deploy to a BeamMP server:

   ```powershell
   .\scripts\deploy.ps1 -Target 'C:\path\to\BeamMP-Server'
   ```

   This zips `client/` (plus the shared envelope) to `<Target>\Resources\Client\BeamComp.zip` and copies
   `server/` (plus the shared envelope) to `<Target>\Resources\Server\BeamComp\`. It is idempotent and
   never modifies the committed `client/` or `server/` trees. All staging happens in a temp folder.

3. (Re)start the BeamMP server. Joining BeamNG clients receive the client mod automatically.

### What a deploy keeps, and what it overwrites

The server folder is wiped and recopied on every run, but the plugin's own runtime data is carried
across first:

- **Preserved:** `beamcomp.grids.json`, `beamcomp.presets.json`, `beamcomp.runs.jsonl`. Each preserve
  step is guarded, so deploying to a fresh target is fine.
  **`server/beamcomp.grids.json` is authored content, not an empty seed.** It holds 251 races on 13
  maps with a grid and a default assignment, and it ships. Because the deploy preserves an existing target file, a server
  that already has grids keeps its own and therefore never receives newly shipped ones; only a fresh
  install gets the current set. Say so in the changelog when the set grows.
  Grids are edited in-game, so updating the shipped set means copying the live file back into the
  repo: `<server>\Resources\Server\BeamComp\beamcomp.grids.json` -> `server/`. Nothing does that
  automatically, on purpose, because it would let a test server's experiments walk into a release.
- **Overwritten:** everything else, **including `beamcomp.config.ini`**. That file is tracked in git, so
  a password set on the server is gone after the next deploy, and one committed to the repo travels with
  the release. Set it on the server *after* deploying, or accept that it ships.
- `-Clean` additionally removes the client zip before rebuilding it.

### The license rides along

The deploy copies `LICENSE` into **both** halves (the zip root and the server folder) and `README.md`
into the server folder. BeamComp is MIT-licensed, and MIT's one condition is that the copyright notice
and the license text travel with every copy. So each half carries its own, and a server operator who
only ever sees the server folder still has it. A missing `LICENSE` or `README.md` **aborts the deploy**
instead of producing a build without them.

### Proving a client change is actually live

The BeamMP client mod is served from a cache that can go stale, so a merged client fix can look inert
in-game while the client still runs the old zip. `init.lua` carries a `BUILD_MARKER` that is logged at
load:

```
I|GELua.beamcomp| loaded (build tooltip-copy/2026-09-12)
```

Check for the current marker in `beamng.log` before concluding that a change did not work, and bump the
marker when shipping a client-visible fix that needs an in-game re-test.

## Building the download

```powershell
.\scripts\package.ps1
```

Produces `releases/BeamComp-<version>/` and `releases/BeamComp-<version>.zip`: `README.md`,
`COMMANDS.md`, `CHANGELOG.md`, `LICENSE` and the `Resources/` tree a server operator drops into their
server. The
`Resources` half is built by calling `deploy.ps1`, the same code path that puts BeamComp on a live
server, so the download cannot drift from what has been tested.

Two things it refuses to do:

- **Invent a version.** It reads `PLUGIN_VERSION` from `server/main.lua`, so the number on the zip is
  the number the server reports back with `/beamcomp`. Bump it there.
- **Ship a package that disagrees with itself.** The three `ui/modules/apps/*/app.json` carry their own
  `version` because BeamNG reads them directly, and nothing at runtime compares them to the plugin. The
  packaging step does, and a mismatch stops the build.

It warns (but does not stop) when the working tree is dirty, because a release built from uncommitted
work cannot be rebuilt from a commit later.

`releases/` is gitignored.

## Two things that fail silently

- **The 200-local ceiling.** LuaJIT allows at most 200 active locals per function, and a file's main
  chunk *is* a function. `server/main.lua` and `client/lua/ge/extensions/beamcomp/init.lua` both sit near
  that limit. Going over is a **compile error**, so the file never loads and the whole plugin or
  extension is silently dead: no HUD, no chat commands, no clue why. Hang new helpers on an existing
  namespace table instead of adding a top-level `local`.
- **GE and VE are different Lua VMs.** Game-Engine and Vehicle-Engine extensions share no state, no
  modules and no globals. Cross-VM communication goes through the engine APIs (`be:queueLuaCommand`,
  `obj:queueGameEngineLua`, `extensions.hook`).

## Design decisions

The source comments reference architecture decisions by number (`ADR-0017`, `ADR-0043`, …). Those
records are kept with the project's working notes and are not part of this repository.
