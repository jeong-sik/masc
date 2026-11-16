# Tools runtime projection without an unused ledger scan

Tools refreshes rebuild their full runtime projection. That projection previously
also read recent Keeper reaction-ledger JSONL rows, although no repository Tools
consumer reads the resulting `keeper_reaction_ledger` field. The retained old
PID22599 allocation window attributed an estimated 386,399,992 additional bytes
to the ledger's recent-row path. That historical allocation observation does not
establish refresh frequency, CPU share or an improvement in an installed server.

This change intentionally removes only
`runtime_resolution.keeper_reaction_ledger` from Tools responses. It skips the
read instead of filtering the JSON after reading. Full shell runtime resolution
and full health still compute their ledger summaries, including strict malformed
row/quarantine and current pending-queue authority. The ledger producer, parser
and summary code are unchanged.

The private full fleet builder is shared by fixed full and Tools getters. Both
keep phase-before-metadata observation, the full paused details and the boot
path's bootable set, including profile-error handling. The runtime builder is
also shared: a private supplier thunk runs at the original tail position after
the same full build/path/git/diagnostic/warning work. Tools chooses its fixed
getter. The existing light view has different paused-detail and bootable behavior
and is not substituted. No public boolean/mode, cache, TTL or last value is added.
Current/Reuse selection, timing, warming/error classification, selected Keeper
resolution and final live decorations are unchanged.

## Consumer and contract scope

The audit covered production references in `lib`, `bin`, `dashboard/src`, scripts
and the relevant public interfaces/design documents at baseline
`607419c653251c46470eabee1b71f0ac8bd61b48`. Focal consumer hashes are retained in
[result.json](result.json).

| Consumer | Runtime data it reads |
| --- | --- |
| Tools API/resource/panel | Raw runtime response; full paths, mismatch/warnings, diagnostics, build/deployment, Keeper runtime, FD/disk and fleet fiber count. No ledger access. |
| Schedule and Keeper surface clients | Tool inventory, waiting inventory and effective surface; no ledger access. |
| TUI Tools loader/decoder | `runtime_resolution.disk_observation`; inventory, usage and cleanup projections. |
| `keeper-waiting-inventory.sh` | Deployment status, binary commit and mismatch fields. |
| Skill workload harnesses and latency probe | Effective tool/skill observations or response captures/timing; no runtime-ledger access. |
| Shell store/normalizer | Normalizes ledger into `fleet_safety.keeper_reaction_ledger`; this separate full-shell producer retains the field. |

The generic runtime normalizer is called by the shell store, not the Tools API.
`fetchDashboardTools` preserves raw runtime JSON and normalizes only tool and
waiting inventory. The Tools response type does not declare the removed direct
field. The full-shell ledger contract in `server_routes_http_runtime.mli` remains
unchanged; the new fixed Tools getter and Tools response contract document the
wire-field removal. The cleanup design text is updated to preserve its disk
contract without calling Tools the full-shell projection.

This inventory covers repository consumers. Unknown external clients cannot be
ruled out; the wire-field removal is intentional and has no compatibility flag.

## Executed evidence

OCaml5.5.2, arm64. The replay compiles exact baseline and candidate source bodies:
fleet base/full builders, the complete full runtime builder and the complete
Tools producer, including cache selection and final decoration. Effect ports are
explicit deterministic fixtures in [ports.ml](ports.ml). The assertions are in
[cases.ml](cases.ml), and source/helper hashes bind the retained result.

- **758 native assertions passed.** Full runtime JSON and effect order match the
  baseline exactly. Tools JSON matches baseline JSON with only the ledger key
  removed, including key order and values. Five scenarios cover ordinary data,
  warnings/commit drift, unknown binary identity, no server state and an unread
  census marker.
- A 180-case matrix covers Current/Reuse, global/selected/missing Keeper,
  computed/warming/error cache ports and timing present/absent. The Tools leaf
  count is zero throughout. Nonempty paused details and a deliberately different
  meta-scan bootable set catch substitution of the light view. Full fleet effect
  order matches after removing only the ledger event.
