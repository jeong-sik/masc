# Overlay Lenient Load (PR A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A poisoned `agent-core-models-overlay.toml` row (stale/unknown fields left by another release) no longer blocks server boot or `masc setup`; valid rows still install, bad rows are skipped with one WARN each.

**Architecture:** Add a lenient load path to agent_core's `Model_catalog` (valid rows apply, bad rows returned as `(label, reason)` skips) and make `Server_runtime_bootstrap.configure_agent_core_model_catalog_overlay` default to it, emitting per-row WARNs. Strict `load_file` stays for the `AGENT_CORE_MODEL_CATALOG` full-replacement path (SSOT protection). Whole-file failures (unreadable, broken TOML, duplicate identities among surviving rows) stay fail-closed: skipping must never turn a contradiction into a silent winner, since row identity decides pricing.

**Tech Stack:** OCaml 5, Otoml, Alcotest (`test/`), ppx_inline_test (`let%test` inside agent_core lib), Dune (CI-only).

**Spec:** `docs/superpowers/specs/2026-09-10-dead-server-resilience-design.md` (PR A section).

**Constitution adaptations (`docs/constitution.xml` `<execution_protocol>`):**
- **No local Dune builds.** TDD ordering is preserved in commit contents (tests written before implementation), but test execution happens at the CI boundary after push. Do not run `dune build`/`dune test` locally; do not watch CI in a loop — after pushing, move to the next task and check CI when notified.
- Branch from current `origin/main` (`git fetch origin` first). One PR for this plan.
- No magic numbers: this change introduces no tunable numeric constants.

**File structure:**
- Modify: `packages/agent_core/lib/llm_provider/model_catalog.ml` — add `skipped_entry`, `parse_table_array_lenient`, `catalog_of_toml_lenient`, refactor `parse_catalog` → `parse_catalog_with`, add `of_toml_string_lenient`/`load_file_lenient`, plus inline tests.
- Modify: `packages/agent_core/lib/llm_provider/model_catalog.mli` — expose the two lenient loaders and `skipped_entry`.
- Modify: `lib/server/server_runtime_bootstrap.ml:102-121` — default loader becomes lenient; WARN per skipped row.
- Modify: `lib/server/server_runtime_bootstrap.mli:29-43` — signature + contract doc.
- Test: `test/test_server_runtime_bootstrap.ml` — update 3 stub call sites to the new loader shape; add 2 integration tests (real lenient loader); register them in the `Alcotest.run` list.

---

### Task 1: `Model_catalog` lenient loader

**Files:**
- Modify: `packages/agent_core/lib/llm_provider/model_catalog.ml`
- Modify: `packages/agent_core/lib/llm_provider/model_catalog.mli`

- [ ] **Step 1: Write the failing inline tests**

In `packages/agent_core/lib/llm_provider/model_catalog.ml`, insert after the `lookup` function (after current line 860, before `wire_kind_labels`) — placement matters because the tests call `lookup`:

```ocaml
let%test "of_toml_string_lenient keeps valid rows and skips the poisoned one" =
  match
    of_toml_string_lenient
      ~source:"fixture"
      "[[models]]\n\
       id_prefix = \"good-model\"\n\
       supports_tools = true\n\
       [[models]]\n\
       id_prefix = \"stale-model\"\n\
       supports_extended_thinking = true\n"
  with
  | Ok (catalog, [ { entry_label = "stale-model"; skip_reason } ]) ->
    String.equal
      skip_reason
      "model entry \"stale-model\" contains unknown field(s): supports_extended_thinking"
    && Option.is_some (lookup catalog "good-model")
    && Option.is_none (lookup catalog "stale-model")
  | Ok _ | Error _ -> false
;;

let%test "of_toml_string_lenient skips every poisoned row without failing the load" =
  match
    of_toml_string_lenient
      ~source:"fixture"
      "[[models]]\n\
       id_prefix = \"stale-a\"\n\
       supports_extended_thinking = true\n\
       [[models]]\n\
       id_prefix = \"stale-b\"\n\
       supports_reasoning_budget = 1024\n"
  with
  | Ok (catalog, [ a; b ]) ->
    String.equal a.entry_label "stale-a"
    && String.equal b.entry_label "stale-b"
    && Option.is_none (lookup catalog "stale-a")
    && Option.is_none (lookup catalog "stale-b")
  | Ok _ | Error _ -> false
;;

let%test "of_toml_string_lenient keeps whole-file TOML breakage fail-closed" =
  match of_toml_string_lenient ~source:"fixture" "not toml" with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "of_toml_string_lenient keeps duplicate surviving rows fail-closed" =
  (* Skipping poisoned rows must not turn a contradiction into a silent
     winner: two surviving rows with one identity still decide pricing, so
     the load fails rather than picks one. *)
  match
    of_toml_string_lenient
      ~source:"fixture"
      "[[models]]\n\
       id_prefix = \"dup-model\"\n\
       [[models]]\n\
       id_prefix = \"dup-model\"\n"
  with
  | Error _ -> true
  | Ok _ -> false
;;

let%test "of_toml_string_lenient labels a row with no readable id by position" =
  match
    of_toml_string_lenient
      ~source:"fixture"
      "[[models]]\n\
       id_prefix = \"good-model\"\n\
       [[models]]\n\
       supports_tools = true\n"
  with
  | Ok (_, [ { entry_label = "<model entry #2>"; _ } ]) -> true
  | Ok _ | Error _ -> false
;;
```

