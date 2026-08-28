# Phase 0: Disable Local Playground (Fail-Closed) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `Local` sandbox profile impossible to use — rejected at config load, keeper create/update, and dispatch — behind a default-off gate with a dev/test escape hatch (`MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1`).

**Architecture:** A single gate reader (`Env_config_sandbox.Gate`) is the SSOT for "is local allowed". Three enforcement surfaces consume it: keeper TOML/profile-default load (`keeper_meta_contract.ml`), keeper-up argument validation (`keeper_turn_up_args.ml`, called from create/update/dashboard), and the dispatch branch itself (`keeper_tool_execute_runtime.ml`, defense in depth). The `Local` constructor and `default_sandbox_profile` stay in the type (TLA/SSOT stability); every *resolution surface* rejects it when the gate is off.

**Tech Stack:** OCaml 5, dune, Alcotest, Eio. Tests run via `scripts/dune-local.sh` / `make test-unit`.

**Spec:** `docs/superpowers/specs/2026-08-27-openssh-microvm-exec-design.md` §4.1. Phases 1 (SSH exec lane) and 2 (Firecracker microVM) get their own plans after spec review.

---

## File Structure

- Modify: `lib/config/env_config_sandbox.ml` / `.mli` — new `Gate` submodule (flag + canonical message)
- Modify: `lib/config/feature_flag_registry.ml:112` — register `MASC_EXEC_ALLOW_LOCAL_PLAYGROUND`
- Modify: `lib/keeper/keeper_turn_up_args.ml` / `.mli` — `validate_sandbox_profile_allowed`; extend `validate_sandbox_settings` with `?sandbox_profile`
- Modify: `lib/keeper/keeper_turn_up_create.ml:59`, `lib/keeper/keeper_turn_up_update.ml:241` — pass the resolved profile into validation
- Modify: `lib/keeper/keeper_meta_contract.ml:379-381` — reject `Local` from profile defaults/manifests
- Modify: `lib/keeper/keeper_tool_execute_runtime.ml:332-334` — `Local` dispatch branch fails closed; one-time warning when the hatch is on
- Create: `test/test_keeper_local_playground_gate.ml` + stanza in `test/dune`
- Modify: `test/test_keeper_turn_up_args.ml`, `test/test_keeper_turn_sandbox_profile_gate.ml` — new cases
- Modify: `config/keepers/issue_king.toml:4` — `local` → `docker`
- Modify: `scripts/harness/perf/README.md:177` — drop `local` as a valid example
- Create: `docs/rfc/RFC-0394-local-playground-fail-closed.md` — strategy-change RFC

## Conventions used below

- Env readers follow `env_config_sandbox.ml` (`Feature_flag_registry.get_bool` for registered flags; registry entry required).
- Test stanza with env, precedent `test/dune:2693-2701`:
  ```
  (test
   (name test_x)
   (modules test_x)
   (action (setenv SOME_ENV true (run %{test})))
   (libraries masc_test_deps))
  ```
- Fast test loop: `scripts/dune-local.sh build test/<name>.exe && _build/default/test/<name>.exe`
- Full suite: `make test-unit`
- Substring helper (copied from `test/test_keeper_local_profile_docker_playground.ml:41-45`):
  ```ocaml
  let contains needle haystack =
    let n = String.length needle and h = String.length haystack in
    let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
    scan 0
  ```

---

### Task 1: Gate flag module (`Env_config_sandbox.Gate`)

**Files:**
- Create: `test/test_keeper_local_playground_gate.ml`
- Modify: `test/dune` (append stanza)
- Modify: `lib/config/env_config_sandbox.ml` (add `Gate` after the `Preflight` module, ~line 93)
- Modify: `lib/config/env_config_sandbox.mli` (add `Gate` sig after `Preflight`, ~line 94)
- Modify: `lib/config/feature_flag_registry.ml` (insert after the `MASC_KEEPER_DOCKER_PLAYGROUND` entry, line 112)

