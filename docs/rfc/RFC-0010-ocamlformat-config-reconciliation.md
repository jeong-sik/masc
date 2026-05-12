---
rfc: "0010"
title: "ocamlformat config reconciliation"
status: Draft
created: 2026-05-12
updated: 2026-05-12
author: vincent
supersedes: []
superseded_by: null
related: ["0058"]
implementation_prs: []
---

# RFC-0010 — ocamlformat config reconciliation

## 1. Problem

`.ocamlformat` declares `profile = janestreet`, but the codebase has never
been run through ocamlformat. As of 2026-05-12 (`origin/main` HEAD
`1a0a840c6`):

| Tree | Files violating `ocamlformat --check` | Total `.ml` + `.mli` |
|------|---|---|
| `lib/` | 1658 | 2036 (81%) |
| `test/` + `bin/` | 790 | 855 (92%) |
| **Combined** | **2448** | **2891 (85%)** |

The non-compliance is not janestreet-specific: switching `profile` to
`default` leaves the same files violating (sampled 100/100 still off).
The repo's OCaml is hand-formatted; `.ocamlformat` is an aspirational
artifact, not an enforced one.

### 1.1 How it got here

`.ocamlformat` with `profile = janestreet` entered `main` in commit
`9faabfadf` (2026-04-26, PR #10633 "chore(eio_guard): drop deprecated
with_rw/with_ro aliases"). That PR's description scopes itself to
"12 lines deleted, 2 files" and lists "what survives unchanged" — the
`.ocamlformat` write is not mentioned. It is an accidental inclusion
(squash/rebase carryover from another branch), not a deliberate style
decision. No migration accompanied it, and no one noticed for 4 months.

### 1.2 Why it stays invisible

`.github/workflows/ocamlformat.yml` only checks files a PR changed:

```bash
files=$(git diff --name-only --diff-filter=AMR "$base...$head" -- '*.ml' '*.mli')
```

A PR touching only fresh files is fine. A PR touching a *pre-existing*
file inherits that file's 4-month-old drift and is forced to reformat it
wholesale. This converts every cross-cutting refactor into a two-PR
dance:

1. The intended change (e.g. RFC-0058 Phase 5.3a: delete 4 dead wrappers,
   +28 / −46).
2. `ocamlformat-check` fails on the touched files.
3. `ocamlformat -i` the whole file (+381 / −288) — the actual change is
   now a needle in a reformat haystack.
4. A `style:` follow-up PR or commit to carry the reformat separately.

Observed instances (2026-05-12): PR #14931 (`style(cascade_model_resolve):
align to janestreet`), and the `style(test_oas_worker_named_liveness_integration)`
commit on PR #14905. With ~85% of the tree non-compliant, this recurs on
every PR that edits an old file — a self-perpetuating whack-a-mole.

## 2. Options

| # | Change | Debt after | CI `ocamlformat-check` | Trade-off |
|---|--------|-----------|------------------------|-----------|
| A | Remove `profile = janestreet` (or set `profile = default`) | ~85% remains — codebase fits no profile | still fails | Does not solve anything. Rejected. |
| B | Add `disable = true` to `.ocamlformat` | 0 (every file trivially passes) | green | ocamlformat is neutered repo-wide; new code gets no format enforcement. `version` pin stays, so the CI workflow's `opam install ocamlformat.$version` step still works. One-line revert re-arms it. |
| C | Delete `.ocamlformat` **and** `.github/workflows/ocamlformat.yml` | 0 | the job ceases to exist | Honest acknowledgement that the repo doesn't use ocamlformat. Re-introducing it later means restoring both files. Removes a CI job. |
| D | Big-bang reformat the whole tree to one chosen profile | 0 | green | ~2900 `.ml`/`.mli` files in one PR. Every in-flight PR (RFC-0058, RFC-0070, RFC-0071, RFC-0072 sprints — dozens of open branches) gets a merge conflict. `git blame` line provenance lost for the entire codebase. Needs `.git-blame-ignore-revs`. Massive, must be its own RFC with a freeze window. |
| E | Keep status quo; formalize per-PR `style:` follow-ups | permanent | per-PR fail → fix | The whack-a-mole. Converges *eventually* (only touched files reformat) but every old-file edit pays the tax. RFC-0058-class work hits it constantly. |

## 3. Recommendation: Option B (`disable = true`)

```diff
 version = 0.29.0
-profile = janestreet
+profile = janestreet
+disable = true
```

(Keep `profile` so the line survives for a future re-enable; `disable`
overrides it.)

Rationale:

- **Smallest reversible change.** One line. Re-arming ocamlformat is
  deleting that line — at which point Option D's RFC kicks in.
- **Stops the bleeding immediately.** CI `ocamlformat-check` goes green
  for every PR. RFC-0058 Phase 5.3b and the rest of the Phase 5.x sprint
  stop carrying reformat noise.
- **Doesn't pretend.** Setting `disable = true` is a truthful statement:
  "this repo is not ocamlformat-clean and we are not enforcing it right
  now." Option C is the more honest version of the same thing but also
  removes a CI job, which is a larger surface change; B is the minimal
  step and C remains available as a follow-up if the team wants the job
  gone entirely.

### 3.1 Re-enabling ocamlformat (out of scope, future RFC)

If the team wants ocamlformat back, that is Option D and needs its own
RFC covering:

- Profile choice (`janestreet` vs `default` vs `conventional` vs custom).
- A merge-freeze window so the big-bang commit doesn't conflict with
  in-flight work.
- `.git-blame-ignore-revs` so `git blame` skips the reformat commit.
- Whether to do it tree-wide in one commit or directory-by-directory.

This RFC explicitly does *not* decide any of that.

### 3.2 The two `style:` PRs already in flight

PR #14931 and the `style(test_oas_worker_named_liveness_integration)`
commit on #14905 reformatted a handful of files toward `janestreet`
before this RFC. After Option B merges they are harmless no-ops (those
files happen to be janestreet-clean now, which `disable = true` makes
irrelelvant). They can be merged as-is or closed; either is fine. Don't
block them on this RFC.

## 4. Non-goals

- Deciding which ocamlformat profile is "correct" — future RFC.
- A general code-style enforcement strategy (linting, pre-commit hooks) —
  out of scope.
- Reformatting any code — Option B touches only `.ocamlformat`.

## 5. Acceptance

- `.ocamlformat` gains `disable = true`.
- `ocamlformat-check` CI passes on a PR that edits an arbitrary
  pre-existing file (e.g. add a no-op comment to `lib/runtime_catalog.ml`
  and confirm the check is green).
- No `.ml` / `.mli` file content changes in the implementing PR.