- [ ] **Step 2: Implement the lenient loader**

In the same file, add the `skipped_entry` type and helpers immediately after the strict `parse_table_array` (after current line 762):

```ocaml
(* Lenient variant of [parse_table_array]: a row that fails [parse] is
   excluded and reported instead of failing the whole load. Deployment
   overlays are hand-written and outlive the binary that wrote them; a stale
   field introduced by a newer release (or removed by an older one) must not
   block every other row. Whole-file failures stay fail-closed — see
   [catalog_of_toml_lenient]. *)
type skipped_entry =
  { entry_label : string
  ; skip_reason : string
  }

let skipped_entry_label ~kind ~id_key position item =
  match
    (try Otoml.find_opt item Otoml.get_string [ id_key ] with
     | Otoml.Type_error _ -> None)
  with
  | Some raw when String.trim raw <> "" -> String.trim raw
  | Some _ | None -> Printf.sprintf "<%s entry #%d>" kind position
;;

let parse_table_array_lenient ~kind ~id_key toml key parse =
  match Otoml.find_opt toml (Otoml.get_array Fun.id) [ key ] with
  | None -> [], []
  | Some items ->
    let entries, skipped =
      List.fold_left
        (fun (entries, skipped) (position, item) ->
           match parse item with
           | Ok entry -> entry :: entries, skipped
           | Error reason ->
             ( entries
             , { entry_label = skipped_entry_label ~kind ~id_key position item
               ; skip_reason = reason
               }
               :: skipped ))
        ([], [])
        (List.mapi (fun index item -> index + 1, item) items)
    in
    List.rev entries, List.rev skipped
;;
```

Add `catalog_of_toml_lenient` immediately after `catalog_of_toml` (after current line 815):

```ocaml
let catalog_of_toml_lenient toml =
  let models, model_skipped =
    parse_table_array_lenient ~kind:"model" ~id_key:"id_prefix" toml "models" parse_entry
  in
  let providers, provider_skipped =
    parse_table_array_lenient
      ~kind:"provider"
      ~id_key:"id"
      toml
      "providers"
      Model_provider_catalog.parse_entry
  in
  match reject_duplicate_rows models providers with
  | Error _ as e -> e
  | Ok () -> Ok ({ models; providers }, model_skipped @ provider_skipped)
;;
```

Refactor `parse_catalog` (current lines 817-830) into a shared wrapper so the strict and lenient paths have byte-identical whole-file error behavior:

```ocaml
let parse_catalog_with ~source parse catalog_of =
  let parse_res =
    try Ok (parse ()) with
    | Sys_error msg ->
      Error (Printf.sprintf "cannot read model catalog %s: %s" source msg)
    | Otoml.Parse_error (_pos, msg) ->
      Error (Printf.sprintf "model catalog TOML parse error in %s: %s" source msg)
    | Otoml.Type_error _ ->
      Error (Printf.sprintf "model catalog TOML type error in %s" source)
  in
  match parse_res with
  | Error _ as e -> e
  | Ok toml -> catalog_of toml
;;

let parse_catalog ~source parse = parse_catalog_with ~source parse catalog_of_toml
```

Add the public lenient entry points immediately after `load_file` (current line 836):

```ocaml
let of_toml_string_lenient ~source contents =
  parse_catalog_with
    ~source
    (fun () -> Otoml.Parser.from_string contents)
    catalog_of_toml_lenient
;;

let load_file_lenient path =
  parse_catalog_with ~source:path (fun () -> Otoml.Parser.from_file path) catalog_of_toml_lenient
;;
```

- [ ] **Step 3: Expose the API in the mli**

In `packages/agent_core/lib/llm_provider/model_catalog.mli`, insert after the `val load_file : string -> (t, string) result` declaration (current line 110):

