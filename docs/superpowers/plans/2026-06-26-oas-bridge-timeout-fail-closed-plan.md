# OAS Bridge Timeout Fail-Closed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Masc_oas_bridge.run_safe` fail closed when no Eio clock is available, eliminating the silent `Unix.gettimeofday` fallback.

**Architecture:** Replace the optional-clock pattern match with a required-clock check. If `Masc_eio_env.get_opt` returns `None` or the env carries `clock = None`, return a typed `Internal_contract_rejected` error instead of executing the wrapped function. Keep all timeout/cancel/overshoot metrics unchanged.

**Tech Stack:** OCaml 5.4, Eio 1.x, dune, Alcotest.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/masc_oas_bridge.ml` | Bridge implementation; add required-clock check. |
| `lib/masc_oas_bridge.mli` | Public API docstring; reflect clock requirement. |
| `test/test_masc_oas_bridge_timeout_guard.ml` | Guard tests; update no-clock test to expect failure. |
| `test/test_tool_task_coverage.ml` | Coverage tests; update no-clock test to expect failure. |

---

## Task 1: Update timeout guard test

**Files:**
- Modify: `test/test_masc_oas_bridge_timeout_guard.ml:32-48`

- [ ] **Step 1: Change `test_accepts_positive_timeout_without_eio_env` to expect failure**

Replace the body with:

```ocaml
let test_rejects_positive_timeout_without_eio_env () =
  match Masc_eio_env.get_opt () with
  | Some _ ->
    failwith
      "test_rejects_positive_timeout_without_eio_env requires Masc_eio_env.get_opt () = \
       None before calling run_safe"
  | None ->
    let called = ref false in
    match
      Masc_oas_bridge.run_safe ~caller:"test_timeout_guard" ~timeout_s:0.1 (fun () ->
        called := true;
        Ok "ok")
    with
    | Ok _ -> failwith "expected failure when no Eio clock is available"
    | Error _ -> Alcotest.(check bool) "fn was not called" false !called)
;;
```

- [ ] **Step 2: Update test registration**

Replace the test case name at lines 97–100:

```ocaml
; Alcotest.test_case
    "rejects positive timeout without eio env"
    `Quick
    test_rejects_positive_timeout_without_eio_env
```

---

## Task 2: Update tool task coverage test

**Files:**
- Modify: `test/test_tool_task_coverage.ml:398-407`

- [ ] **Step 1: Change `masc_oas_bridge_runs_without_eio_env` to expect failure**

Replace the `None` branch body with:

```ocaml
  | None ->
    let called = ref false in
    match
      Masc_oas_bridge.run_safe ~caller:"test_tool_task_coverage" ~timeout_s:0.1 (fun () ->
        called := true;
        Ok "ok")
    with
    | Ok _ -> failwith "expected failure when no Eio clock is available"
    | Error _ -> Alcotest.(check bool) "fn was not called" false !called)
```

---

## Task 3: Implement fail-closed bridge

**Files:**
- Modify: `lib/masc_oas_bridge.ml:26-52`

- [ ] **Step 1: Add a required-clock helper**

Insert before `run_safe`:

```ocaml
let require_clock () =
  match Masc_eio_env.get_opt () with
  | Some { clock = Some clock; _ } -> Ok clock
  | Some { clock = None; _ } ->
    Error
      (Keeper_internal_error.sdk_error_of_masc_internal_error
         (Keeper_internal_error.Internal_contract_rejected
            { reason = "Masc_oas_bridge.run_safe: Eio env initialized without a clock" }))
  | None ->
    Error
      (Keeper_internal_error.sdk_error_of_masc_internal_error
         (Keeper_internal_error.Internal_contract_rejected
            { reason = "Masc_oas_bridge.run_safe: Masc_eio_env not initialized" }))
;;
```

- [ ] **Step 2: Replace `clock_opt` logic in `run_safe`**

Replace lines 26–52 with:

