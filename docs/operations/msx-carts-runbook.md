# MSX cartridges

The operator runbook for the game images the workspace MSX machine
(RFC-0439) can load.

## Where they live

`<base-path>/.masc/msx/carts/` is the inventory. `masc_msx_load` without a
`cart` lists it as `carts_available`, and a Keeper then passes one of those
names (with or without `.rom`) as `cart`. The TUI's MSX screen opens with a
load menu over the same directory. The directory starts empty; nothing in the
install or the server fills it.

The C-BIOS ROMs the machine boots from are separate: `MSX_ROMS` names their
directory, or `.masc/msx/bios/` when it holds `cbios_main_msx2.rom`.

## What the machine accepts

The core maps plain cartridges and supports ASCII8, ASCII16, Konami,
Konami-SCC banking and Koei ASCII8 SRAM variants. Mapper detection is not
a compatibility guarantee: loading an image and seeing a title do not prove
that menus, gameplay, sound or persistent saves work.

## Disk images (.dsk)

`cart` also takes a raw `.dsk` floppy image: a name ending in `.dsk` (the
extension can be left off) loads into the drive instead of the slot, from
the same `carts/` inventory. The load itself runs the C-BIOS warm-up and
replays the Disk ROM's second-stage call, so the first observation is
the result of the boot-sector handoff. A Keeper can step `masc_msx_step`
from there; a successful load does not establish game compatibility.
The observation names the image under `disk`;
`cartridge` reads null while a disk runs.

There is no fetch script for disks: a commercial `.dsk` is the operator's
own image, the same responsibility line as any file placed in `carts/`
beyond the pinned table below.

## Open-source cartridges

`scripts/msx-fetch-homebrew-carts.sh` fills the inventory with games whose
authors publish them under a licence that permits redistribution. Each entry
is pinned to one release and one SHA-256; the script downloads from the
author's release page, verifies the digest, and refuses a file that differs.

| Cartridge | Version | Licence | Author |
|---|---|---|---|
| `xspelunker.rom` | 1.4.3 | GPL-3.0 | Santiago Ontañón, [santiontanon/xspelunker](https://github.com/santiontanon/xspelunker) |
| `tales-of-popolon.rom` | 1.3.1 | GPL-3.0 | Santiago Ontañón, [santiontanon/talesofpopolon](https://github.com/santiontanon/talesofpopolon) |
| `transball.rom` | 1.3.2 | GPL-3.0 | Santiago Ontañón, [santiontanon/transballmsx](https://github.com/santiontanon/transballmsx) |
| `noborunoca.rom` | 1.0.2 | MIT | h1romas4, [h1romas4/noborunoca](https://github.com/h1romas4/noborunoca) |

```bash
scripts/msx-fetch-homebrew-carts.sh --base-path /path/to/project
scripts/msx-fetch-homebrew-carts.sh --list      # the pinned table
scripts/msx-fetch-homebrew-carts.sh --dry-run   # what would be fetched
```

A file already present with the pinned digest is left alone, so the script
is safe to rerun. It never fetches a commercial ROM image. Anything else an
operator places in `carts/` is the operator's own responsibility.

XRacing (GPL-3.0) and Westen House (Apache-2.0) by the same author are
not in the pinned, verified inventory. Their compatibility is unverified.

## Checked

On 2026-09-08 each of the four images was booted for 400 frames on the
`ocaml-msx` boot harness (`boot.exe --roms roms/cbios --cart <image>
--frames 400`) with C-BIOS 0.29a. NOBORUNOCA reached its title screen;
the three Brain Games titles were still on the publisher's splash at frame
400, which is where they are at that point on real hardware too.

## Sangokushi II compatibility boundary

The 2026-09-08 investigation reproduced an opening sequence followed by a
failed file open and a terminal `PC=01a7` loop on the existing core. The disk
contained `MUSIC.CIM`, which the same run had already opened earlier. At the
later failure, the filename began with the preceding `RET` instruction byte.
A CPU write trace then showed the original file loaded correctly, followed
by the game restoring its code from VRAM. The VDP read buffer returned the
first byte twice, shifting the restored RAM contents. The filename pointer
and disk file were correct; replacing the image or normalizing the malformed
filename would conceal the actual VRAM read defect. [ocaml-msx PR #15](https://github.com/jeong-sik/ocaml-msx/pull/15) corrects the
prefetch sequence; gameplay recovery still needs a replay on that binary.

The mapper pin from MASC PR #34167 was already included in server source
`5ebfc257c55a6a771ace0ab412051a3d5e5cce44`; the older “redeploy pending”
report must not be used as current deployment status.

Campaign acceptance still requires readable interactive menus, starting a
scenario, taking turns, completing a battle, saving progress, restarting and
restoring that progress, and an observed ending. Record source/binary identity,
image and BIOS hashes, frame-numbered inputs and screenshots at these stages.
The current in-memory machine and input ledger are not a persistent save:
reloading/ejecting replaces it, and the core's save-state API is unimplemented.