```ocaml
(** A catalog row excluded by the lenient loaders. [entry_label] is the row's
    declared [id_prefix]/[id] when readable, otherwise a positional label such
    as ["<model entry #2>"]. [skip_reason] is the parse/validation error that
    excluded the row. *)
type skipped_entry =
  { entry_label : string
  ; skip_reason : string
  }

(** Lenient variant of {!of_toml_string}: rows that fail to parse are excluded
    and reported instead of failing the whole load. Deployment overlays are
    hand-written and outlive the binary that wrote them, so one stale field
    must not block every other row. Whole-file failures — unreadable input,
    broken TOML, or duplicate identities among surviving rows — remain [Error]:
    skipping must never turn a contradiction into a silent winner. *)
val of_toml_string_lenient
  :  source:string
  -> string
  -> (t * skipped_entry list, string) result

(** Lenient variant of {!load_file}; see {!of_toml_string_lenient}. *)
val load_file_lenient : string -> (t * skipped_entry list, string) result
```

- [ ] **Step 4: Verify at the CI boundary**

No local build (constitution). Type/behavior verification happens in Task 3's CI run. Before committing, re-read the full diff of the two files checking: (a) strict `parse_table_array`, `catalog_of_toml`, `load_file`, `of_toml_string` bodies are untouched; (b) `parse_catalog` behavior is unchanged by the refactor (same error strings, same order); (c) no unused variable warnings would fire (e.g. `Some _ | None` catch-all in `skipped_entry_label`).

- [ ] **Step 5: Commit**

```bash
git add packages/agent_core/lib/llm_provider/model_catalog.ml packages/agent_core/lib/llm_provider/model_catalog.mli
git commit -m "feat(model-catalog): add lenient overlay load that skips poisoned rows"
```

---

### Task 2: Bootstrap defaults to lenient + per-row WARN

**Files:**
- Modify: `lib/server/server_runtime_bootstrap.ml:102-121`
- Modify: `lib/server/server_runtime_bootstrap.mli:29-43`
- Test: `test/test_server_runtime_bootstrap.ml` (stub sites at current lines 334-336, 356-358, 426; new tests after line 387; registration after line 4811)

- [ ] **Step 1: Update the 3 stub call sites to the new loader shape**

The `~load_catalog` stub type changes from `string -> (t, string) result` to `string -> (t * skipped_entry list, string) result`. `Error`-returning stubs are unaffected. Three edits in `test/test_server_runtime_bootstrap.ml`:

In `test_model_catalog_overlay_installs_config_root_overlay` (current lines 334-336), change:

```ocaml
        ~load_catalog:(fun path ->
          load_calls := path :: !load_calls;
          Ok Llm_provider.Model_catalog.empty)
```

to:

```ocaml
        ~load_catalog:(fun path ->
          load_calls := path :: !load_calls;
          Ok (Llm_provider.Model_catalog.empty, []))
```

In `test_model_catalog_overlay_absent_is_noop` (current lines 356-358), apply the same change (`Ok Llm_provider.Model_catalog.empty` → `Ok (Llm_provider.Model_catalog.empty, [])`).

In `test_explicit_model_catalog_replacement_precedes_overlay` (current line 426), change `~load_catalog:(fun _ -> Ok overlay)` to `~load_catalog:(fun _ -> Ok (overlay, []))`.

The `Error "parse failed"` stub in `test_model_catalog_overlay_invalid_fails_loud` (line 376) needs no change.

- [ ] **Step 2: Write the failing integration tests**

In `test/test_server_runtime_bootstrap.ml`, insert after `test_model_catalog_overlay_invalid_fails_loud` (after current line 387). These use the **default** loader (real `Model_catalog.load_file_lenient`), so they exercise file read + lenient parse + install together:

