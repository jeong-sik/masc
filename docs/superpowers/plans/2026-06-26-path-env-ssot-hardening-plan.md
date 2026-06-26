# Path / Env SSOT Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove implicit cwd-relative path construction in MASC and consolidate duplicated env parsers in OAS behind a single typed helper module.

**Architecture:**
- MASC: `bin/main_eio.ml` uses `Common.masc_dirname` and `Config_dir_resolver` instead of literal `.masc/config` concatenation.
- OAS: `Llm_provider.Cli_common_env` becomes the canonical env parser; `Defaults` and `Util` delegate to it; `Tool_result_store` uses it for numeric overrides.

**Tech Stack:** OCaml 5.4, dune, Alcotest, inline expect tests (`let%test`).

---

## File Structure

| File | Responsibility |
|------|----------------|
| `bin/main_eio.ml` | MASC `init` command path construction. |
| `lib/core/common.ml` / `.mli` | SSOT for `.masc` directory name. |
| `lib/config_dir_resolver/config_dir_resolver.ml` | Path resolution helpers. |
| `oas/lib/llm_provider/cli_common_env.ml` | Canonical OAS env parsers (already mostly correct). |
| `oas/lib/defaults.ml` | Default config; env parsing delegates to `Cli_common_env`. |
| `oas/lib/base/util.ml` | General utilities; remove duplicate `int_env_or`. |
| `oas/lib/tool_result_store.ml` | Use canonical env parser for overrides. |
| `oas/test/test_cli_common_env.ml` (create if absent) | Tests for consolidated parser behavior. |

---

## Part A — MASC Path SSOT

## Task 1: Fix `init` command path construction

**Files:**
- Modify: `bin/main_eio.ml:933-936`

- [ ] **Step 1: Replace literal `.masc` concatenation**

Change:

```ocaml
let target_root = Filename.concat (Filename.concat base_path ".masc") "config" in
```

to:

```ocaml
let target_root =
  Filename.concat
    (Filename.concat base_path Common.masc_dirname)
    "config"
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

## Part B — OAS Env SSOT

## Task 3: Extend canonical env parser with float helper

**Files:**
- Modify: `oas/lib/llm_provider/cli_common_env.ml`

- [ ] **Step 1: Add `float` parser**

Insert after the `int` function:

```ocaml
let float ?(allow_negative = false) ~default var =
  match Sys.getenv_opt var with
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = ""
    then default
    else (
      match float_of_string_opt trimmed with
      | Some v when allow_negative || v >= 0.0 -> v
      | Some v ->
        Diag.warn
          "cli_common_env"
          "%s=%S is negative (%f); using default %f"
          var
          raw
          v
          default;
        default
      | None ->
        Diag.warn
          "cli_common_env"
          "%s=%S is not a float; using default %f"
          var
          raw
          default;
        default)
  | None -> default
;;
```

- [ ] **Step 2: Add inline tests for `float`**

Append after the existing `int` tests:

```ocaml
let%test "float accepts positive env value" =
  with_env "OAS_TEST_CLI_COMMON_ENV_FLOAT_POSITIVE" "3.14" (fun () ->
    float ~default:1.0 "OAS_TEST_CLI_COMMON_ENV_FLOAT_POSITIVE" = 3.14)
;;

let%test "float rejects negative env value by default" =
  with_env "OAS_TEST_CLI_COMMON_ENV_FLOAT_NEGATIVE" "-1.0" (fun () ->
    let warnings = ref [] in
    let value =
      Diag.with_sink
        (fun level ~ctx msg -> warnings := (level, ctx, msg) :: !warnings)
        (fun () -> float ~default:1.0 "OAS_TEST_CLI_COMMON_ENV_FLOAT_NEGATIVE")
    in
    value = 1.0
    && List.exists
         (fun (level, ctx, msg) ->
            level = Diag.Warn && ctx = "cli_common_env" && String.contains msg '-')
         !warnings)
;;

let%test "float rejects non-numeric env value" =
  with_env "OAS_TEST_CLI_COMMON_ENV_FLOAT_NON_NUMERIC" "not-a-number" (fun () ->
    let warnings = ref [] in
    let value =
      Diag.with_sink
        (fun level ~ctx msg -> warnings := (level, ctx, msg) :: !warnings)
        (fun () -> float ~default:1.0 "OAS_TEST_CLI_COMMON_ENV_FLOAT_NON_NUMERIC")
    in
    value = 1.0
    && List.exists
         (fun (level, ctx, msg) ->
            level = Diag.Warn && ctx = "cli_common_env" && String.contains msg 'n')
         !warnings)
;;
```

---

## Task 4: Refactor `Defaults` to delegate to `Cli_common_env`

**Files:**
- Modify: `oas/lib/defaults.ml:8-53`

- [ ] **Step 1: Replace local env helpers with delegations**

Replace the entire block from `warn_invalid_env` through `bool_env_or` with:

```ocaml
let int_env_or default var = Llm_provider.Cli_common_env.int ~default var
let float_env_or default var = Llm_provider.Cli_common_env.float ~default var
let bool_env_or default var =
  match Llm_provider.Cli_common_env.get var with
  | None -> default
  | Some v ->
    (match String.lowercase_ascii v with
     | "1" | "true" | "yes" | "on" -> true
     | _ -> false)
