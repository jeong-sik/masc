# Intermediate delivery speech boundary

Base: `ca72565034d8dc6cde91e33f40b699ef6ac16116`.

Canonical `Operation_checkpoint` and `Operation_native` deliveries with a
`Terminal_result` slot were classified as root reply output. The slot ends that
delivery; it does not establish completion of the root operation. History now
retains the checkpoint or native continuation identity in `Intermediate_speech`.
The executable projects these rows as progress and excludes them from latest
reply selection for `/copy`. Original content is retained. Root operation and
unknown speech classification remain unchanged; this change does not establish
their terminal authority.

## Observed decision measurement

Isolated artifacts: `/tmp/masc-tui-intermediate-speech-20261012/`, containing
`parent.ml`, `current.ml`, `parent.log`, and `current.log`.

The harness copies the production provenance decision, phase mapping arms, and
latest-reply fold. Its surroundings supply minimal payload types and already
decoded provenance; the provenance field decoder is an identity stub.

- Parent: exit 1, `FAIL: intermediate delivery classified as root reply`.
- Current: exit 0, `PASS: checkpoint/native boundary identity and body; progress phase; copy refusal; root result unchanged`.

The parent harness warning about an unhandled `Intermediate_speech` constructor
comes from the harness supplying the new type to old consumer code. The parent
source did not declare that constructor; this warning is not evidence of a
parent compilation failure.

Six changed OCaml files passed syntax-only parsing. `git diff --check` passed.
The registered canonical wire fixture has not run. JSON decoding, whole history
ingestion, full typechecking, clipboard side effects, rendering, installed
runtime, screenshots, CI, approval and merge are unverified.

## Refresh boundary

On resume, the eight-file source unit was still uncommitted on
`fix/tui-intermediate-speech-boundary-20261012`. Remote fetch failed because
`github.com` could not be resolved. Cached `origin/main` is not current remote
compatibility evidence; re-read the remote head and overlapping changes before
publication or merge.