- A ledger leaf that raises is reached by baseline Tools and by the retained
  full runtime getter; candidate Tools succeeds without calling it. This detects
  a scan followed by output filtering. The unchanged actual full-health ledger
  section also executes with one leaf call. This section check is not execution
  of the complete full-health endpoint.
- **Six actual-source type checks passed**, with fatal warnings4/8/32/69: the
  interfaces and complete implementations of health_fleet, the runtime facade
  and runtime_info. Fresh changed `masc_server` CMIs form the actual dependency
  chain in an isolated directory; native fixture CMIs cannot shadow them.
- The actual metadata-once/boot-path regressions now cover the fixed Tools
  getter. The existing pending-cache Current test checks the public Tools
  producer's retained full fields and omitted ledger. Both complete regression
  files parse, but their full typing is blocked at both baseline and candidate
  by prebuilt dependencies disagreeing over `Workspace_utils_paths_backend`.
  Existing whole-file warning4 diagnostics also remain. These regressions were
  not executed and are not reported as typed or passing.
- The actual paused-detail regression compares every static field after removing
  only each detail's `paused_elapsed_sec`. Both observations must retain nonempty
  details and independently report a finite, nonnegative elapsed value. It does
  not compare two wall-clock ages for equality. The exact updated local predicate
  passed **10 native fixture checks**, including distinct valid ages, zero,
  invalid/missing ages and preservation of static differences. This is separate
  from execution of the whole actual regression file. Its parse and blocked
  typing receipt were refreshed; the unchanged 758-case suite and six production
  type checks were retained without rerunning them.

The native ports replace filesystem, clock, build, diagnostics, metadata/profile,
metrics, scheduler/cache and ledger effects. The leaf is a frozen small summary;
it does not parse actual JSONL. These checks establish source-body behavior under
those ports, not real cache freshness, disk authority or production latency.
Actual full-shell/full-health ledger authority is preserved by unchanged source
and the fixed full getter; no live workspace was read to execute this proof.

## Bounded output cost

The fixture's serialized Tools envelope shrinks from 1,892 to 1,771 bytes. Over
100 serialized Current reads, baseline invokes the frozen ledger leaf100 times;
candidate invokes it zero times. Allocation/CPU observations are retained in
`result.json`. The fixture excludes the real JSONL work; its near-equal CPU times
are not an estimate of runtime savings. No claim is made about total CPU/RSS,
refresh frequency or installed behavior.

## Reproduce

With OCaml5.5.2 and Yojson installed, provide the existing compatible project
compiler-prefix JSON. Missing/incompatible dependency artifacts do not trigger a
build fallback.

```sh
python3 docs/evidence/tools-runtime-projection-20261116/replay.py \
  --repo . --base 607419c653251c46470eabee1b71f0ac8bd61b48 \
  --opam-prefix /path/to/ocaml-5.5.2-prefix \
  --cmi-prefix /path/to/existing/command-prefix.json \
  --out artifacts/tools-runtime-projection-20261116/reproduction
```

Use a fresh output directory. Retained local execution is
`artifacts/tools-runtime-projection-20261116/run-7-final`. No Dune, dependency/full
build, full test link, CI, runtime/provider/cursor/capture request, install or
restart was performed.

The test-only elapsed-age correction is recorded in
`artifacts/tools-runtime-projection-20261116/paused-regression-fix-2`. To reproduce
that bounded refresh, run `refresh_paused_regression.py` with the same `--repo`,
`--opam-prefix` and `--cmi-prefix`, plus `--prior-result` naming the preceding
receipt, `--prior-typing` naming its actual-typing directory and `--out` naming a
new artifacts directory. It refuses changed original source/helper bytes. A fresh
full `replay.py` run uses the updated actual regression as well.