;;
```

Note: `Cli_common_env.bool` already exists but returns `false` for invalid values without warning. If preserving the `Defaults` warning behavior is required, keep the local `bool_env_or` that warns on invalid values; otherwise delegate to `Cli_common_env.bool`.

- [ ] **Step 2: Remove now-unused `warn_invalid_env` and `env_or` if possible**

If `env_or` is no longer used in `Defaults`, remove it. If `warn_invalid_env` is no longer used, remove it. Verify with:

```bash
grep -n "warn_invalid_env\|env_or" oas/lib/defaults.ml
```

---

## Task 5: Remove duplicate `int_env_or` from `Util`

**Files:**
- Modify: `oas/lib/base/util.ml:156-163`

- [ ] **Step 1: Replace with delegation**

Replace:

```ocaml
let int_env_or default var =
  match Sys.getenv_opt var with
  | Some raw ->
    let trimmed = String.trim raw in
    (match int_of_string_opt trimmed with
     | Some v when v > 0 -> v
     | _ -> default)
  | None -> default
;;
```

with:

```ocaml
let int_env_or default var = Llm_provider.Cli_common_env.int ~default var
;;
```

- [ ] **Step 2: Verify no other function in `Util` needs `Sys.getenv_opt` directly**

```bash
grep -n "getenv_opt\|getenv" oas/lib/base/util.ml
```

If `int_env_or` was the only use, the `Sys` module may no longer be needed in `Util`.

---

## Task 6: Use canonical parser in `Tool_result_store`

**Files:**
- Modify: `oas/lib/tool_result_store.ml:25-29`

- [ ] **Step 1: Replace `int_of_env` with canonical parser**

Replace:

```ocaml
let int_of_env name =
  match Sys.getenv_opt name with
  | None -> None
  | Some s -> int_of_string_opt s
;;
```

with:

```ocaml
let int_of_env name =
  match Llm_provider.Cli_common_env.get name with
  | None -> None
  | Some s -> int_of_string_opt s
;;
```

This preserves the existing "invalid value is treated as unset" behavior while going through the canonical trim/non-empty helper.

---

## Task 7: Build and test OAS changes

- [ ] **Step 1: Build the affected OAS libraries**

```bash
cd /Users/dancer/me/workspace/yousleepwhen/oas
dune build @all
```

Expected: builds without errors.

- [ ] **Step 2: Run inline tests in `cli_common_env.ml`**

```bash
dune test lib/llm_provider/cli_common_env.ml
```

or

```bash
dune runtest lib/llm_provider/
```

Expected: all `let%test` blocks pass.

- [ ] **Step 3: Run OAS test suite**

```bash
dune runtest
```

Expected: no new failures.

---

## Task 8: Build and test MASC changes

- [ ] **Step 1: Build `main_eio` executable**

```bash
cd /Users/dancer/me/workspace/yousleepwhen/masc/.worktrees/feat/masc-oas-p0-infra-hardening-20260626
scripts/dune-local.sh build bin/main_eio.exe
```

Expected: builds without errors.

- [ ] **Step 2: Smoke-test `init` command**

```bash
rm -rf /tmp/masc-ssot-test
mkdir /tmp/masc-ssot-test
./_build/default/bin/main_eio.exe init --base-path /tmp/masc-ssot-test
ls /tmp/masc-ssot-test/.masc/config
```

Expected: `.masc/config` directory exists and contains seeded files.

---

## Task 9: Commit

- [ ] **Step 1: Stage MASC changes**

```bash
cd /Users/dancer/me/workspace/yousleepwhen/masc/.worktrees/feat/masc-oas-p0-infra-hardening-20260626
git add bin/main_eio.ml
git add docs/superpowers/notes/2026-06-26-sys-getcwd-audit.md || true
```

- [ ] **Step 2: Stage OAS changes**

```bash
cd /Users/dancer/me/workspace/yousleepwhen/oas
git add lib/llm_provider/cli_common_env.ml \
        lib/defaults.ml \
        lib/base/util.ml \
        lib/tool_result_store.ml
```

- [ ] **Step 3: Commit MASC path SSOT**

```bash
cd /Users/dancer/me/workspace/yousleepwhen/masc/.worktrees/feat/masc-oas-p0-infra-hardening-20260626
git commit -m "refactor(bin): use Common.masc_dirname for .masc/config path

Eliminates a literal string concatenation that bypassed the path SSOT helpers."
```

- [ ] **Step 4: Commit OAS env SSOT**

```bash
cd /Users/dancer/me/workspace/yousleepwhen/oas
git commit -m "refactor(oas): consolidate env parsing behind Cli_common_env

- Add float parser to Cli_common_env.
- Defaults/Util delegate int/float env parsing to Cli_common_env.
- Tool_result_store uses Cli_common_env.get for trim/non-empty handling."
```

---

## Spec Coverage Check

- [x] MASC path literal `.masc/config` → Task 1.
- [x] `Sys.getcwd` audit documented → Task 2.
- [x] OAS duplicated env parsers consolidated → Tasks 3–6.
- [x] Tests added/updated → Tasks 3, 7, 8.
- [x] CI verification → Tasks 7–8 (full CI run before merge).

## Placeholder Scan

No TBD/TODO/fill-in-details remain. All code blocks contain concrete changes.