```ocaml
let test_model_catalog_overlay_skips_poisoned_entries () =
  with_temp_dir "model-catalog-overlay-lenient" (fun dir ->
    let config_root = Filename.concat dir "config-root" in
    let overlay = Filename.concat config_root "agent-core-models-overlay.toml" in
    mkdir_p config_root;
    write_file
      overlay
      "[[models]]\n\
       id_prefix = \"lenient-good-model\"\n\
       supports_tools = true\n\
       [[models]]\n\
       id_prefix = \"lenient-stale-model\"\n\
       supports_extended_thinking = true\n";
    let installed = ref None in
    let result =
      Server_runtime_bootstrap.configure_agent_core_model_catalog_overlay
        ~config_root
        ~set_overlay:(fun catalog -> installed := Some catalog)
        ()
    in
    (match result with
     | None -> Alcotest.fail "expected config-root overlay resolution"
     | Some path ->
       Alcotest.(check string) "path" (canonical_path overlay) (canonical_path path));
    match !installed with
    | None -> Alcotest.fail "expected the surviving overlay rows to install"
    | Some catalog ->
      Alcotest.(check bool)
        "valid row survives"
        true
        (Option.is_some (Llm_provider.Model_catalog.lookup catalog "lenient-good-model"));
      Alcotest.(check bool)
        "poisoned row skipped"
        true
        (Option.is_none (Llm_provider.Model_catalog.lookup catalog "lenient-stale-model")))

let test_model_catalog_overlay_broken_toml_still_fails_loud () =
  with_temp_dir "model-catalog-overlay-broken-toml" (fun dir ->
    let config_root = Filename.concat dir "config-root" in
    let overlay = Filename.concat config_root "agent-core-models-overlay.toml" in
    mkdir_p config_root;
    write_file overlay "not toml";
    let set_overlay_calls = ref 0 in
    match
      Server_runtime_bootstrap.configure_agent_core_model_catalog_overlay
        ~config_root
        ~set_overlay:(fun (_ : Llm_provider.Model_catalog.t) -> incr set_overlay_calls)
        ()
    with
    | (_ : string option) ->
      Alcotest.fail "expected Config_error for broken-TOML overlay"
    | exception Env_config_core.Config_error message ->
      Alcotest.(check bool)
        "error names overlay path"
        true
        (String_util.contains_substring message "agent-core-models-overlay.toml");
      Alcotest.(check int) "no install" 0 !set_overlay_calls)
```

Register both in the `Alcotest.run` list, immediately after the `"model catalog overlay invalid fails loud"` case (current line 4809-4811):

```ocaml
          Alcotest.test_case
            "model catalog overlay skips poisoned entries"
            `Quick test_model_catalog_overlay_skips_poisoned_entries;
          Alcotest.test_case
            "model catalog overlay broken TOML still fails loud"
            `Quick test_model_catalog_overlay_broken_toml_still_fails_loud;
```

- [ ] **Step 3: Implement the bootstrap change**

In `lib/server/server_runtime_bootstrap.ml`, replace `configure_agent_core_model_catalog_overlay` (current lines 102-121) with:

```ocaml
(* Per-row degradation: a poisoned overlay row (e.g. a stale field left by
   another release) is excluded with one WARN per row instead of failing the
   whole boot — install must not be blocked by config residue. Whole-file
   failures (unreadable, broken TOML, duplicate surviving rows) still raise
   [Config_error], as does the [AGENT_CORE_MODEL_CATALOG] full-replacement
   path, which keeps the strict loader. *)
let configure_agent_core_model_catalog_overlay
      ?config_root
      ?(load_catalog = Llm_provider.Model_catalog.load_file_lenient)
      ?(set_overlay = Llm_provider.Model_catalog.set_global_overlay)
      ()
  =
  match resolve_agent_core_model_catalog_overlay_path ?config_root () with
  | None -> None
  | Some path ->
    (match load_catalog path with
     | Ok (overlay, skipped) ->
       List.iter
         (fun (skip : Llm_provider.Model_catalog.skipped_entry) ->
            Log.Misc.warn
              "model_catalog: overlay %s skipping entry %s: %s"
              path
              skip.entry_label
              skip.skip_reason)
         skipped;
       set_overlay overlay;
       Log.Misc.info
         "model_catalog: deployment overlay %s installed onto embedded catalog"
         path;
       Some path
     | Error detail ->
       raise
         (Env_config_core.Config_error
            (Printf.sprintf "catalog overlay %s: %s" path detail)))
```

- [ ] **Step 4: Update the mli contract**

In `lib/server/server_runtime_bootstrap.mli`, replace the `configure_agent_core_model_catalog_overlay` signature and doc (current lines 29-43) with:

```ocaml
val configure_agent_core_model_catalog_overlay :
  ?config_root:string ->
  ?load_catalog:(string ->
    (Llm_provider.Model_catalog.t * Llm_provider.Model_catalog.skipped_entry list, string) result) ->
  ?set_overlay:(Llm_provider.Model_catalog.t -> unit) ->
  unit ->
  string option
(** Install the deployment capability overlay (RFC-0342 D1 / Agent Core contract).
    Resolves config-root [agent-core-models-overlay.toml] only; there is no parent
    or env fallback. Rows that fail to parse are skipped with one WARN per row and
    the surviving rows are installed with [Model_catalog.set_global_overlay], so
    [Model_catalog.global] serves the embedded catalog merged with the
    deployment's delta rows; config residue from another release must not block
    boot. An explicit [AGENT_CORE_MODEL_CATALOG] installed by
    {!configure_agent_core_model_catalog_env} keeps replacement precedence over
    the overlay. Returns the installed overlay path. An unreadable file, broken
    TOML, or duplicate identities among surviving rows raise
    [Env_config_core.Config_error] (fail-loud at boot, same as the full-catalog
    path). *)
```