```ocaml
  let clock =
    match require_clock () with
    | Ok clock -> clock
    | Error err ->
      Log.Misc.warn
        "masc_oas_bridge.run_safe: no Eio clock available, rejecting call \
         (caller=%s, budget=%.1fs)"
        caller timeout_s;
      return err
  in
  let t0 = Eio.Time.now clock in
  let elapsed () = Eio.Time.now clock -. t0 in
  let do_timeout fn = Eio.Time.with_timeout_exn clock timeout_s fn in
```

Note: `return` here is the identity for the result monad; since `run_safe` returns `('a, Agent_sdk.Error.sdk_error) result`, use the raw `Error err` value directly by returning it from `run_safe`. The cleanest implementation is:

```ocaml
  match require_clock () with
  | Error err -> err
  | Ok clock ->
    let t0 = Eio.Time.now clock in
    let elapsed () = Eio.Time.now clock -. t0 in
    let do_timeout fn = Eio.Time.with_timeout_exn clock timeout_s fn in
    try
      do_timeout fn
    with
    | Eio.Time.Timeout -> ...
    | Eio.Cancel.Cancelled inner_exn as exn -> ...
    | exn -> ...
```

Wrap the existing `try` body inside the `Ok clock` branch.

- [ ] **Step 3: Remove `Unix` from the module if no longer used**

If `Unix.gettimeofday` is the only use of `Unix` in the file, delete the `open Unix` line or remove the reference. Check with `grep "Unix" lib/masc_oas_bridge.ml` after the change.

---

## Task 4: Update `.mli` docstring

**Files:**
- Modify: `lib/masc_oas_bridge.mli:6-15`

- [ ] **Step 1: Document clock requirement**

Replace the comment block with:

```ocaml
(** Safe execution of a generic OAS operation with a mandatory timeout.
    Requires an initialized {!Masc_eio_env} carrying an Eio clock.
    If the environment is missing or has no clock, returns
    [Agent_sdk.Error.Internal (Internal_contract_rejected ...)] instead of
    executing the wrapped function.

    Catches [Eio.Time.Timeout] and [Eio.Cancel.Cancelled] to perform functional rollback.
    [caller] (#10094) labels the Otel_metric_store timeout counter so the
    operator can attribute timeouts to specific call sites.
    Raises [Invalid_argument] when [timeout_s] is not positive and finite. *)
```

---

## Task 5: Build and test

- [ ] **Step 1: Build the timeout guard test**

```bash
cd /Users/dancer/me/workspace/yousleepwhen/masc/.worktrees/feat/masc-oas-p0-infra-hardening-20260626
scripts/dune-local.sh build test_masc_oas_bridge_timeout_guard
```

Expected: builds without errors.

- [ ] **Step 2: Run the timeout guard test**

```bash
_build/default/test/test_masc_oas_bridge_timeout_guard.exe
```

Expected: all tests pass.

- [ ] **Step 3: Build the tool task coverage test**

```bash
scripts/dune-local.sh build test_tool_task_coverage
```

Expected: builds without errors.

- [ ] **Step 4: Run the tool task coverage test**

```bash
_build/default/test/test_tool_task_coverage.exe
```

Expected: all tests pass.

---

## Task 6: Commit

- [ ] **Step 1: Stage changes**

```bash
git add lib/masc_oas_bridge.ml lib/masc_oas_bridge.mli \
        test/test_masc_oas_bridge_timeout_guard.ml \
        test/test_tool_task_coverage.ml
```

- [ ] **Step 2: Commit**

```bash
git commit -m "fix(oas_bridge): fail closed when no Eio clock is available

- Replaces Unix.gettimeofday fallback with Internal_contract_rejected error.
- Updates timeout guard and tool task coverage tests to expect failure.
- Documents the clock requirement in the .mli."
```

---

## Spec Coverage Check

- [x] P1.1 fail-closed OAS bridge timeout → Tasks 1–4.
- [x] No silent degradation path → `require_clock` returns typed error.
- [x] Tests updated → Tasks 1–2.
- [x] CI verification → Task 5 (full CI run before merge).

## Placeholder Scan

No TBD/TODO/fill-in-details remain. All code blocks contain concrete changes.
