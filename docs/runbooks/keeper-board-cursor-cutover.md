# Keeper Board cursor cutover

After installing the candidate binaries, but before starting or restarting
MASC against an existing workspace, run the read-only gate:

```sh
masc-keeper-board-cursor-cutover-check --base-path /path/to/workspace
```

The command discovers canonical Keeper metadata, validates every metadata row,
and asks the production reaction-ledger reader for each Keeper's current-
generation Board cursor. It exits `0` only when every registered Keeper is
ready. Missing, malformed, or unreadable state exits `2`; the command never
writes or repairs runtime state.

A workspace with no registered Keeper metadata fails closed as well. A
genuinely new workspace has no pre-existing cursor state to cut over and does
not need this gate. Reset or recreate runtime state only through a separately
approved operator action.
