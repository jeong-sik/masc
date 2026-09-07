# Bounded Firefox upload bytes

The former single `od` response exceeded Process_eio's 8 MiB head plus 256 KiB
tail capture. BSD od emits more than four characters per input byte, so even
2 MiB input chunks could exceed the retained head. A second prefix cap could
also hide the capture truncation marker.

Production upload reads now use chunks derived from the capture head divided
by eight, preserving the complete process capture for strict hex decoding.
The global process capture caps remain unchanged. Each command bounds the
source read with `od -j offset -N count`; the aggregate includes the existing
extra-byte sentinel before deciding whether the file fits the 16 MiB limit.

`probe.log` records the production upload code and actual Exec_buffer running
in the OCaml interpreter with real POSIX od. The transport adapter uses the
same head/tail caps as Process_eio. It demonstrates the old retention failure,
byte-for-byte successful staging at 0, 3 MiB + 17 bytes, and exactly 16 MiB,
rejection at 16 MiB + 1 byte, and preservation of missing/skip-past-EOF errors.
This does not exercise container or remote authorization; existing Keeper
path tests own that boundary. `sources.json` identifies the measured source.

Browser Host Proof runs the same probe. Reproduce without building MASC:

```sh
python3 scripts/probe-browser-upload-bytes.py --out /path/to/evidence
```
