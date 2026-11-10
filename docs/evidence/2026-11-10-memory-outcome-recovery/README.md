# Memory outcome recovery and attention evidence

This bundle records source review and a local Dashboard component reproduction.
It does not establish deployment or recovery of the two evidence-absent original
requests discussed in [#50828](https://github.com/jeong-sik/masc/issues/50828).

## Source identity

The recovery layer is commit `612fa55c013c4d21d301746885bdaefb7c9ea4af`; its
changelog-only successor is `1ed202aed3b37d6a9bc8618a2b780bfc2e0942d0`.
The attention layer was reviewed against that successor. At capture time its
tracked 28-file binary diff had SHA-256
`1c2a00a15a165753f9f12c4198dc2c645aaf983f8fa1d865eef670a3c8c7a6b5`;
the new recovery guide had SHA-256
`167634bbf33a772d7f5ead98e2d20847e2d06c1ed632a645477f4ced800c8763`.
[source-manifest.json](source-manifest.json) lists the corresponding 29 source
files and their content digests. These coordinates exclude this evidence bundle
and later changelog-only commits.

Two independent non-author sessions reviewed each source layer. The attention
review found and verified responses for old TUI rows clearing current attention,
hidden refresh failures, and reversed Dashboard request completion. Both final
source verdicts found no remaining P0/P1/P2 in the recorded source snapshot.
These session verdicts are not formal GitHub account approvals.

## Checks

- Focused Dashboard Vitest: API 98, component 21 and existing async-resource 23
  tests passed, 142 total. Component cases include four reversed completion
  orders and two completions after unmount.
- Dashboard TypeScript `--noEmit`: exit 0.
- All 20 changed attention-layer OCaml files parsed with OCaml 5.5.1 using
  `ocamlc -stop-after parsing FILE`; both changed Python files passed `ast.parse`.
  [final-syntax.json](final-syntax.json) retains each parser result. The project
  toolchain is 5.5.2: this check is syntax only, not a typecheck or native test.
- `git diff --check`: exit 0 for the reviewed source snapshot.

The Dashboard checks ran from `dashboard/` with the commands below. Their output
was observed in the implementation session's tool transcript; no separate raw
Vitest or TypeScript output file was retained.

```sh
./node_modules/.bin/vitest run --config vitest.config.ts --no-file-parallelism --maxWorkers=1 src/components/memory/keeper-memory-health.test.ts src/api/dashboard-misc.test.ts src/lib/async-state.test.ts
./node_modules/.bin/tsc --noEmit
```

No Dune build, native OCaml fixture execution, CI run, install or server restart
was performed for these observations.

## Component captures

The local Vite fixture imported the changed `KeeperMemoryHealth` component and
strict API decoder directly from source. It used the API test payload constructor
with synthetic keeper/request IDs, one durable `missing_after_dispatch`, and one
independent admission `outcome_unknown`. The fixture intercepted its Memory
health endpoint; all other `/api/` requests were blocked. It did not contact the
operating MASC server. The fixed sample observation dates are not runtime ages.

- [attention.png](attention.png): attention count 2, separate stopped count 0,
  both row badges and expandable typed pending/admission evidence.
- [refresh-failure.png](refresh-failure.png): a synthetic transport failure is
  visible while the last accepted attention count and observation time remain.

Both captures were visually inspected. They are original fixture captures, not
sanitized operating-server screenshots. They do not verify the installed TUI,
production CSS bundle, worker RPC, provider calls, Memory commits or cursor ACKs.

The prior silent-wait class and proven-terminal publication gap are addressed by
these source changes. Evidence-absent dispatched requests still need a separate
durable per-original fence/disposition contract; elapsed time or repeated sync
does not authorize replay.
