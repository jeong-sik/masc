# One rendering of a restored frozen Librarian question

Base: local `b69de3bc93f9d22e9469162ac3564686edee895b` (PR #52511's tree,
remote head `4020118998ec9ed05f8ba5dd906643c7db83bb31`).

Previously, ordinary restoration built its substitutions and prompt, then
the complete public validator built them again. History request decode then
ran that validator once more. A restored frozen question therefore built the
same large inputs three times. Floor restore/decode repeated this work too.

The candidate keeps field/schema/render checks in shared private functions.
Internal factories pass the rendering they just computed to those checks.
Public validators still reconstruct the expected substitutions and prompt
when given a potentially modified record. The private History source-binding
check follows successful restoration and retained prompt-hash verification;
it does not render it again. Floor creation still fully validates the
publicly supplied step; floor decode uses its already validated restoration.
Physical owner/source/link checks, error ordering and counterpart effect
policy remain in place. No input format, cache, current-prompt lookup or
state/cursor behavior changes.

## Validation

The three changed production implementations typed directly against prebuilt
dependencies and their unchanged public signatures using OCaml 5.5.2 with
fatal warnings 4/8/32/69. [typing.json](typing.json) records the results.
No Dune build, project link or full regression was run.

The source-extracted control-flow probe compares baseline/candidate ordinary
restore, public record validation and floor restoration/context validation.
All 30 successful/error results match. Renderer/input/schema ports are
deterministic fixtures: this is not a production rendering or provider test.
For its 12MB synthetic input, ordinary restoration invokes materialization
twice before and once after; allocation is 153,559,096 -> 76,780,448 bytes.
Single-run CPU timings are retained in [results.json](results.json) and do not
establish a speedup. The full History decode's three-to-one count follows its
inspected call sites; the probe does not execute that decode.

Replay with the project's OCaml/findlib/Yojson toolchain:

```sh
python3 docs/evidence/librarian-single-render-20261116/probe.py \
  --source-root . --baseline e0e819e29968366c1dffb59ad625ba4e17d4ac22 \
  --output artifacts/single-render-replay
```

The publicly reachable baseline has the same Runtime source as the stack
parent. Data is synthetic; source SHA-256s
are recorded. The production preparation regression adds unchanged frozen
bytes, invalid captured fields, retained prompt-digest checks and floor
working-context/carried-state cases. It was parsed but not executed.
Installed-server CPU/RSS recovery and the preflight ancestry-walk cost are
separate unverified work.
