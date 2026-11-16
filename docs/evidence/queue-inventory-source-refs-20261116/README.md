# Waiting queue source-reference hashing

When a waiting-inventory row is suppressed by grouping, its detail is no longer
constructed or hashed. An emitted schedule group calculates the queue-order
anchor's reference once and reuses it for that same member after sorting by due
time. Other members keep their own exact source reference and incarnation.

This bundle records a local source check of step 1. It contains no runtime capture,
allocation measurement, deployment proof or cross-observation snapshot cache.

## Source identity

The original run used main/base
`878ab909ada1cc485c609c313f1f9c61612c17bc` and local source commit
`20980cb353a79170f721052848a10bd61309cbfc`. The sole changed product file was
`lib/server_keeper_waiting_inventory.ml`, with blob
`4e27f8f32d0ec9800c74f5cae6c75291e43b214d` and SHA-256
`87f400ad692d8c3c49e082c971be234046010225e162f3e0986a51d5d53e3ae3`.
The public `.mli` was unchanged. `typing.json` records both source hashes.

The source commit may acquire a different ID when imported into a native stack.
Use the imported head as `--candidate`; the file blob and hashes above identify
the recorded production source independently of that history change. The helper
reads exact Git objects, not the working tree's product files.

## Recorded checks

The complete final 1,864-line implementation was ascribed against the actual
125-line public `.mli` and typed with OCaml 5.5.2 against existing dependency CMIs.
Warnings 4, 8, 32 and 69 were fatal. It returned exit 0 with empty stdout/stderr.
This checks the implementation/signature boundary against those CMIs; it does not
rebuild dependencies, link the full module or validate deployed inventory I/O.

The original standalone probe extracted the complete pure inventory row projection
before/after, the actual source-reference function body and pending-selection type.
It used existing production queue-encoder and SHA native archives, with a counter
around each source-reference call. It passed 21 inputs and 134 assertions, comparing
the complete serialized row JSON byte for byte and checking exact digest call
counts. All emitted anchor/member addresses were checked against the same
prebuilt encoder/SHA oracle and their own incarnation. Cases include:

- Empty and individual queues, suppressed Connector rows and bounded member IDs.
- Six schedule due-order permutations, a queue anchor that is not first by due
  time, equal due times and interleaved schedule groups.
- Duplicate arrival values, mixed Connector urgency, two incarnations of the
  same source and a repeated exact selection object.
- All three Board variants, whose public details retain only opaque address
  fields, plus mixed Board/schedule/Connector input.

Schedule groups of three changed six calls to three; eleven grouped Connector
items changed eleven calls to one. `results.json` retains every case's measured
call counts. Three unchanged grouping test bodies from
`test/test_tool_misc_coverage.ml` were also extracted and executed against the
candidate renderer. This was not execution of the whole test file or its normal
test executable.

The preserved `_build` **source copies** of the queue encoder and SHA module were
byte-equal to the selected base source. That establishes source-copy equality
only. No build receipt established that the existing native archives were built
from those copies. Matching copies do not prove archive build provenance. The
full implementation/signature typing result above is separate from this native
probe and has its own prebuilt-CMI limitation.

No Dune invocation, product build, CI dispatch/watch, live runtime query, install,
or allocation/latency measurement ran. These results do not quantify the fraction
of the incident's total memory/CPU cost that this change removes.

## Replay prerequisites and command

`replay.py` accepts paths as arguments and discovers existing CMIs, native objects,
archives and an enumerate-capable PPX driver. It never invokes Dune or rebuilds
project modules. It compiles a standalone probe and links existing archives.
It requires an already-populated build tree compatible with these sources, OCaml
5.5.2 and the installed dependencies named in the helper. Missing or incompatible
artifacts cause an error; there is no build or download fallback. Supply
`--ppx-driver` to select an existing driver explicitly if discovery is unsuitable.

From a checkout containing this evidence and the imported source:

```sh
python3 docs/evidence/queue-inventory-source-refs-20261116/replay.py \
  --repo "$PWD" \
  --base 878ab909ada1cc485c609c313f1f9c61612c17bc \
  --candidate HEAD \
  --build-root "$PWD/_build/default" \
  --opam-prefix /path/to/ocaml-5.5.2-prefix \
  --out "$PWD/artifacts/queue-source-ref-replay"
```

Outputs, generated source and diagnostics go to `--out`. A successful replay
prints the case/assertion/test counts and records the exact chosen source hashes,
typing result and source-copy observations there.

The portable helper was syntax-checked and its CLI help inspected during evidence
curation. It was **not replayed**: the recorded execution used its earlier local
harness. No new compilation or probe execution was performed during curation.
`cases.ml` is the unchanged case source used by that original run. The helper
re-extracts the actual existing grouping tests and source bodies from `--base`
and `--candidate` when explicitly invoked.
