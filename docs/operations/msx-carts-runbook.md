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

A plain cartridge image of 16 KB or 32 KB. The machine maps it at `0x4000`
in slot 2, the address C-BIOS checks for the `AB` header, and it has no
MegaROM mapper. A 48 KB image or a mapper-based one does not run.

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

XRacing (GPL-3.0) and Westen House (Apache-2.0) by the same author are 48 KB
images and are left out for the reason above, not for licensing.

## Checked

On 2026-09-08 each of the four images was booted for 400 frames on the
`ocaml-msx` boot harness (`boot.exe --roms roms/cbios --cart <image>
--frames 400`) with C-BIOS 0.29a. NOBORUNOCA reached its title screen;
the three Brain Games titles were still on the publisher's splash at frame
400, which is where they are at that point on real hardware too.
