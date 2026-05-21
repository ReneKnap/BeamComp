# shared/

Single source for things both the server plugin and the client mod need.

## `envelope.lua`

The cross-side message envelope: every BeamComp message is
`{ "type": <string>, "payload": <any> }`, JSON-encoded. `envelope.lua` provides
`encode` / `decode` over that shape.

Because the server (BeamMP Lua) and client GE (BeamNG LuaJIT) run in isolated,
separately-delivered Lua states, they cannot `require` a shared file at runtime.
So `scripts/deploy.ps1` **copies `envelope.lua` into both payloads** at build:

- client zip: `lua/ge/extensions/beamcomp/envelope.lua`
- server: `Resources/Server/BeamComp/envelope.lua`

Edit it here once; the deploy step propagates it. The committed repo holds no
duplicate copies.

The two runtimes ship JSON helpers under different names (BeamNG
`jsonEncode` / `jsonDecode`; BeamMP `Util.JsonEncode` / `Util.JsonDecode`), so
`envelope.lua` takes an injected codec -- each side wires its own at load via
`envelope.set_codec(encode_fn, decode_fn)`.

## `races/`

Vendored time-trial race definitions. See `races/README.md`.
