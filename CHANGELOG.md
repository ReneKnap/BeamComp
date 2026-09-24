# Changelog

## 0.9.0 -- Early Access (2026-09-12)

The first release. Everything here is new.

Early Access means it is complete and playable, and that a few rough edges are known and listed
below rather than hidden.

### Racing

- Any of BeamNG's time-trial races, run as a real multiplayer race for everyone on the server.
- Checkpoints, live position, live times, and a standings board that updates while you drive.
- A results screen on finish, and a free-roam window afterwards before everything is cleaned up.
- Laps, direction and sprint-or-circuit can be overridden per race.
- `/dnf` to give up, `/results` to hide or show your own results card.

### Starting the field

- **Grids for 105 races are included and already assigned** -- Grid Map, Hirochi Raceway, Italy and
  West Coast USA. Every other race starts on a sensible default layout.
- Parametric starting grids: rows, columns, spacing, distance behind the line, angle -- edited in
  game with a live preview and saved by name.
- A grid can be set as the default for a race, so that race always starts on it.
- Large vehicles get the room they need; the field is placed on the ground it actually stands on.
- A synchronised countdown that holds every car, or an F1-style light sequence where the car is free
  and a jump start costs time instead.

### Who you race

- AI opponents, up to 16, with easy / medium / hard presets and their own named drivers.
- Vehicle rules: everyone in the same car, everyone in a random car, or free choice inside a power
  and weight limit. A car that does not fit the limit is swapped for one that does.
- Qualifying, for a grid order that was driven rather than drawn.
- Championships across several races, and a class-drop tournament that eliminates the back of the
  field each round.

### Running the server

- A setup panel (`/raceui`) with every option and an explanation on every field, and saved setups
  that can be reloaded.
- A grid editor (`/gridui`).
- Admin access by password or by BeamMP name -- see `beamcomp.config.ini`.
- Players pick the name everyone sees with `/name`.
- Recover and repair as a held key during the race, on by default and switchable per race.
- On joining, every player gets one message naming the three commands he needs -- `/raceui`, `/name`
  and `/keys`. The `/raceui` line says how to get in where a password is set, and is left out where he
  could not get in at all.
- `/keys` opens a window showing which keys his own game has those two on, for every connected device,
  where he can also rebind or remove them. The setup panel can still send the key lines to everyone in
  chat.

### Known issues

- Changing your car's configuration during the pause after qualifying leaves it loose going into the
  race countdown.
- If the race host disconnects during staged qualifying while AI are in the field, those AI are left
  stranded in the rotation.

### Not in this release

- Per-race statistics -- best times, track records and the post-race analysis overlay -- are switched
  off. They will come back once they work the way they should.
