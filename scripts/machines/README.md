# Local machine play

Run an independently built `masc-msx-addon-worker` or `masc-dos-addon-worker`
without an HTTP server or Docker. This is a single-player host for a separate
worker process; it does not attach tools to a running MASC server.

Use a separate workspace populated with **copies** of your local media:

- MSX: `.masc/msx/bios/` and `.masc/msx/carts/`.
- DOS: `.masc/dos/programs/<game>/` containing the executable and game data.

Do not point this at a shared live workspace. Checkpoints and guest writes go
into the supplied workspace. No media is included or downloaded by this tool.

```sh
python3 scripts/machines/local-play.py --machine msx \
  --worker /path/to/masc-msx-addon-worker --base-path /path/to/isolated-workspace
```

Keep this process running. Send one JSON line per decision; schemas are saved
in the printed `tools.json` path. Examples:

```json
{"operation":"meta","arguments":{"include_inventory":true}}
{"operation":"load","arguments":{"cart":"sangokushi-2.dsk"}}
{"operation":"screen","arguments":{}}
{"operation":"press","arguments":{"keys":["return"],"hold_frames":1,"frames":15}}
{"operation":"save","arguments":{"slot":"local-before-choice"}}
```

For DOS, launch with `--machine dos` and its worker. Inspect `inventory`, then
load the game directory with the selected executable from that inventory:

```json
{"operation":"inventory","arguments":{}}
{"operation":"load","arguments":{"program":"samguk3","boot":"KOEI.COM"}}
{"operation":"screen","arguments":{}}
```

Read the returned PNG before deciding the next input. Delivery alone does not
prove a menu choice succeeded. The runner records requests durably before
sending them and retains full replies, PNGs and worker stderr in a new evidence
directory. Transport/protocol errors stop the session; inspect the saved record
before attempting another input. EOF stops the worker, so explicitly save a
checkpoint before ending the process. Restart with the same isolated workspace
and `restore` the named slot to resume.

The DOS controller belongs to `local-player`. Calls check its current holder;
this runner does not take another principal's controller or hand it to a Keeper
in a different process. Shared sessions should use the MASC host admission path.