- [ ] **Step 1: Write the failing test + dune stanza**

`test/test_keeper_local_playground_gate.ml`:
```ocaml
open Alcotest

let hatch_key = "MASC_EXEC_ALLOW_LOCAL_PLAYGROUND"
let clear_hatch () = Unix.putenv hatch_key ""
let set_hatch () = Unix.putenv hatch_key "true"

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  scan 0

let test_gate_default_disabled () =
  clear_hatch ();
  check bool "gate off by default" false
    (Env_config_sandbox.Gate.allow_local_playground ())

let test_gate_enabled_via_hatch () =
  set_hatch ();
  Fun.protect ~finally:clear_hatch (fun () ->
      check bool "gate on with hatch" true
        (Env_config_sandbox.Gate.allow_local_playground ()))

let test_disabled_message_names_hatch () =
  check bool "message names the hatch env var" true
    (contains hatch_key Env_config_sandbox.Gate.disabled_message)

let () =
  run "Local playground gate"
    [ "gate",
      [ test_case "default disabled" `Quick test_gate_default_disabled
      ; test_case "enabled via hatch" `Quick test_gate_enabled_via_hatch
      ; test_case "message names hatch" `Quick test_disabled_message_names_hatch
      ] ]
```

Append to `test/dune`:
```
(test
 (name test_keeper_local_playground_gate)
 (modules test_keeper_local_playground_gate)
 (libraries masc_test_deps))
```
(If the build reports `Unix` unbound, change libraries to `(libraries masc_test_deps unix)`.)

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/dune-local.sh build test/test_keeper_local_playground_gate.exe`
Expected: FAIL — compile error, `Gate` does not exist in `Env_config_sandbox`.

- [ ] **Step 3: Implement the gate**

`lib/config/env_config_sandbox.ml`, after the `Preflight` module:
```ocaml
(* --------------------------------------------------------------- *)
(* Gate — local playground kill switch                             *)
(* --------------------------------------------------------------- *)

module Gate = struct
  let env_key = "MASC_EXEC_ALLOW_LOCAL_PLAYGROUND"

  let allow_local_playground () =
    Feature_flag_registry.get_bool env_key

  let disabled_message =
    "sandbox_profile \"local\" is disabled: the local playground is off \
     (fail-closed). Set sandbox_profile = \"docker\", or set \
     MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1 for dev/test only."
end
```

`lib/config/env_config_sandbox.mli`, after the `Preflight` sig:
```ocaml
(** {1 Gate — local playground kill switch} *)
module Gate : sig
  val env_key : string
  (** [MASC_EXEC_ALLOW_LOCAL_PLAYGROUND]. *)

  val allow_local_playground : unit -> bool
  (** Default [false]: the [Local] sandbox profile is rejected at config
      load, keeper create, and dispatch.  Escape hatch for dev/test. *)

  val disabled_message : string
  (** Canonical rejection message shared by all gate surfaces. *)
end
```

`lib/config/feature_flag_registry.ml`, after the `MASC_KEEPER_DOCKER_PLAYGROUND` record:
```ocaml
  { env_name = "MASC_EXEC_ALLOW_LOCAL_PLAYGROUND";
    description = "Escape hatch: allow the disabled local sandbox profile (dev/test only)";
    default = false; category = "keeper";
    lifecycle = Active };
```

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/dune-local.sh build test/test_keeper_local_playground_gate.exe && _build/default/test/test_keeper_local_playground_gate.exe`
Expected: PASS (3 cases). Note: this relies on fresh env reads per call (the module documents "Fresh read per call"); if the registry turns out to cache, split the enabled case into a second stanza with `(action (setenv MASC_EXEC_ALLOW_LOCAL_PLAYGROUND true (run %{test})))` per the `test/dune:2696-2700` precedent.

- [ ] **Step 5: Commit**

```bash
git add lib/config/env_config_sandbox.ml lib/config/env_config_sandbox.mli \
  lib/config/feature_flag_registry.ml test/test_keeper_local_playground_gate.ml test/dune
