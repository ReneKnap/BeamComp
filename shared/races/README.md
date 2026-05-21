# shared/races/

Vendored BeamNG time-trial race definitions BeamComp can run.

## Folder shape

A race is a self-contained folder (BeamNG mission format):

```
<map>/<NNN-name>/
  race.race.json     pathnodes (checkpoints), segments (order), start positions
  info.json          mission wrapper (laps, start trigger, vehicle setup)
  *.prefab.json      race props / markers
```

`race.race.json` is the geometry BeamComp parses (start positions, checkpoint
spheres, ordering); `*.prefab.json` are the props to spawn on every client.

## No races are committed here

BeamNG's stock race files (under the game's
`gameplay/missions/<map>/timeTrial/`) are **bCDDL-licensed game content** and are
intentionally **not** copied into this repository. Drop your own race folder(s)
here, or point the tooling at an installed race, rather than vendoring the
game's files.
