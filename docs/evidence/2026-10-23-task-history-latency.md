# Task history latency, 2026-10-23

## Observed failure

The installed server (`dd72436925365a0028981c8bbb5b9a1e52ef1877`)
returned Task `task-2497`'s seven history observations in 10.930158 seconds
with limit 50, and 12.943751 seconds with the TUI's limit 59 and original
workspace preconditions. Both replies exhausted the observed prefix.
The installed TUI logged a 10.002-second timeout for the same limit-59 read.
The adjacent full-health observation returned in 0.002502 seconds; its
60-second scheduler window reported no stalls. These are separate samples,
not a general server-load diagnosis.

## Reader probe

The exact reader functions from baseline
`c56363ce9813fc563f3bf051ab612bcbc39e897d` and candidate source commit
`928c13231cf7812255c121d4feaae9ff445e05bc` were compiled into a standalone
native probe using OCaml 5.5.1, Yojson and `digestif.c`. Each processed the
same captured byte ceilings from 38 live dated source files. The probe
parsed each nonblank JSON row and hashed every row with its physical offset.

| Reader | Bytes | Rows | Range reads | Elapsed seconds | CPU seconds |
|---|---:|---:|---:|---:|---:|
| Baseline | 254722443 | 467554 | 62208 | 5.942795 | 5.872638 |
| Candidate | 254722443 | 467554 | 3905 | 3.244220 | 3.236958 |

Both produced SHA-256
`89db7face3f6deb78ae962fdff9a270e8aa621433842221aa1e722ca83e0bfde`.
The probe used POSIX open/seek/read/close as the range adapter. It did not
execute production ownership checks, canonical event validation, the Eio
pool, HTTP transport, or TUI rendering. Baseline ran before candidate in one
pair; these timings demonstrate this reader probe, not deployed API latency.
The source still scans unrelated rows for sparse histories; this change
does not introduce an index or claim asymptotically faster lookup.

The same probe passed independent physical-row/byte-offset expectations for
empty input, blank rows, newline on a block boundary, a row spanning more
than three blocks, UTF-8, forward continuation anchors and changed anchors.

## Validation scope

- Both changed production modules passed focused `ocamlfind ocamlc -c`
  typechecks against existing compiled dependency interfaces. This is not
  a clean repository build.
- Changed OCaml sources/interfaces and the extended integration test passed
  compiler parsing; `git diff --check` passed.
- The added `test_h2_journal` scenario exercises actual history pages for
  cross-block rows, physical offsets, anchors, append exclusion, ordered
  corruption failures and unfinished captured tails. It has not been run
  locally; no local Dune build was performed.
- Independent source review found no P0/P1/P2 issues in either layer. It is
  separate from GitHub approval, CI, merge and installed-runtime verification.
- The live server/TUI were not replaced. Candidate server, live API and
  visible TUI timings remain unverified.

## Review follow-up

Run `39912714570`, on the earlier stack top
`e645a96c60d354124466e7bf0cac993ee66156c5`, compiled its selected target but
failed during test initialization: `masc_browser_act`'s `latitude.minimum`
was encoded as an integer where the schema requires a float. No history
scenario ran, so this run is neither a history regression nor a passing
history test. The current rebased stack includes the independent float-bound
repair `fa641e57e2a` from main.

The upper-layer review requested evidence that an unanswered read really
stops when the owner leaves. `test_tui_io_domain` now sends a real loopback
GET without an overall timeout, waits for the server to receive it without
answering, then cancels the caller. It awaits the actual request worker's
cleanup, checks that the pool's inflight count returns to its original
value, and checks a subsequent request on the same origin/domain. The full
test module passes focused typechecking against existing dependency
interfaces. A focused native relink of that test against existing local
production archives then passed all seven IO-domain scenarios, including
the new unanswered-GET case (Alcotest run `YQVE5FW6`, 0.163 seconds).
The first attempt could not bind the loopback socket inside the filesystem/
network sandbox; rerunning the same executable with loopback access passed.
This is not a clean candidate build or exact-head CI result. Minimal CI run
`39915980810` was separately requested on source head
`f179140e7f67b455aa4ca0f66df551a74be1a809` for `test_h2_journal` and
`test_tui_io_domain`. It stopped during compilation at the unrelated Plugin
`current_category` fragile match. The independent repair is #45426,
merged as `123f2f821a60f5c6d2250d6dbea7f049aec1faae`; the whole history
stack must include that fix before rerunning these selected scenarios.

This checks withdrawal of an owned observation, not server progress while
the operator remains on the same view. An unanswered peer stays pending
until withdrawal, transport failure or shutdown. An idle/first-byte timer
would also reject a legitimate scan that has not produced response bytes.
The independent reader probe above is not an end-to-end claim that every
production history scan now finishes below ten seconds.