git commit -m "feat(exec): add MASC_EXEC_ALLOW_LOCAL_PLAYGROUND gate SSOT (default off)"
```

---

### Task 2: Keeper-up validation gate

**Files:**
- Modify: `lib/keeper/keeper_turn_up_args.ml` (add function near line 375; extend `validate_sandbox_settings` at line 402)
- Modify: `lib/keeper/keeper_turn_up_args.mli:94`
- Modify: `lib/keeper/keeper_turn_up_create.ml:59`
- Modify: `lib/keeper/keeper_turn_up_update.ml:241`
- Test: `test/test_keeper_turn_up_args.ml` (module alias `A = Keeper_turn_up_args`, cases around lines 405-441)

- [ ] **Step 1: Write the failing tests**

Add to `test/test_keeper_turn_up_args.ml` (reuse/add the `contains` helper from Conventions):
```ocaml
let hatch_key = "MASC_EXEC_ALLOW_LOCAL_PLAYGROUND"

let test_validate_rejects_local_when_gate_off () =
  Unix.putenv hatch_key "";
  (match A.validate_sandbox_profile_allowed ~profile:Keeper_types_profile_sandbox.Local with
   | Error msg ->
     check bool "rejection names the hatch" true (contains hatch_key msg)
   | Ok () -> fail "local profile must be rejected when the gate is off")

let test_validate_allows_docker_when_gate_off () =
  Unix.putenv hatch_key "";
  (match A.validate_sandbox_profile_allowed ~profile:Keeper_types_profile_sandbox.Docker with
   | Ok () -> ()
   | Error err -> fail ("docker must stay allowed: " ^ err))

let test_validate_allows_local_with_hatch () =
  Unix.putenv hatch_key "true";
  Fun.protect ~finally:(fun () -> Unix.putenv hatch_key "") (fun () ->
      match A.validate_sandbox_profile_allowed ~profile:Keeper_types_profile_sandbox.Local with
      | Ok () -> ()
      | Error err -> fail ("hatch must allow local: " ^ err))
```
Register the three cases in that file's `run` list.

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/dune-local.sh build test/test_keeper_turn_up_args.exe`
Expected: FAIL — `A.validate_sandbox_profile_allowed` unbound.

- [ ] **Step 3: Implement**

`lib/keeper/keeper_turn_up_args.ml`, after `resolve_sandbox_profile` (line 381):
```ocaml
let validate_sandbox_profile_allowed ~profile =
  match profile with
  | Local when not (Env_config_sandbox.Gate.allow_local_playground ()) ->
    Error Env_config_sandbox.Gate.disabled_message
  | _ -> Ok ()
```
(If `Local` is not in scope, qualify: `Keeper_types_profile_sandbox.Local`.)

Extend `validate_sandbox_settings` (line 402) with an optional profile, preserving every existing `allowed_paths` check verbatim after the new gate:
```ocaml
let validate_sandbox_settings ?sandbox_profile ~allowed_paths =
  match sandbox_profile with
  | Some profile ->
    (match validate_sandbox_profile_allowed ~profile with
     | Error _ as err -> err
     | Ok () -> <existing body unchanged>)
  | None -> <existing body unchanged>
```
Concretely: wrap, do not rewrite — the existing `allowed_paths=[ "*" ]` rejection and subsequent checks move under the `Ok () ->` / `None ->` arms untouched.

`lib/keeper/keeper_turn_up_args.mli`: update the `validate_sandbox_settings` signature to take `?sandbox_profile:sandbox_profile` first, and add:
```ocaml
val validate_sandbox_profile_allowed :
  profile:Keeper_types_profile_sandbox.sandbox_profile -> (unit, string) result
```

