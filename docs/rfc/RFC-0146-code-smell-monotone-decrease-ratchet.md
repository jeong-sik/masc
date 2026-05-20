---
rfc: "0146"
title: "Code-Smell Monotone-Decrease Ratchet"
status: Draft
created: 2026-05-20
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0078", "0088", "0126"]
implementation_prs: []
---

# RFC-0146 — Code-Smell Monotone-Decrease Ratchet

## 1. Problem

The 2026-05-19 code-smell audit
([`memory/masc-mcp-code-smell-report-2026-05-19.html`](../../memory/masc-mcp-code-smell-report-2026-05-19.html))
defined four reproducible metrics (§6 of the report):

1. **Godfile** — `.ml` files `>= 1000` LoC under `lib/`
2. **Catch-all** — `| _ ->` arms in `lib/**/*.ml`
3. **`contains_substring`** — top-level `let contains_substring` definitions
4. **`ignore (...)`** — `^\s*ignore (` call sites

Three consolidation PRs (#16608, #16609, #16610) merged in the 24 hours
following the audit. Re-running the same four commands on 2026-05-20:

| metric              | 2026-05-19 | 2026-05-20 | Δ (24h)  |
| ------------------- | ----------:| ----------:| --------:|
| godfile             |       47   |       51   | **+4**   |
| catch-all           |    3,417   |    3,843   | **+426** |
| contains_substring  |       28   |       28   | +0       |
| ignore() (no-cmt)   |       85   |       85   | +0       |

Two metrics rose despite the consolidation work — i.e. new code at the
margins outweighs the dedup. Without a gate, every audit becomes a Sisyphus
task. §`software-development.md` Workaround Rejection Bar already names this
shape (telemetry-as-fix, N-of-M patch). The remediation prescribed there is
a *ratchet*: lock metrics against a baseline and require monotone decrease.

## 2. Why not the existing audit scripts

`scripts/audit-code-smell.sh` and friends already measure these
quantities, but their gate is "informational by default" / `--strict` only
for two of the four. They do not store a baseline, so CI cannot tell
whether a PR moved a metric up or down. Result: regressions land silently.

## 3. Decision

Introduce a **monotone-decrease ratchet** for the four HTML-prescribed
metrics:

- `.ci/code-smell-baseline.json` — stored counts + `lastUpdated` /
  `lastUpdatedCommit`.
- `scripts/ci-code-smell-ratchet.sh` — `--measure | --check | --rebaseline`.
- `.github/workflows/code-smell-ratchet.yml` — runs on `pull_request` and
  `push: main`. PRs fail if any metric exceeds the baseline.

**Locking the count (equal-or-better passes) is intentional** — this
RFC explicitly rejects the freeze-as-fix workaround. Counts may *hold*
(no regression, no improvement) but never rise without an explicit waiver.

### 3.1 Measurement commands (frozen)

Sub-agents and future audits **must not modify** these commands. Any
change requires a new RFC superseding this one. Each command is copied
verbatim from §6 of the audit HTML:

```
godfile            : find lib -name "*.ml" -exec wc -l {} + \
                       | awk '$1>=1000 && $2!="total"{c++}END{print c+0}'
catch_all          : rg -c "^\s*\| _ ->" lib/ --type ml \
                       | awk -F: '{s+=$NF}END{print s+0}'
contains_substring : rg -c "^let contains_substring" lib/ --type ml \
                       | awk -F: '{s+=$NF}END{print s+0}'
ignore_calls       : rg "^\s*ignore \(" lib/ --type ml -c \
                       | awk -F: '{s+=$NF}END{print s+0}'
```

The HTML uses raw `find ... | awk '$1>=1000{c++}'`. We add
`$2!="total"` so multi-chunk `wc` runs (common locally with many files)
don't double-count the synthetic `total` row. On a single `wc` chunk the
two forms agree.

### 3.2 Initial baseline (this PR)

| metric              | count |
| ------------------- | ----: |
| godfile             |    51 |
| catch_all           |  3843 |
| contains_substring  |    28 |
| ignore_calls        |    85 |

These are measured on the same `origin/main` HEAD that this PR branches
from. The **24h regression delta is not reverted** — the baseline is the
starting line, not the report. Reverting would require root-fix PRs in
this same RFC, which would conflate "build the gate" with "fix the
regression".

## 4. Escape hatch

PRs may add a `RATCHET-WAIVED: <reason>` line to the PR body. The
workflow then passes the check job but emits a notice that the PR body
must reference a sunset RFC. This mirrors the §Workaround Rejection Bar
override clause: production-blocking fix paths get through, but only via
explicit, audit-able opt-out. No silent escape.

## 5. Sunset criteria

This ratchet is *not* the destination; it is the floor. We strengthen
the gate (e.g., per-metric sub-ratchets, file-level sub-budgets) when:

- All four metrics fall to **≤ 50% of the baseline** (i.e. godfile ≤ 25,
  catch_all ≤ 1921, contains_substring ≤ 14, ignore_calls ≤ 42), **OR**
- A dedicated typed-replacement RFC (e.g. closed-sum-type catch-all
  retirement) lands and obsoletes one of the four metrics individually.

## 6. Out of scope (deferred)

- Magic-number repetition (HTML §3) — left to the existing
  `lint-magic-number.sh` advisory pass; ratcheting it requires
  per-allowlist work, which is its own RFC.
- WORKAROUND comment census — covered by RFC-0088.
- Per-file caps — covered by RFC-0126 phase work; this RFC's `godfile`
  count is a global aggregate.

## 7. References

- `memory/masc-mcp-code-smell-report-2026-05-19.html` §6 (Reproducibility)
- `~/me/instructions/software-development.md` §Workaround Rejection Bar
- RFC-0078 (RFC number ledger) — co-located ledger advance in this PR.
- RFC-0088 (Counter-as-Fix umbrella) — adjacent: WORKAROUND comment
  policy.
- RFC-0126 (Silent-fallback discipline) — adjacent: lint scanner stack.
