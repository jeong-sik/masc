# Setup Error Attribution (PR B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When `masc setup` fails because model *configuration* could not be loaded (catalog overlay / runtime.toml parse), the output says so — file path, reason, next action — instead of the catch-all "Model connection failed" that sent operators debugging credentials.

**Architecture:** One pure formatter `Server_runtime_bootstrap.config_load_failure_diagnostic` wraps the underlying config error with an attribution header and next-action guidance; `setup_validate_runtime`'s config-error branch prints it. The `require_ok` label in `Masc_cli_setup.run` changes from "Model connection" to "Model validation" so the trailing line is accurate for every failure class (config load, runtime unavailable, tools disabled, probe failure). Exit codes unchanged (1 everywhere they were 1); messages only.

**Tech Stack:** OCaml 5, Cmdliner, Alcotest.

**Spec:** `docs/superpowers/specs/2026-09-10-dead-server-resilience-design.md` (PR B section).

**Constitution adaptations:**
- **No local Dune builds.** Tests written first, executed in CI after push. No CI watch loops.
- Independent change → own branch `feat/setup-error-attribution` from current `origin/main` (NOT stacked on PR A). PR A touched the same files (`server_runtime_bootstrap.{ml,mli}`, `test_server_runtime_bootstrap.ml`); any merge conflict is textual and small — acceptable per the constitution's independent-PR rule.
- No magic numbers.

**Current behavior (verified on origin/main `5a1bbdf0b7`):**
- `bin/main_eio.ml:2496-2507` `setup_validate_runtime`: wraps `configure_agent_core_model_catalog_env` + `configure_agent_core_model_catalog_overlay` + `Runtime.load_list` in try/with `Env_config_core.Config_error message -> Error message`; the `Error message` branch does `prerr_endline message; 1`. Everything in that branch is a config-load failure — the model probe only runs later, on the `Ok` path.
- `bin/masc_cli_setup.ml:236`: `require_ok "Model connection" validate_runtime;` — `require_ok` (`bin/masc_cli_setup.ml:162-163`) appends `" failed; fix the diagnostic above and run setup again."` via `fail` → `Log.Misc.error "setup: %s"`. So EVERY failure class ends with the "Model connection failed" lie.
- Underlying messages already carry the file path (`catalog overlay %s: %s` from the bootstrap; `runtime config parse failed (%s): …` from `Runtime.load_list`, `lib/runtime/runtime.ml:1392-1396`).
- Probe-failure branch already has its own accurate message (`bin/main_eio.ml:2529`: "The selected model did not pass its real response/tool check…"), so config-vs-probe separation only requires fixing the config branch and the label.
- No test asserts the strings "Model connection" / "Model connection failed" (grepped `test/`).

**File structure:**
- Modify: `lib/server/server_runtime_bootstrap.ml` — add `config_load_failure_diagnostic` after `configure_agent_core_model_catalog_overlay`.
- Modify: `lib/server/server_runtime_bootstrap.mli` — expose it with doc.
- Modify: `bin/main_eio.ml:2506-2507` — Error branch prints the formatter output.
- Modify: `bin/masc_cli_setup.ml:236` — label rename.
- Test: `test/test_server_runtime_bootstrap.ml` — 1 unit test + registration.

---

### Task 1: Config-load attribution formatter + wiring

**Files:**
- Modify: `lib/server/server_runtime_bootstrap.ml` (insert after `configure_agent_core_model_catalog_overlay`, which ends at current line 121)
- Modify: `lib/server/server_runtime_bootstrap.mli` (insert after the overlay val, current line 43)
- Modify: `bin/main_eio.ml:2506-2507`
- Modify: `bin/masc_cli_setup.ml:236`
- Test: `test/test_server_runtime_bootstrap.ml` (new test after `test_model_catalog_overlay_invalid_fails_loud`, current line 387; registration after current line 4811)

- [ ] **Step 1: Write the failing test**

In `test/test_server_runtime_bootstrap.ml`, insert after `test_model_catalog_overlay_invalid_fails_loud`:

```ocaml
let test_config_load_failure_diagnostic_attributes_to_config () =
  let output =
    Server_runtime_bootstrap.config_load_failure_diagnostic
      ~detail:
        "catalog overlay /ws/.masc/config/agent-core-models-overlay.toml: model entry \
         \"m\" contains unknown field(s): supports_extended_thinking"
  in
  Alcotest.(check bool)
    "names the configuration class, not a connection problem"
    true
    (String_util.contains_substring output "not a model connection problem");
  Alcotest.(check bool)
    "carries the config file path verbatim"
    true
    (String_util.contains_substring output "agent-core-models-overlay.toml");
  Alcotest.(check bool)
    "names the next action"
    true
    (String_util.contains_substring output "masc runtime-verify");
  Alcotest.(check bool)
    "never claims a model connection failure"
    false
    (String_util.contains_substring output "Model connection failed")
```

Register it in the `Alcotest.run` list immediately after the `"model catalog overlay invalid fails loud"` case:

```ocaml
          Alcotest.test_case
            "config load failure diagnostic attributes to config"
            `Quick test_config_load_failure_diagnostic_attributes_to_config;
```

- [ ] **Step 2: Implement the formatter**

In `lib/server/server_runtime_bootstrap.ml`, insert immediately after `configure_agent_core_model_catalog_overlay` (after current line 121):

```ocaml
(* A config-load failure (catalog overlay, runtime.toml) must not be reported
   as a model connection problem: the model was never reached. The diagnostic
   names the class, carries the underlying file-path-bearing detail verbatim,
   and states the next action. *)
