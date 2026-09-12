# BeamComp

**Turn BeamNG.drive's singleplayer time-trial races into real multiplayer races on your BeamMP
server.**

BeamNG ships hundreds of time-trial races, and every one of them is a solo affair against the clock.
BeamComp takes those same races and runs them for everyone on the server at once: an admin picks a
race, every player spawns on a starting grid with fresh cars and the track's own props and cones, a
countdown holds the field, and from the green light on you are racing each other -- with checkpoints,
live position, and a standings board that updates while you drive.

Built for small groups on private servers who would rather race than free-roam.

This is an Early Access release: complete and playable, with a few known rough edges listed in
[CHANGELOG.md](CHANGELOG.md).

## What you get

- **Real starting grids.** Cars line up in rows and columns, not in a heap on the spawn point. Grids
  are editable in-game and saved per race.
- **A synchronised start.** A countdown that locks every car, or an F1-style light sequence where the
  car is free and a jump start costs you time instead.
- **Live race information.** Next checkpoint, your position, your time, and the standings of everyone
  on track.
- **Qualifying**, if you want a grid order that was earned rather than drawn.
- **Championships and class-drop tournaments** across several races in one session.
- **AI opponents** -- up to 16, with difficulty presets, so a group of three still gets a full field.
- **Vehicle rules.** Everyone in the same car, everyone in a random car, or free choice within a power
  and weight limit.
- **In-race assists.** Recover and repair on a held key, on by default and switchable per race.

## Requirements

| | |
|---|---|
| Game | BeamNG.drive with the BeamMP client mod installed |
| Server | A BeamMP server you can put files on |
| Tested against | BeamNG.drive 0.39 |

## If you are just playing

**There is nothing to install.** BeamMP hands you the client mod when you join a server that runs
BeamComp, and the race HUD appears on its own when a race starts.

One thing is worth doing on your first visit:

```
/name Alex
```

That is the name everyone sees in the standings and the results. Without it you appear under your
BeamMP name -- and while BeamMP login is broken, that is a guest number that changes every time you
start the game, so nobody will recognise you twice. Two to twenty characters, spaces allowed.

During a race, `/dnf` gives up and `/results` hides or shows your own results card.

## If you run the server

### 1. Install

The download unpacks to four things:

```
README.md       this file
CHANGELOG.md    what is in this version, and what is known to be rough
LICENSE         the terms it comes under
Resources/      the mod itself
```

Copy `Resources` into your BeamMP server folder, merging it with the one already there. Afterwards
your server has:

```
<BeamMP-Server>/Resources/Client/BeamComp.zip     the mod players receive
<BeamMP-Server>/Resources/Server/BeamComp/        the plugin the server runs
```

Then restart the server. It prints `beamcomp` lines on startup; if you see none, the plugin did not
load.

You do not need to hand `BeamComp.zip` to anyone -- BeamMP delivers it to every player who joins.

### 2. Decide who may start races

Starting and aborting races, saving and deleting grids and presets, and running the championship are
**admin-gated**. `Resources/Server/BeamComp/beamcomp.config.ini` offers two ways in, and they work side
by side:

```ini
# The practical one. Any string.
racePassword = pick-something

# Race admins by BeamMP name, comma separated.
raceAdmins =
```

- **`racePassword`** -- a player types `/raceui`, the setup panel opens with a password box, and the
  right password makes them a race admin **until they leave the server**. Nothing is stored on the
  client, so it is entered once per session. Five wrong tries start a 60-second cooldown; every attempt
  is logged with the player's name and never with what they typed.
- **`raceAdmins`** -- a list of BeamMP display names. **This does not work while BeamMP account login is
  broken:** everyone connects as a guest and the guest name changes on *every* game start, so today's
  entry will not match the same person tomorrow. It is kept for the day logins come back.

> **With neither set, every connected player may start races, overwrite grids and run the
> championship.** That is the deliberate default so nothing breaks on an existing server, and the
> server prints a boxed warning at startup whenever it applies.

The settings file is read **once, at server start** -- change the password, restart the server.

**Every setting is explained in the file itself** -- open it once and you have the whole picture. What
follows here is the same thing in short.

<details>
<summary>The rest of the settings file</summary>

`beamcomp.config.ini` is a plain `key = value` file, one setting per line:

```ini
# Lines starting with # are comments.
raceAdmins = Alice, Bob
racePassword = something-only-we-know
useClientName = true
```

- `useClientName` -- whether the name a player set with `/name` is used. `false` always uses the BeamMP
  name.
- A line that cannot be read is **skipped with a warning naming its line number**, and every other
  setting still applies. A typo costs you that one line, not the password three lines below it.
- A `#` (or `;`) starts a comment **only at the start of a line**. Mid-line it is an ordinary character,
  so a password may contain one.
