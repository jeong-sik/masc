# Runtime draft races after parent integration

Original head `487023eb3c91e9d91e3aaabb5dd9f3fa6b8f2d8a` was repaired locally
and checkpointed as `7984f8788c`. This candidate really merges published parent
`0b541f32bdcc0e5483fbac8248904cf05bf2ac58` (#41153).

## Repairs and integration

- A per-session commit notification lets still-mounted Settings refresh its four
  local runtime snapshots after navigation unmounts the editor. Its subscription
  rejects obsolete authority/generation callbacks; stale child callbacks remain
  suppressed.
- A raw read captures source generation and cannot adopt a superseded response.
  After releasing its busy phase it resumes clean automatic reads; dirty drafts
  still require explicit comparison.
- Uncertain write results block another write across remount. Comparison and
  revision adoption retain separate admission so operator recovery remains usable.
- Parent mandatory assignment revision and API contract are retained. The one
  source conflict was the parent's imperative replacement projection refresh
  versus session adoption. Session adoption creates a new config identity, hiding
  old projections immediately and triggering a fresh read. The retained regression
  now directly checks absence of old controls while that read is held and the new
  lane candidates after release, plus draft/revision/save behavior.

## Executed evidence

On the integrated candidate, the two affected component suites passed 138 tests;
whole Dashboard TypeScript and changed-file ESLint passed with no diagnostics.
The tests use synthetic API fixtures, not a running backend. Logs retain exact
/tmp source bytes, including trailing blank lines. Raw evidence therefore has
EOF whitespace warnings; these do not change the recorded execution results.

Before parent integration, replacing the three production files with original
head bytes made all three new race regressions fail (`red.log`); restoring the
repair made them pass (`green.log`). Separately removing only the clean-read
continuation produced one failure and restoring it produced one pass. These RED
runs prove the repair locally before parent propagation, not a new integrated
artifact or release result. No product logic changed in the merge resolution.

```sh
# From dashboard
pnpm test src/components/runtime-toml-editor.test.ts src/components/settings-surface.test.ts
pnpm exec tsc --noEmit --pretty false
pnpm exec eslint src/lib/runtime-toml-session.ts src/components/runtime-toml-editor.ts src/components/runtime-toml-editor.test.ts src/components/settings-surface.ts src/components/settings-surface.test.ts
```

No native build, live runtime, browser rerun, full suite, CI, Full RC, deployment
or release is claimed. Historical evidence stays byte-for-byte unchanged. Descendant
#41172 must converge its duplicate generation guard and connect activity commits
to parent-owned Settings refresh; its own observation signal does not by itself
notify this raw-file session's commit subscribers.
