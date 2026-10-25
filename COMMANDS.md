# Chat commands

Everything below can also be done in BeamComp's windows, except giving up a race with `/dnf`. The
commands are for anyone who would rather type. To install BeamComp and find the windows, see
[README.md](README.md).

Commands marked **admin** need race admin rights, see step 3 in the README. Every command hides its own
chat line, so nobody else sees what you typed.

## For everyone

| Command | What it does |
|---|---|
| `/keys` | Opens the window showing your repair and recover keys. You can rebind them there. |
| `/name <your name>` | Sets the name everyone sees. Two to twenty characters, spaces allowed. |
| `/dnf` | Gives up the race you are in. |
| `/results` | Hides or shows your own results card. |
| `/races [all]` | Lists the races on your current map. `all` adds the races from the game's Time Trial menu. |
| `/cars [model]` | Lists the installed vehicles, or the factory versions of one model. |
| `/championship` | Shows the championship table. |
| `/beamcomp` | Answers in the chat if BeamComp is running. |

## For race admins

| Command | Who | What it does |
|---|---|---|
| `/raceui` | admin | Opens the race panel. On a server with a password, everyone can open it to enter the password there. |
| `/gridui` | admin | Opens the grid editor. |
| `/race <name> [options]` | admin | Builds the grid for a race, like **Confirm & Build Grid**. Without a name it prints every option. |
| `/go` | admin | Starts the race waiting on the grid, like **Start Race**. `/start` and `/racestart` do the same. |
| `/raceend` | admin | Ends the race and scores it as it stands, like **End & score**. The cars stay. |
| `/raceclear` | admin | Throws the race away and returns everyone to free roam, like **Cancel race**. |
| `/championship start` | admin | Starts a championship, see below. |
| `/championship stop` | admin | Ends the championship and names the winner. |

## `/race`

```
/race <name>                         the race as the game has it
/race <name> 3                       three laps
/race <name> ai 8 medium             with eight AI opponents
/race <name> car=<model>             everyone in the same car
/race <name> car=host                everyone in the car you are sitting in
/race <name> maxhp=300 order=random  power limit, random grid order
```

`/races` gives you the names to put there. Before anything spawns, your own game checks the race and
the options, and you are told what is wrong instead of getting a broken start. Like the button, `/race`
leaves the field waiting on the grid until `/go`.

Options can come in any order, and each word option also takes a short form, such as `rev` for
`reverse`.

### The race

| Option | What it does |
|---|---|
| `sprint` | Runs the route once and finishes at the end. |
| `circuit` | Runs laps and finishes back at the start line. |
| a number | How many laps. Without one, the track's own lap count applies. |
| `reverse` | Drives the route backwards. A track without its own reverse route refuses this, `force` starts it anyway. |
| `force` | Starts anyway when the track cannot do what you picked: laps on a track that is not a loop, or `reverse` without a reverse route. |
| `grid=<name>` | Lines up on this saved grid instead of the race's default one. |
| `all` | Also finds races from the game's Time Trial menu by name. |

A name can start with `map:` or `menu:` to say which of the two lists you mean, when a race is in both.

### Cars

| Option | What it does |
|---|---|
| `car=<model>` | Everyone drives this car. Add `:<config>` for a factory version, for example `car=<model>:<config>`. |
| `car=random` | Everyone gets a random car. |
| `car=host` | Everyone drives the car you are sitting in. |
| `maxhp=<n>` | A car with more horsepower than this is swapped for one that fits. |
| `maxpwr=<n>` | A car with more horsepower per kilo than this is swapped for one that fits. |
| `maxkg=<n>` | A car heavier than this, in kilos, is swapped for one that fits. |
| `minkg=<n>` | A car lighter than this, in kilos, is swapped for one that fits. |

### Grid order and qualifying

| Option | What it does |
|---|---|
| `order=entry` | A fixed order, the same every race. |
| `order=random` | A random order. |
| `order=last` | The result of the previous race, or random if there was none. |
| `order=pwr` | By power to weight. |
| `order=championship` | By the championship table. |
| `order=quali` | Qualifying decides the grid. |
| `quali=<min>` | How long qualifying runs, from 1 to 30 minutes. |

Add `:rev` to a ranked order to flip it, so the fastest start at the back, for example `order=last:rev`.

### Assists

| Option | What it does |
|---|---|
| `recover` | Lets drivers put a stuck or flipped car back on the track: stop, then hold the key. |
| `repair` | Lets drivers fix a damaged car where it stands: stop, then hold the key. |

Both are on unless you switch them off. `recover:off` and `repair:off` switch one off. `recover:<secs>`
and `repair:<secs>` set how long the key has to be held, from 1 to 30 seconds.

### AI opponents

| Option | What it does |
|---|---|
| `ai <n>` | Adds this many computer drivers, 1 to 16. |
| `ai <n> easy` | The same, with a difficulty: `easy`, `medium` or `hard`. |
| `aicar=<model>` | What the computer drivers drive. Add `:<config>` for a factory version. |
| `aiaggr=<0..1>` | How hard they fight for position. |
| `aiskill=<0..1>` | How cleanly and quickly they drive. |
| `airubber=<0..1>` | How much they speed up when behind and ease off when ahead. Higher keeps the field together. |
| `aiavoid=on` | Lets them steer around other cars instead of driving into them. `aiavoid=off` switches that off. |
| `airoute=snap` | Keeps them on the roads. |
| `airoute=direct` | Follows the race line instead, for routes that leave the road. |

## `/championship`

```
/championship                                   show the table
/championship start                             start one with the default settings
/championship start points=linear order=quali   start one with your own settings
/championship stop                              end it and name the winner
```

| Setting | What it does |
|---|---|
| `points=f1` | 25, 18, 15, 12, 10, 8, 6, 4, 2, 1 for the top ten. The default. |
| `points=linear` | The winner scores one point per starter, every place below one less. |
| `points=quadratic` | 64 for the winner, half as many for each place below. |
| `order=reversed` | The points leader starts at the back. The default. |
| `order=normal` | The points leader starts at the front. |
| `order=quali` | Qualifying decides the grid before each race. |
| `quali=<min>` | How long that qualifying runs, from 1 to 30 minutes. |

Only finishers score. A setting given without `start`, for example `/championship points=f1`, changes
the running championship. Starting a championship ends a class-drop tournament, which is set up in the
race panel only.
