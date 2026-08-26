# RFC-AC-022: Code-Smell Monotone-Decrease Ratchet

**Status**: Draft
**Date**: 2026-05-20
**Scope**: `.ci/code-smell-baseline.json`, `scripts/ci-code-smell-ratchet.sh`, `.github/workflows/code-smell-ratchet.yml`
**One sentence**: Lock four OAS code-smell metrics (godfile / catch_all / duplicate_helpers / ignore_calls) against a stored baseline so that PRs can only decrease or hold the counts.

## Related Documents

- `memory/2026-05-20-masc-mcp-oas-workaround-audit.md` — Cluster C (exhaustive-match cleanup) prescription: `dune -w +8` strict + monotone-decrease ratchet for `_ ->` regressions.
- masc-mcp PR #16833 (`29c2befa9f` — `ci(code-smell): 4-metric monotone-decrease ratchet + RFC-0146`) — sibling implementation in masc-mcp. OAS mirrors the script/workflow shape but defines a different metric set, since OAS has no HTML code-smell report and `contains_substring` is not the dominant duplicate-helper signature.
- `~/me/instructions/software-development.md` §Workaround Rejection Bar — ratchets are the prescribed prevention for "every audit becomes a Sisyphus task" pattern.
- OAS exhaustive-match cleanup history (9 merged PRs touching 27 sites) — without a gate, the next refactor wave will re-introduce `_ ->` arms in closed-variant contexts.

## 0. Summary

OAS has no automated guard against the four code-smell shapes that
the 2026-05-20 audit (Cluster C) identified as regression-prone:

1. **godfile** — `.ml` / `.mli` files ≥ 1000 LoC.
2. **catch_all** — `| _ ->` arms (most are legitimate list filters,
   but a non-trivial fraction silently absorbs new variants when a
   closed sum type gains a constructor).
3. **duplicate_helpers** — top-level redefinitions of small utility
   functions that should live in a shared module
   (`contains_substring`, `starts_with`, `first_token_basename`,
   `last_pipeline_segment`).
4. **ignore_calls** — bare `ignore (...)` call sites without an
   adjacent comment justifying the discarded result.

This RFC introduces a baseline + monotone-decrease ratchet. PRs may
*decrease* or *hold* any metric; a PR that *increases* any metric
fails CI unless the PR body carries `RATCHET-WAIVED: <reason>` and
links a sunset RFC.

## 1. Problem

Audit cycles in OAS have repeatedly converged on the same pattern:

1. A sweep identifies N regression-prone sites.
2. K PRs land that reduce N → N - K.
3. New PRs over the next weeks re-introduce roughly K sites.
4. The next audit re-discovers the same shapes with the same N.

The audit memory (`2026-05-20-masc-mcp-oas-workaround-audit.md`)
records this for masc-mcp as the "Sisyphus task" pattern; the OAS
exhaustive-match cleanup (9 PRs, 27 sites) is the local instance.

`dune -w +8` strict warnings catch *fully-exhaustive missing arms*,
but they cannot catch:

- a new `| _ ->` arm added to a previously-exhaustive match
  (downgrade is silent);
- a third file defining `let contains_substring = ...` instead of
  reusing an existing one;
- a new file landing at 1500 LoC;
- a new `ignore (expensive_call ())` without context.

A ratchet does not replace `dune -w +8` — it complements it by
locking the *aggregate* counts so any silent regression triggers CI
attention.

## 2. Decision

Adopt a 4-metric monotone-decrease ratchet wired into CI.

- Baseline file: `.ci/code-smell-baseline.json`.
- Gate script: `scripts/ci-code-smell-ratchet.sh` with three modes
  (`--measure | --check | --rebaseline`).
- Workflow: `.github/workflows/code-smell-ratchet.yml` runs on
  `pull_request` and `push:main`.
- Escape hatch: `RATCHET-WAIVED: <reason>` line in PR body (PR path
  only — `push:main` always fails on regression).

## 3. Measurement Commands (Reproducibility)

These commands are normative. Changing any of them requires a
superseding RFC. The script wraps them verbatim.

```bash
# 1. godfile
find lib -name "*.ml" -o -name "*.mli" \
  | xargs wc -l \
  | awk '$1>=1000 && $2!="total"{c++}END{print c+0}'

# 2. catch_all
rg -c "^\s*\| _ ->" lib/ --type ml \
  | awk -F: '{s+=$NF}END{print s+0}'

# 3. duplicate_helpers
rg -c "^let (contains_substring|starts_with|first_token_basename|last_pipeline_segment)" lib/ --type ml \
  | awk -F: '{s+=$NF}END{print s+0}'

# 4. ignore_calls
rg -c "^\s*ignore \(" lib/ --type ml \
  | awk -F: '{s+=$NF}END{print s+0}'
```

Note on `find(1)`: some shells alias `find` to ripgrep. The script
resolves `/usr/bin/find` first to preserve POSIX semantics. The
in-script command is byte-identical to the form above when the alias
is bypassed.

## 4. Baseline (2026-05-20)

Measured at `d845cad7b3410a2fafa2ce1743f122a21bef9be1` (`origin/main`):

| metric             | count |
|--------------------|-------|
| godfile            | 10    |
| catch_all          | 768   |
| duplicate_helpers  | 9     |
| ignore_calls       | 15    |