Call sites — pass the profile where one is in scope:
- `lib/keeper/keeper_turn_up_create.ml:59`: `validate_sandbox_settings ~allowed_paths` → `validate_sandbox_settings ~sandbox_profile ~allowed_paths` (`sandbox_profile` is bound at lines 41-46).
- `lib/keeper/keeper_turn_up_update.ml:241`: read the surrounding 30 lines; if a resolved profile value is in scope, pass it the same way. If the update path never resolves a profile, leave the call unchanged — create/config/dispatch gates still cover it. Record which you did in the commit message.
- `lib/server/server_dashboard_http_keeper_api_post.ml:882`: same rule.

- [ ] **Step 4: Run to verify**

Run: `scripts/dune-local.sh build test/test_keeper_turn_up_args.exe test/test_keeper_allowed_paths.exe && _build/default/test/test_keeper_turn_up_args.exe && _build/default/test/test_keeper_allowed_paths.exe`
Expected: PASS. (`test_keeper_allowed_paths.ml` must compile unchanged — that is the point of the optional argument.)

- [ ] **Step 5: Commit**

```bash
git add lib/keeper/keeper_turn_up_args.ml lib/keeper/keeper_turn_up_args.mli \
  lib/keeper/keeper_turn_up_create.ml lib/keeper/keeper_turn_up_update.ml \
  lib/server/server_dashboard_http_keeper_api_post.ml test/test_keeper_turn_up_args.ml
git commit -m "feat(keeper): reject sandbox_profile=local at keeper-up validation (gate off)"
```

---

### Task 3: Config-load gate (profile defaults / manifests)

**Files:**
- Modify: `lib/keeper/keeper_meta_contract.ml:379-381`
- Test: `test/test_keeper_turn_sandbox_profile_gate.ml` (existing suite for `effective_meta_of_profile_defaults` — follow its fixture pattern)

- [ ] **Step 1: Write the failing test**

In `test/test_keeper_turn_sandbox_profile_gate.ml`, copy an existing case's defaults/meta fixture, change only the resolved profile to `Local`, and assert rejection:
```ocaml
let test_local_profile_defaults_rejected_when_gate_off () =
  Unix.putenv "MASC_EXEC_ALLOW_LOCAL_PLAYGROUND" "";
  (* fixture: same defaults record as the existing cases in this file,
     with sandbox_profile = Some Keeper_types_profile_sandbox.Local *)
  match Masc.Keeper_meta_contract.effective_meta_of_profile_defaults defaults meta with
  | Error msg ->
    check bool "error names disabled" true (contains "disabled" msg)
  | Ok _ -> fail "local profile defaults must be rejected when the gate is off"
```
Register it in the file's `run` list.

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/dune-local.sh build test/test_keeper_turn_sandbox_profile_gate.exe && _build/default/test/test_keeper_turn_sandbox_profile_gate.exe`
Expected: FAIL — resolution currently returns `Ok`.

- [ ] **Step 3: Implement**

`lib/keeper/keeper_meta_contract.ml`, in `effective_meta_of_profile_defaults`:
```ocaml
  match target_sandbox_profile with
  | Error _ as err -> err
  | Ok Local when not (Env_config_sandbox.Gate.allow_local_playground ()) ->
      Error
        (Printf.sprintf "keeper %s rejected: %s"
           meta.name Env_config_sandbox.Gate.disabled_message)
  | Ok sandbox_profile ->
      (* existing body unchanged *)
```
(`Local` should be in scope via the `let open Keeper_types_profile in` at line 367; if not, qualify it. If dune reports `Env_config_sandbox` unbound, add the config library to the keeper lib's dune deps.)

- [ ] **Step 4: Run to verify it passes**

Same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/keeper/keeper_meta_contract.ml test/test_keeper_turn_sandbox_profile_gate.ml
git commit -m "feat(keeper): reject sandbox_profile=local from profile defaults/manifests"
```

---

### Task 4: Dispatch-layer defense in depth

**Files:**
- Modify: `lib/keeper/keeper_tool_execute_runtime.ml:332-334`

