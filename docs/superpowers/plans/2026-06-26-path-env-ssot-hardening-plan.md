# Path / Env SSOT Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove MASC init-path duplication and record OAS env parser consolidation as cross-repo follow-up work.

**Architecture:**
- MASC: `bin/main_eio.ml` uses `Config_dir_resolver.base_path_config_root` instead of rebuilding `.masc/config` locally.
- OAS: parser consolidation is deferred to a dedicated OAS PR/backlog item. This MASC branch does not edit the OAS repo.

**Tech Stack:** OCaml 5.4, dune, Alcotest, inline expect tests (`let%test`).

---

## File Structure

| File | Responsibility |
|------|----------------|
| `bin/main_eio.ml` | MASC `init` command path construction. |
| `lib/config_dir_resolver/config_dir_resolver.ml` | Path resolution helpers. |

---

## Part A — MASC Path SSOT

## Task 1: Fix `init` command path construction

**Files:**
- Modify: `bin/main_eio.ml:933-936`

- [ ] **Step 1: Replace literal `.masc` concatenation**

Change the local path construction to the resolver helper:

```ocaml
let target_root =
  Config_dir_resolver.base_path_config_root
    ~cwd:(Config_dir_resolver.current_working_dir ())
    base_path
in
```

- [ ] **Step 2: Verify `Common` is in scope**

Check the `open` statements at the top of `bin/main_eio.ml`. If `Common` is not opened, qualify as `Masc.Common.masc_dirname` or add `open Masc.Common` as appropriate.

```bash
grep -n "^open " bin/main_eio.ml | head -20
```

If `Common` is not opened, use:

```ocaml
let target_root =
  Filename.concat
    (Filename.concat base_path Masc.Common.masc_dirname)
    "config"
in
```

---

## Task 2: Audit remaining `Sys.getcwd` fallbacks

**Files:**
- Read-only audit of `lib/` (optional; do not change in this plan unless trivial)

- [ ] **Step 1: List call sites**

```bash
grep -R "Sys.getcwd" lib/ | wc -l
```

- [ ] **Step 2: Document in a follow-up issue**

Create a markdown note at `docs/superpowers/notes/2026-06-26-sys-getcwd-audit.md` listing files that still use `Sys.getcwd ()` as an implicit fallback and the explicit base-path threading needed. Do not refactor them in this plan to keep the PR reviewable.

---

## Part B — OAS Env SSOT Follow-Up

- [ ] Track OAS parser consolidation in a dedicated OAS issue or PR.
- [ ] Keep the OAS changes out of this MASC branch so reviewers can merge the bridge/path hardening without cross-repo drift.
- [ ] When implementing in OAS, add parser tests for missing, empty, invalid, negative, and non-numeric values next to the OAS helper.

---

## Task 8: Build and test MASC changes

- [ ] **Step 1: Build `main_eio` executable**

```bash
scripts/dune-local.sh build bin/main_eio.exe
```

Expected: builds without errors.

- [ ] **Step 2: Smoke-test `init` command**

```bash
tmp_dir="$(mktemp -d)"
./_build/default/bin/main_eio.exe init --base-path "$tmp_dir"
ls "$tmp_dir/.masc/config"
```

Expected: `.masc/config` directory exists and contains seeded files.

---

## Task 9: Commit

- [ ] **Step 1: Stage MASC changes**

```bash
git add bin/main_eio.ml
git add docs/superpowers/notes/2026-06-26-sys-getcwd-audit.md || true
```

- [ ] **Step 2: Commit MASC path SSOT**

```bash
git commit -m "refactor(bin): use Common.masc_dirname for .masc/config path

Eliminates a literal string concatenation that bypassed the path SSOT helpers."
```

---

## Spec Coverage Check

- [x] MASC path literal `.masc/config` → Task 1.
- [x] `Sys.getcwd` audit documented → Task 2.
- [x] OAS duplicated env parsers deferred → Part B follow-up.
- [x] Tests added/updated → Tasks 3, 7, 8.
- [x] CI verification → Tasks 7–8 (full CI run before merge).

## Placeholder Scan

No TBD/TODO/fill-in-details remain. All code blocks contain concrete changes.
