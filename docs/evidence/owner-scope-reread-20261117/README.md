# Execution-scope body reuse within one discovery

`Admission_owner.discover` originally loaded the complete execution scope inside
`Parts.discover` and again immediately after it. The second load still needs
fresh metadata, progress and body-integrity checks. Repeating canonical JSON
parsing and serialization for the same immutable request is avoidable.

The new opaque observation holds immutable bindings and already verified request
ASTs for this one pair of reads. Rereading inventories the original store/scope
again, drops hints absent from or bound differently in that inventory, and uses
the existing atomic record/body read for every listed record. It hashes every
body once. Only a complete immutable-binding match reuses an AST; new or changed
bindings run the full original body validator. The final listed-identity check
still follows body validation. Current progress is returned as each record is
read. This remains a sequence of fresh observations, not an atomic scope snapshot
or authority for effects.

Hints are consumed with `Atomic.exchange` before I/O. Failure or cancellation
cannot leave them in the observation. A subsequent or concurrent caller without
the hints performs ordinary full reads; no retry gate is introduced. No prior
owner progress or raw body-byte field is retained by the hint. The hints do keep
the canonical ASTs alive until consumption. This is a local value, without a
global registry, time budget, or cross-discovery cache.

## Captured native results

The baseline is `ea0b8d1fd284fad784557373fd82e8565a774b10`. The fixture compiles
the complete baseline and candidate Owner implementations with the complete
unchanged Store implementation. It adds explicit module aliases, atomic counters
and weak witnesses, as shown in [replay.py](replay.py). Digesting, parsing,
canonicalization, serialization, owned-file I/O and Store serialization are the
actual implementations. No decoder or Store interface is substituted.

[observed.json](observed.json) records 83 passing assertions. An unchanged pair
performs two atomic Store record/body reads and two body SHA checks in both
versions; body JSON parsing falls from two to one. The AST is physically shared.
New/changed binding and body cases hash and parse once per fresh body. The counts
are instrumented call counts, not OS syscall counts or elapsed-time estimates.

| Synthetic payload | Baseline pair allocated | Observation/reread allocated |
| --- | ---: | ---: |
| 16 B | 170,672 B | 169,104 B |
| 4 KiB | 236,208 B | 210,032 B |
| 256 KiB | 4,105,424 B | 2,530,960 B |

Six explicitly sequenced alternating rounds each timed 12 unchanged pairs at
256 KiB using process user+system CPU time. Baseline trials ranged from
0.116059–0.175891 s; candidate trials ranged from 0.084256–0.100022 s. The median
paired candidate/baseline ratio was 0.7326. These are local, counter-instrumented
native read-pair measurements, including real temporary-file I/O and any GC
during the timed loop. No Eio scheduler or CPU pool is installed, so the existing
standalone inline fallback runs this work. Explicit full GCs for lifetime checks
run only in the disposable fixture and outside the timed loops. These results do
not establish server CPU, latency or RSS recovery.

Error/race controls include missing, unreadable and corrupt bodies; malformed,
noncanonical and duplicate-key bodies with matching digests; changed bindings;
new records; removed records; removal or mutation after inventory; body error
precedence over listed-identity mismatch; latest progress; a spent observation;
and two real systhreads sharing one observation. Cancellation is an explicit
`Eio.Cancel.Cancelled` exception at the real reread's post-inventory hook, not an
asynchronous cancellation of filesystem I/O.

## Lifetime cost and controls

The first ASTs now remain reachable during the later historical replacement
checks in Parts. The baseline can release them before that interval. With an
independent synthetic 1,048,968 B work root, a 256 KiB payload adds 263,160 B to
the union of reachable roots during this gap; a 4 KiB payload adds 5,112 B.
This is a disclosed retention cost, not a lower-peak-memory claim. The work root
models overlapping work; the fixture does not execute Parts' historical proof.

Weak witnesses show raw body bytes and previous owner progress clear while the
observation remains. The AST clears after the actual reread returns and its
result is discarded. A consumed observation occupies 440 reachable bytes in
this fixture, including its Store/scope fields; this is not its pre-consumption
size. Cancellation also releases the consumed hint after the frame returns.

For four 64 KiB originals, both all-binding-changed and retired-plus-new controls
show zero old ASTs at the first and every later atomic-read boundary. Fresh AST
counts rise from zero to three as reads proceed. Their unions are sampled
reachable-root sizes, not peak heap or RSS. The prefilter therefore prevents
these unused old ASTs overlapping the whole new inventory. Unchanged matching
hints still live through the reread and are shared by its outputs.

## Source and dependency boundaries

[manifest.json](manifest.json) binds whole baseline/candidate source bytes and
the retained fixture/output files. [typing.json](typing.json) records whole
actual Owner MLI/ML typing under their real wrapped module names with fatal
warnings 4/8/32/69, and complete isolated Store/Owner typing. The isolated Owner
MLI receipt precedes a documentation-only edit; the exact final MLI is covered
by the real wrapped typing receipt. These are direct OCaml 5.5.2 compilations
against existing CMIs and native archives, not a product build. The native graph
has 324 prebuilt `.cmxa` descriptors and 323 existing companion `.a` files. Its
inventory digest identifies captured inputs; it does not prove their sources
equal the tested Git revision. The complete tested Owner/Store bodies are
separately source-bound.

The consumer layer's separate caller proof records source review and final-byte
parsing. Its actual wrapped Parts MLI
typing stopped because the existing Capture CMI and fresh Owner CMI make
inconsistent assumptions about the Owner interface. No replacement interface or
large dependency rebuild was used. There was no full MASC integration execution,
Dune build, CI run, live request, provider execution or runtime mutation.

## Replay

The helper was replayed successfully with the existing native dependency graph.
It writes only to a new explicit `artifacts/` output and its own temporary Store
roots. The executable basename remains `test_scope.exe`, and the HOME-write
escape is removed. A marker and the active HOME guard are asserted before tests.

```sh
python3 docs/evidence/owner-scope-reread-20261117/replay.py \
  --repo "$PWD" --out "$PWD/artifacts/owner-scope-replay" \
  --compile-prefix /path/to/existing-compile-prefix.json \
  --link-command /path/to/existing-native-link-command.json
```

The compile prefix is JSON argv beginning with the matching `ocamlopt` and
containing existing dependency include paths, `-no-alias-deps`, `-open Masc`,
and fatal warnings 4/8/32/69. The link command is JSON argv for that existing
native graph, ending with the five fixture units `metrics`, `store_scope_test`,
`owner_before`, `owner_scope_test`, `test_scope`. The helper replaces that tail
and output filename. Dependencies must already exist; it neither resolves nor
builds them. Recorded argv digests identify the local captures, not a portable
installation recipe. All input records and body content in this bundle are
disposable synthetic data.