let config_load_failure_diagnostic ~detail =
  Printf.sprintf
    "Model configuration could not be loaded (this is not a model connection problem):\n\
     %s\n\
     Fix the configuration above or move the file aside, then run setup again. `masc runtime-verify` re-checks the model connection afterwards."
    detail
```

- [ ] **Step 3: Expose in the mli**

In `lib/server/server_runtime_bootstrap.mli`, insert immediately after the `configure_agent_core_model_catalog_overlay` block (after current line 43):

```ocaml
val config_load_failure_diagnostic : detail:string -> string
(** Operator-facing diagnostic for configuration load failures (catalog overlay,
    runtime.toml): attributes the failure to configuration — explicitly not a
    model connection problem — carries the underlying detail (which already
    names the file) verbatim, and states the next action. Pure formatting; no
    I/O, no exit-code decision. *)
```

- [ ] **Step 4: Wire into `setup_validate_runtime`**

In `bin/main_eio.ml`, change the `loaded` match's Error branch (current lines 2506-2507) from:

```ocaml
  match loaded with
  | Error message -> prerr_endline message; 1
```

to:

```ocaml
  match loaded with
  | Error message ->
    prerr_endline (Server_runtime_bootstrap.config_load_failure_diagnostic ~detail:message);
    1
```

- [ ] **Step 5: Rename the require_ok label**

In `bin/masc_cli_setup.ml` line 236, change:

```ocaml
        require_ok "Model connection" validate_runtime;
```

to:

```ocaml
        require_ok "Model validation" validate_runtime;
```

The trailing line becomes "setup: Model validation failed; fix the diagnostic above and run setup again." — accurate for all four failure classes (config load, runtime unavailable, tools disabled, probe failure).

- [ ] **Step 6: Verify at the CI boundary**

No local build (constitution). Re-read the full diff checking: (a) exit codes unchanged — Error branch still returns 1, `require_ok`/`fail` path untouched; (b) the probe-failure message at `bin/main_eio.ml:2529` is untouched (config-vs-probe separation); (c) the success line `Model connection: %s / %s` at 2517 is untouched; (d) grep `bin/ lib/ test/` for `"Model connection"` — only the 2517 success line and the new test's negative assertion may remain; (e) `String_util.contains_substring` is available in the test file (already used at line 386).

- [ ] **Step 7: Commit**

```bash
git add lib/server/server_runtime_bootstrap.ml lib/server/server_runtime_bootstrap.mli bin/main_eio.ml bin/masc_cli_setup.ml test/test_server_runtime_bootstrap.ml
git commit -m "fix(setup): attribute config load failures to configuration, not model connection"
```

---

### Task 2: Push, PR, CI boundary, review handoff

- [ ] **Step 1: Branch, rebase, push**

```bash
git fetch origin
git rebase origin/main   # branch was cut from origin/main; keep it current
git push -u origin feat/setup-error-attribution
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "fix(setup): attribute config load failures to configuration, not model connection" --body "$(cat <<'EOF'
## Why

v0.35.2 install reported \"Model connection failed; fix the diagnostic above and run setup again.\" when the real problem was a stale `agent-core-models-overlay.toml` — the model was never reached. Operators debugged credentials instead of the config file. PR A stopped per-row poison from failing at all; this PR B makes the remaining config-load failures (broken TOML, unreadable file, duplicate rows, runtime.toml parse) honest. Spec: `docs/superpowers/specs/2026-09-10-dead-server-resilience-design.md` (PR B).

## What

- New `Server_runtime_bootstrap.config_load_failure_diagnostic`: wraps the underlying file-path-bearing error with \"not a model connection problem\" attribution + next action (fix/move the file, `masc runtime-verify` to re-check).
- `setup_validate_runtime`'s config-error branch prints it (exit code still 1).
- `Masc_cli_setup.run`'s label for the step: \"Model connection\" → \"Model validation\", so the trailing line is accurate for every failure class.
- Probe-failure and success messages untouched; exit codes unchanged.

## Tests

- Alcotest: formatter output attributes to configuration, carries the file path verbatim, names the next action, and never claims \"Model connection failed\".

## Notes

- Independent PR from main per the constitution; touches two files PR A also touched (`server_runtime_bootstrap.{ml,mli}`, `test_server_runtime_bootstrap.ml`) — conflicts are textual and small.
- `setup_validate_runtime` lives in the `bin/main_eio.ml` executable (not linkable into tests); the testable core is the pure formatter, wiring is one call — verified by review.
EOF
)"
```

- [ ] **Step 3: CI boundary + review handoff**

Per the constitution: do not poll CI. Move on to the next plan (PR D) while CI runs; an adversarial review agent covers this PR's diff in parallel. When CI completes, check `gh pr checks` once; if red, read the failing log and fix on the branch.

---

## Self-review notes (already applied)

- Spec coverage: (1) config load failure reported as config failure with path+reason+next action — Steps 2/4 (path+reason ride the underlying message, attribution + next action from the formatter); (2) probe failure vs config failure separate messages — probe message untouched, config branch gets its own wrapper; (3) exit codes unchanged — Step 6 check (a); (4) spec's test ("output points at config file path, not 'Model connection'") — Step 1 asserts path present + "Model connection failed" absent.
- "Model validation" label covers all four classes because every class prints its own specific diagnostic first; the label is only the trailing wrapper.
- Type consistency: `config_load_failure_diagnostic : detail:string -> string` identical in ml/mli/test/call site.
- Not in scope (deliberately): `masc runtime-verify`'s own error reporting; the all-poisoned-overlay summary WARN (PR A review follow-up, decided separately).