- The value is everything after the **first** `=`, trimmed at both ends. A password may contain `=`, but
  cannot begin or end with a space -- there is no quoting.
- An empty value means "not set", for every key.

</details>

### 3. Raise `MaxCars`

In your server's `ServerConfig.toml`. BeamMP's `MaxCars` caps **all** vehicles a single player may have
synced -- and a race spawns, owned by the race host, their own car **plus the track's prop and cone
vehicles plus every AI car**. If `own + props + AI` exceeds `MaxCars`, BeamMP silently deletes the
overflow, so only the first few AI ever appear.

Set it high enough for the worst case, for example **64** (1 own + ~40 props + 16 AI).

## Running a race

The comfortable way is the panel:

```
/raceui
```

It lists the races on your current map and lets you set everything -- laps, direction, grid, vehicle
rules, AI, qualifying, start mode -- with an explanation on every field. Saved setups can be reloaded
next time.

The same thing from chat, if you know what you want:

```
/race <name>                         the race as the game has it
/race <name> 3                       three laps
/race <name> ai 8 medium             with eight AI opponents
/race <name> car=<model>             everyone in the same car
/race <name> maxhp=300 order=random  power limit, random grid order
```

`/races` gives you the names to put there. Bare `/race` prints the full list of options. The server never guesses: it asks your own game client to
check the race and the options first, and tells you what is wrong instead of starting something broken.

**Then the field waits for you.** Everyone spawns on the grid and stays there -- staging does not end by
itself. Start it with the panel's button or:

```
/go
```

Anything else that goes wrong has a way out: `/raceend` jumps straight to the results screen, and
`/raceclear` returns everything to normal free-roam.

## Command reference

| Command | Who | What |
|---|---|---|
| `/race <name> [options]` | admin | Prepare a race. Bare `/race` prints the options. |
| `/go`, `/start`, `/racestart` | admin | Start the staged race. Nothing starts without it. |
| `/raceend` | admin | Force the race to the results screen, cars stay. |
| `/raceclear` | admin | Force everything back to free-roam and clean up. |
| `/raceui` | admin | Open the race setup panel. Also the password prompt. |
| `/gridui` | admin | Open the starting-grid editor. |
| `/races [all]` | everyone | List the races on your current map. |
| `/cars [model]` | everyone | List installed vehicles, or one model's configurations. |
| `/name <your name>` | everyone | Set the name everyone sees. |
| `/dnf` | everyone | Give up the race you are in. |
| `/results` | everyone | Hide or show your own results card. |
| `/beamcomp` | everyone | Diagnostic ping -- answers in chat if the mod is alive. |

## Starting grids

**105 races come with a grid already built and assigned**, covering Grid Map, Hirochi Raceway, Italy
and West Coast USA. You do not have to do anything for those -- they start on a proper grid out of the
box. Every other race starts on a sensible default layout until you build one for it.

`/gridui` opens the grid editor: rows and columns, spacing, where the field sits relative to the start
line, and how it is angled. You see the result on the track while you edit it. Grids are saved by name
and one can be set as the default for a race, so it is used every time that race is started.

Grids live in `Resources/Server/BeamComp/beamcomp.grids.json`. **Your own grids are never overwritten**
-- installing a newer BeamComp keeps the file you have. The flip side is that grids added in a later
version do not reach a server that already has the file; the changelog says when new ones ship.

## When something looks wrong

- **Only the first few AI cars appear.** `MaxCars` is too low. See above.
- **A change you deployed has no effect in-game.** The BeamMP client cache can go stale. Restart
  BeamNG fully; the client logs `beamcomp | loaded (build ...)` with a build marker you can check in
  `beamng.log`.
- **The password does not work after a redeploy.** `beamcomp.config.ini` is overwritten by the deploy.
  Set the password on the server again and restart it.
- **Everyone can start races.** Neither `racePassword` nor `raceAdmins` is set. The startup warning says
  so too.

## License

BeamComp is **not open source**, and the usual modding assumption does not apply here. The full terms
are in [LICENSE](LICENSE) -- PolyForm Strict 1.0.0 plus one additional permission. In short:

- **You may** download it, install it, and run it on your own server, for any purpose, including a
  commercial one.
- **You may not** redistribute it -- no mirrors, no re-uploads to mod sites, no bundling it into
  anything else, no selling it. Link people to the original download instead.
- **You may not** publish modified versions or new works based on it.
- It comes with **no warranty**.

The source is readable on purpose, so you can see what runs on your own server and so a problem in the
field can be diagnosed. That is not an invitation to redistribute it.

**Why it is worth respecting.** BeamComp is free to play with -- the supporters who pay for it are
buying *early* access to new versions, nothing else. One re-upload and that is gone, and with it the
reason there are new versions. If someone asks you for it, send them to the original download.

If you want to do something the license does not allow, ask -- permission can be granted.
