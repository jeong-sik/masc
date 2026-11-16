# Missing path-kind observations

`Fs_compat.exact_path_kind` still calls the supplied Eio filesystem's `stat`
provider on every observation. It now handles that provider's typed `Not_found`
before constructing the context that `Eio.Path.kind` would immediately discard.
Other Eio errors retain the same `examining` context, original backend backtrace
and existing `with_io` conversion to `Sys_error`. The public interface, Unix
fallback, follow flag and directory discovery boundary are unchanged.

## Source and executed checks

Base: `8269ef535d57e62f6a5913d9651802fd158a49e7`.
Tested source commit: `f573d6a8b10d1e0e36b581d17bde014cd9aeee54`.
The product file SHA-256 is
`815eceaf6d4dd0187f17dbfce29af6fc545674ea3f15914a5a4cbe04c3c5d05d`.
`results.json` binds the source, interface, cases and executed replay helper by
hash; later import or evidence commits can change the head without changing those
product bytes.

The complete actual 456-line implementation was ascribed against its actual
158-line `.mli` with OCaml 5.5.2. Warnings 4, 8, 32 and 69 were fatal. Typing
returned 0 against existing project dependency CMIs. Findlib reported its existing
`mtime.clock.os` deprecation notice. Dependencies were not rebuilt and the complete
MASC module was not linked or run.

The executed portable helper extracts both complete path-kind functions, the
unchanged actual `with_io`, filesystem-selection and execution-context code, and
the unchanged directory-discovery body. Its native executable uses the installed
Eio filesystem implementation, not prebuilt MASC native archives. It passed 124
checks in 12 groups, including:

- Every Eio stat kind, both follow flags, and a virtual capability namespace whose
  provider result differs from native path lookup. Every observation makes one
  supplied-provider call.
- Typed absence with pre-existing context: one stat before and after; provider
  formatting calls change from one to zero.
- Identical rendered nonmissing `Sys_error`, retained existing context and the
  same first backend raise frame. The complete old/new call stacks naturally
  contain different adapter frames; they were not asserted byte-identical.
- Non-I/O exception identity, explicit cancellation identity and actual fiber
  cancellation during a suspended provider stat, with no formatting or retry.
- Real files, directories, FIFO, socket, links, dangling links, loops, missing
  parents, non-directory parents and denied parent search. Missing, creation and
  deletion remain visible on successive calls. The installed-global-fs
  systhread branch still uses the Unix fallback.
- Actual discovery-body results for external snapshot, WAL-only, quarantine-only
  and dangling entries, retaining a failing sibling's error alongside healthy
  owners. A present primary does not hide an unknown WAL or denied WAL/quarantine.

The exact new native regression body in `test/test_fs_compat.ml` also executed
successfully with its five Alcotest checks. Only its temporary-directory owner was
supplied by the standalone harness. This was not execution of the whole test
file or its normal executable.

Discovery's canonical-base, directory-layout and keeper-name parser ports are
synthetic in this fixture. All supplied names are valid and the base is an owned
temporary directory. The fixture proves its actual I/O/error-collection body on
those inputs, not production path canonicalization or name validation.

## Native measurements

Each round makes 9,000 adapter calls: 3,000 iterations over three paths. Three
rounds alternate before/after order. This run used Darwin arm64, OCaml 5.5.2,
native debug information and enabled OCaml backtrace recording for both versions.
`Gc.allocated_bytes` measures allocations in
the executing OCaml domain; it is not RSS, peak residency, retained heap or a
whole-process allocation census. CPU is process user plus system time from
`Unix.times`. All raw per-round numbers are retained in `results.json`.

| Input | Before allocation per round | Candidate allocation per round |
| --- | ---: | ---: |
| Three missing leaves | 43,681,696–43,682,304 B | 13,321,392–13,322,000 B |
| Present regular file, directory and link | 14,689,696–14,690,000 B | 14,689,392–14,690,304 B |

Missing-path allocation fell about 69.5% in this bounded fixture. CPU timings
overlapped: missing rounds were 0.112–0.122 s before and 0.104–0.124 s after.
This small fixture does not establish the application's total CPU or memory
gain. It does not attribute all previously sampled discovery allocation to this
formatting, or prove installed runtime recovery.

## Replay

The helper below was executed against the immutable tested source commit. It
requires OCaml 5.5.2, installed Eio/Yojson/Alcotest native libraries and a compatible
existing project build tree for the separate whole-module typing check. Missing
or incompatible artifacts fail; there is no build or download fallback.

```sh
python3 docs/evidence/fs-kind-absence-context-20261116/replay.py \
  --repo "$PWD" \
  --base 8269ef535d57e62f6a5913d9651802fd158a49e7 \
  --candidate HEAD \
  --build-root /path/to/existing/_build/default \
  --opam-prefix /path/to/ocaml-5.5.2-prefix \
  --out "$PWD/artifacts/fs-kind-replay" \
  --iterations 3000
```

`WORKTREE` is available as `--candidate` for an explicitly mutable development
run; the retained run used the commit above. New generated source, diagnostics and
results go to `--out`. No Dune invocation, project build, CI action, provider
request, live MASC query, install or restart ran for this evidence.
