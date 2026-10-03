# Memory state fixture baseline

The PNG exports actual recorded PTY screen cells from the installed binary (colors are not retained). This is BEFORE the repair: a drained Librarian with three historical failures still shows memory degraded, and 256 KiB of stored JSON is displayed as about 77k estimated tokens. The companion failed-now fixture shows an error-state pass with a zero counter reported as memory ok.

`before-frames.json` contains all four original ANSI frames at 80/140 columns and their binary SHA-256. The installed binary source SHA is unknown and is not inferred from repository HEAD. The harness source is recorded separately. These captures reproduce the existing issue; they do not prove the repaired candidate runs. Candidate PTY assertions and OCaml regression cases are added separately. No local Dune build or new-head execution was performed.