The 10 godfiles span `lib/pipeline/pipeline.ml`,
`lib/llm_provider/{complete,pricing,capabilities,transport_claude_code,streaming,discovery,backend_openai,transport_codex_cli}.ml`,
and `lib/runtime_server.ml`. Reduction lives outside this RFC — the
ratchet only prevents *growth*.

## 5. Workflow Semantics

| Event           | Behavior                                                        |
|-----------------|-----------------------------------------------------------------|
| `pull_request`  | Run `--check`. Fail unless ratchet PASSED or PR body waived.    |
| `push:main`     | Run `--check`. Fail on any regression. No waiver path.          |

`--rebaseline` is invoked manually on a PR (with reviewer approval)
when a metric must legitimately grow — e.g. importing a vendored
file. The RFC body of that PR must explain the increase.

## 6. Why These Four Metrics

OAS-specific reasoning, divergent from masc-mcp's identical-name
slot:

- **godfile** — OAS `lib/` has 10 files ≥ 1000 LoC, mostly in
  `lib/llm_provider/`. Each new provider tends to push existing
  files past the threshold. Holding the line is the first step
  toward the existing `agent.ml → agent/` decomposition convention.
- **catch_all** — most of OAS's 768 hits are list-pattern filters
  (`| _ -> false` / `| [] -> ... | _ -> ...`). The ratchet does
  not require *removing* them; it forbids *adding* new ones in
  closed-variant matches without a manual review acknowledging the
  trade-off.
- **duplicate_helpers** — the OAS-specific four names
  (`contains_substring`, `starts_with`, `first_token_basename`,
  `last_pipeline_segment`) are textual signatures of helpers that
  appear in 2+ files. `starts_with` is the most common drift
  vector (string-prefix dispatch).
- **ignore_calls** — `ignore (e)` discards a result without context.
  The ratchet prefers `let _ : T = e (* reason *)` so the
  intent is reviewable. This metric is small (15) and likely the
  easiest to drive to zero over time.

## 7. Escape Hatch & Sunset Criteria

Escape hatch: PR body line

```
RATCHET-WAIVED: <reason, e.g. "vendored upstream patch, new provider import">
```

The waiver is only honored on `pull_request`. It must link the
sunset RFC that removes the workaround. CI logs both the waiver and
the regression delta.

Sunset criteria: when *all four* metrics fall to ≤ 30 % of the
2026-05-20 baseline (godfile ≤ 3, catch_all ≤ 230,
duplicate_helpers ≤ 2, ignore_calls ≤ 4), this RFC supersedes
itself with a stricter variant (no waiver path, or threshold
counts rather than monotone-decrease).

## 8. Non-Goals

- This RFC does not measure or gate test code under `test/`.
- It does not classify catch-all arms by RHS — that is a separate
  audit step (see masc-mcp `audit-catchall.sh`; OAS may adopt a
  similar tool in a follow-up).
- It does not replace `dune -w +8` strict warnings or
  bisect coverage floors.
- It does not back-fill the existing godfiles toward 300-line
  decomposition — that is RFC-AC-017 / future work.

## 9. Risks

- **Baseline drift on legitimate refactors.** If a PR legitimately
  needs to add a `| _ ->` arm (e.g. defending against a JSON shape
  from an external API), the waiver path applies. The reviewer
  must confirm the arm is not absorbing a closed sum.
- **False sense of safety.** The ratchet does not catch *semantic*
  regressions — only count regressions. A PR that *replaces* a
  catch-all with another shape that is functionally identical but
  textually different (e.g. `| (_ : t) ->`) would slip past
  `catch_all` measurement. This is acceptable — the goal is
  pressure, not perfection.
- **find(1) alias on dev machines.** Mitigated by resolving
  `/usr/bin/find` explicitly in the script.

## 10. Compatibility with masc-mcp RFC-0146

The two RFCs share script structure but not metric definitions:

| metric (slot)      | masc-mcp (RFC-0146)                       | OAS (RFC-AC-022)                                                                                  |
|--------------------|-------------------------------------------|----------------------------------------------------------------------------------------------------|
| godfile            | `find lib -name "*.ml"` (≥ 1000 LoC)      | `find lib -name "*.ml" -o -name "*.mli"` (≥ 1000 LoC) — `.mli` included                            |
| catch_all          | same                                      | same                                                                                                |
| 3rd metric         | `contains_substring` only                 | `contains_substring \| starts_with \| first_token_basename \| last_pipeline_segment` (4 names)     |
| ignore_calls       | same                                      | same                                                                                                |

The divergence is intentional: OAS does not have an HTML
code-smell report to constrain it, and the helper-duplication
signatures observed in `lib/llm_provider/` and `lib/pipeline/`
differ from the masc-mcp keeper sub-system.

## 11. Acceptance

- [x] `.ci/code-smell-baseline.json` committed with current counts.
- [x] `scripts/ci-code-smell-ratchet.sh` with `--measure | --check | --rebaseline`.
- [x] `.github/workflows/code-smell-ratchet.yml` wired to `pull_request` + `push:main`.
- [x] `--check` against baseline returns PASS at 0-diff (this PR).
- [ ] Next PR that increases any metric exercises the waiver path.
