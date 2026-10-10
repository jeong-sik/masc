# Local machine play

Run an independently built `masc-msx-addon-worker` or `masc-dos-addon-worker`
without an HTTP server or Docker. This is a single-player host for a separate
worker process; it does not attach tools to a running MASC server.

For game-specific prompts and verified local examples, see
[Sangokushi II (MSX) and III (DOS)](SANGOKUSHI.md).

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

For MSX in-game saves, complete the game's save command on its data floppy.
While that floppy is still mounted, export it to a new catalog name:

```json
{"operation":"export_disk","arguments":{"filename":"campaign-data-01.dsk"}}
```

The receipt identifies the exported bytes by filename, length and SHA-256.
Existing names are refused, including symlinks; choose a fresh name each time.
The original image and the running machine remain unchanged. After a fresh
boot, follow the game's load-game/data-disk prompt and use `change_disk` with
that exported filename. A data disk need not itself be bootable. Export is
separate from `save`, which retains the complete emulator checkpoint. It exports
only the currently mounted disk, so exporting the program disk after swapping
away from the data disk does not save the data disk's changes.

The catalog must already exist as `.masc/msx/carts/` under the isolated workspace.
Its components must be real directories kept stable by the local operator;
this path-based writer does not protect against a concurrent privileged host
process replacing an ancestor during publication. Completed bytes are linked
under the new name atomically; process restart preserves the image, but export
does not promise directory-entry durability across power loss.

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