Testing decision (explicit, not a gap): after Tasks 2–3, no keeper meta carrying `Local` can be created or loaded, so this branch is unreachable in production. Direct unit coverage would need the full tool-execute harness; instead, verification is (a) the branch now consults the gate, (b) the full unit suite passes, (c) the contract harness passes in Task 6.

- [ ] **Step 1: Implement the fail-closed branch**

Add near the top of the module (or function — match local style):
```ocaml
let local_hatch_warned = ref false
```

Change the dispatch match (currently `| Local -> local_dispatch_sandbox ()`):
```ocaml
        let dispatch_sandbox =
          match sandbox_profile with
          | Local ->
            if Env_config_sandbox.Gate.allow_local_playground () then (
              if not !local_hatch_warned then (
                local_hatch_warned := true;
                Log.Keeper.warn
                  "local playground enabled via MASC_EXEC_ALLOW_LOCAL_PLAYGROUND (dev/test only)");
              local_dispatch_sandbox ())
            else
              Error
                (Keeper_sandbox_shell_ir_target.target_error
                   ("local_playground_disabled: "
                    ^ Env_config_sandbox.Gate.disabled_message))
          | Docker ->
            (* unchanged *)
```
Note: with the hatch ON, behavior is byte-identical to before (same `local_dispatch_sandbox ()` result) plus a one-time warning.

- [ ] **Step 2: Build and run the tool-execute suites**

Run: `scripts/dune-local.sh build test/test_keeper_tool_execute_stream_close.exe && _build/default/test/test_keeper_tool_execute_stream_close.exe`
Expected: PASS (this suite exercises the dispatch path with the hatch unset in any way that reaches Local only if fixtures construct meta directly — if it now fails with `local_playground_disabled`, add the hatch to its dune stanza per Conventions and note it for Task 6).

- [ ] **Step 3: Commit**

```bash
git add lib/keeper/keeper_tool_execute_runtime.ml
git commit -m "feat(keeper): fail closed on Local dispatch when the playground gate is off"
```

---

### Task 5: Migrate the last local keeper + doc references

**Files:**
- Modify: `config/keepers/issue_king.toml:4`
- Modify: `scripts/harness/perf/README.md:177`

- [ ] **Step 1: Verify current state**

Run: `grep -rn 'sandbox_profile' config/keepers/ scripts/harness/ && grep -H sandbox_profile $MASC_BASE_PATH/.masc/config/keepers/*.toml`
Expected: only `issue_king.toml` says `local` in the repo; live `<base-path>/.masc` keepers are already `docker` (verified 2026-08-27).

- [ ] **Step 2: Migrate**

`config/keepers/issue_king.toml:4`: `sandbox_profile = "local"` → `sandbox_profile = "docker"`.

`scripts/harness/perf/README.md:177`: replace the "`sandbox_profile = "local"` (or `"docker"`)" example with `"docker"` only, and add one sentence: local requires `MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1`.

- [ ] **Step 3: Commit**

```bash
git add config/keepers/issue_king.toml scripts/harness/perf/README.md
git commit -m "chore(keepers): migrate issue_king off the disabled local profile"
```

---

### Task 6: Suite repair under the closed gate

- [ ] **Step 1: Run the full unit suite**

Run: `make test-unit`
Expected: failures only where tests create/load/dispatch `Local` keepers without the hatch.

- [ ] **Step 2: Repair each failure, one of two ways**

- Test legitimately needs the local path (exec-substrate tests, playground-path tests): add the hatch to its `test/dune` stanza — `(action (setenv MASC_EXEC_ALLOW_LOCAL_PLAYGROUND true (run %{test})))` — or merge `(setenv ...)` into an existing action.
- Test asserts profile *validation* behavior: update expectations to the new rejection message.
Known suspects: `test/test_keeper_turn_up_args.ml` (default-resolution cases — should be unaffected since `resolve_sandbox_profile` stays pure; confirm), any suite that boots a keeper end-to-end with a local TOML.