- [ ] **Step 5: Verify at the CI boundary**

No local build (constitution). Re-read the full diff checking: (a) production callers (`bin/main_eio.ml` ×3, `bin/fusion_run.ml:510`, `bin/keeper_capability_probe_cli.ml:397`, `bin/masc_lane_cli_probe.ml:117`, `bin/masc_cli_runtime_sample.ml:111`, `lib/server/server_runtime_bootstrap.ml:587`, `test/test_exact_output_catalog_precedence.ml:868`) all use default arguments, so none need edits; (b) `configure_agent_core_model_catalog_env` still defaults to strict `Model_catalog.load_file`; (c) the WARN fires before `set_overlay` so a skipped row is never silently installed.

- [ ] **Step 6: Commit**

```bash
git add lib/server/server_runtime_bootstrap.ml lib/server/server_runtime_bootstrap.mli test/test_server_runtime_bootstrap.ml
git commit -m "feat(server): boot past poisoned model-catalog overlay rows with per-row WARN"
```

---

### Task 3: Push, PR, CI boundary, review handoff

- [ ] **Step 1: Create branch and push**

```bash
git fetch origin
git switch -c feat/overlay-lenient-load origin/main
# (Tasks 1-2 were committed on this branch — if work happened on a detached
#  or local main, cherry-pick the two commits onto this branch instead.)
git push -u origin feat/overlay-lenient-load
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "feat: degrade poisoned model-catalog overlay rows to warn-and-skip" --body "$(cat <<'EOF'
## Why
v0.35.2 install on a second machine was fully blocked: a stale `.masc/config/agent-core-models-overlay.toml` (unknown fields like `supports_extended_thinking` from a dev build) made `configure_agent_core_model_catalog_overlay` raise `Config_error`, so the server refused to boot and `masc setup` reported a misleading "Model connection failed".

## What
- agent_core `Model_catalog` gains `load_file_lenient`/`of_toml_string_lenient`: valid rows apply, poisoned rows are returned as `(label, reason)` skips.
- `Server_runtime_bootstrap.configure_agent_core_model_catalog_overlay` defaults to the lenient loader and emits one WARN per skipped row.
- Still fail-closed (unchanged): unreadable file, broken TOML, duplicate identities among surviving rows, and the `AGENT_CORE_MODEL_CATALOG` full-replacement path (strict `load_file`).
- Strict `Model_catalog.load_file` is untouched.

Spec: `docs/superpowers/specs/2026-09-10-dead-server-resilience-design.md` (PR A). Plan: `docs/superpowers/plans/2026-09-10-overlay-lenient-load.md`.

## Tests
- Inline: lenient load keeps valid rows / skips all-poisoned / broken TOML fail-closed / duplicate survivors fail-closed / positional label for unreadable id.
- Alcotest: end-to-end via default loader — poisoned overlay installs surviving rows only; broken TOML still raises `Config_error`.
EOF
)"
```

- [ ] **Step 3: CI boundary + review handoff**

Per the constitution execution protocol: do not poll CI. Move on to the next plan (PR B — setup error attribution) while CI runs, and dispatch an adversarial review agent on this PR's diff in parallel. When CI completes (notification), check `gh pr checks` once; if red, read the failing log and fix on the branch.

---

## Self-review notes (already applied)

- Spec coverage: PR A requires (1) lenient path returning skips — Task 1; (2) bootstrap overlay path lenient + WARN per skip — Task 2; (3) broken/unreadable overlay stays fatal — `parse_catalog_with` wrapper unchanged + `broken_toml_still_fails_loud` test; (4) full-replacement path stays strict — `configure_agent_core_model_catalog_env` untouched. All covered.
- Decision flagged for review: duplicate identities among surviving rows stay `Error` (fail-closed) even in lenient mode — they are an authoring contradiction that decides pricing, not schema drift. Called out in plan + mli doc so the reviewer can push back.
- Type consistency: `skipped_entry` fields `entry_label`/`skip_reason` used identically in ml, mli, bootstrap, and tests. Loader type `string -> (t * skipped_entry list, string) result` identical in mli/ml/stubs.
- WARN content is asserted indirectly (skip list unit tests + surviving-catalog integration tests); there is no log-capture helper in this test suite, so no direct log assertion is added.