- [ ] **Step 3: Check the harnesses**

Run: `grep -rn '"local"' scripts/harness/ config/`
Fix any keeper TOML/fixture still requesting `local` (expect none after Task 5; the perf README is docs-only).
Then: `make test-contract` (boots a hermetic server — proves boot-time rejection does not break the harness).

- [ ] **Step 4: Manual verification**

Create a throwaway keeper TOML with `sandbox_profile = "local"` and attempt `masc_keeper_up` against a locally built server — expect a `Policy_rejection` naming `MASC_EXEC_ALLOW_LOCAL_PLAYGROUND`. Repeat with the hatch set — expect success plus the warning log line.

- [ ] **Step 5: Commit**

```bash
git add test/dune test/ scripts/
git commit -m "test: pin MASC_EXEC_ALLOW_LOCAL_PLAYGROUND where local-path coverage is intended"
```

---

### Task 7: RFC-0394 + docs

**Files:**
- Create: `docs/rfc/RFC-0394-local-playground-fail-closed.md`

- [ ] **Step 1: Write the RFC**

Frontmatter and skeleton (fill sections with the content below; keep it terse — this RFC records a decision, the design detail lives in the spec):

```markdown
---
rfc: "0394"
title: "Local playground fail-closed; execution relocates off-host (SSH, then microVM)"
status: Draft
created: 2026-08-27
author: jeong-sik
supersedes: []
related: ["0213", "0208", "0001"]
---

# RFC-0394 — Local playground fail-closed; off-host execution

- Supersedes RFC-0213 §5.2's durable recommendation (B1 seatbelt). Rationale:
  seatbelt is a deprecated Apple API and still shares the host kernel; the
  workspace trust boundary we actually want is a machine boundary.
- Activates RFC-0213 §4 option C (off-host microVM), phased:
  Phase 0 (this RFC): `sandbox_profile = "local"` is rejected at config load,
  keeper create/update, and dispatch unless
  `MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1` (dev/test escape hatch, warns at use).
  Phase 1: OpenSSH remote exec lane (`sandbox_profile = "remote_ssh"`).
  Phase 2: per-keeper Firecracker microVMs on a remote Linux host; the SSH
  endpoint becomes the VM.
- Fail-closed per RFC-0001: unreachable remote / disabled local is an error,
  never a silent fallback to host execution.
- Design spec: docs/superpowers/specs/2026-08-27-openssh-microvm-exec-design.md
```

- [ ] **Step 2: Update RFC-0213**

Add one line to its header block: `updated:` today + a note under §5 that its B1 recommendation is superseded by RFC-0394.

- [ ] **Step 3: AGENTS.md sweep**

Run: `grep -rn -i 'playground\|sandbox_profile' AGENTS.md CLAUDE.md 2>/dev/null`
Update any convention that still presents `local` as a normal choice.

- [ ] **Step 4: Commit**

```bash
git add docs/rfc/RFC-0394-local-playground-fail-closed.md docs/rfc/RFC-0213-keeper-sandbox-isolation.md AGENTS.md CLAUDE.md
git commit -m "docs(rfc): RFC-0394 local playground fail-closed; off-host execution strategy"
```

---

## Plan-level verification

- `make test-unit` green; `make test-contract` green.
- `grep -rn 'sandbox_profile = "local"' config/ scripts/` → no hits.
- Manual: local keeper rejected without hatch, works with hatch + warning (Task 6 Step 4).

## Follow-up plans (not in scope here)

- Phase 1 plan — SSH exec lane: `Sandbox_target.Ssh` variant, `remote_ssh` profile, `keeper_sandbox_ssh.ml` runner (ControlMaster reuse, pinned known_hosts), `masc-exec-shim` remote protocol, path translation, endpoint registry config, secret-projection inversion. Requires spec review sign-off on the shim protocol + config schema first.
- Phase 2 plan — Firecracker microVM backend on a remote Linux host: blocked on operator provisioning the host.
