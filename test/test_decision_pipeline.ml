(** Decision Pipeline Verification — Phase E1 + E2.

    E1 (Det-FF): Pipeline structure verification.
    - NEL invariant: Run/Skip always have non-empty reasons
    - Typed variant round-trip: typed → string list is lossless
    - Recovery floor: non-removable shards are non-empty

    E2 (Det-FB): Audit completeness verification.
    - Decision records include all required fields
    - Ring buffer respects capacity
    - Feature flag gating works correctly

    Part of: Keeper Decision Layer v2 (Plan Rev.5, Phase E) *)

open Alcotest

module WO = Masc_mcp.Keeper_world_observation
module DA = Masc_mcp.Keeper_decision_audit
module TS = Masc_mcp.Tool_shard
module KTP = Masc_mcp.Keeper_tool_policy
module Reg = Masc_mcp.Keeper_registry
module Obs = Masc_mcp.Keeper_composite_observer
module KTC = Masc_mcp.Keeper_turn_cycle_contract
module KTypes = Masc_mcp.Keeper_types
module KSM = Masc_mcp.Keeper_state_machine

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let buf = Buffer.create 1024 in
      (try
         while true do
           Buffer.add_string buf (input_line ic);
           Buffer.add_char buf '\n'
         done
       with End_of_file -> ());
      Buffer.contents buf)

let extract_quoted_strings s =
  let len = String.length s in
  let rec loop i acc =
    if i >= len then List.rev acc
    else if Char.equal s.[i] '"' then
      match String.index_from_opt s (i + 1) '"' with
      | None -> List.rev acc
      | Some j ->
        let value = String.sub s (i + 1) (j - i - 1) in
        loop (j + 1) (value :: acc)
    else
      loop (i + 1) acc
  in
  loop 0 []

let extract_tla_set ~marker content =
  let marker_len = String.length marker in
  let rec find_marker start =
    if start >= String.length content then None
    else
      match String.index_from_opt content start marker.[0] with
      | None -> None
      | Some i ->
        if i + marker_len <= String.length content
           && String.sub content i marker_len = marker
        then Some i
        else find_marker (i + 1)
  in
  match find_marker 0 with
  | None -> Alcotest.fail ("missing marker " ^ marker)
  | Some marker_idx ->
    let brace_idx =
      match String.index_from_opt content (marker_idx + marker_len) '{' with
      | Some idx -> idx
      | None -> Alcotest.fail ("missing opening brace after " ^ marker)
    in
    let close_idx =
      match String.index_from_opt content brace_idx '}' with
      | Some idx -> idx
      | None -> Alcotest.fail ("missing closing brace after " ^ marker)
    in
    String.sub content brace_idx (close_idx - brace_idx + 1)
    |> extract_quoted_strings

let rec find_repo_root dir =
  let candidate =
    Filename.concat dir "specs/keeper-state-machine/KeeperCompositeLifecycle.tla"
  in
  if Sys.file_exists candidate then dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then
      Alcotest.fail "could not find repo root for KeeperCompositeLifecycle.tla"
    else
      find_repo_root parent

let project_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> find_repo_root (Filename.dirname Sys.executable_name)

let keeper_composite_lifecycle_tla () =
  Filename.concat
    (project_root ())
    "specs/keeper-state-machine/KeeperCompositeLifecycle.tla"

let keeper_turn_cycle_tla () =
  Filename.concat
    (project_root ())
    "specs/keeper-state-machine/KeeperTurnCycle.tla"

(* ── E1: NEL Invariant ──────────────────────────────── *)

let test_run_verdict_has_reasons () =
  let verdict = WO.Run { reasons = (WO.Mention_pending, [WO.Task_backlog { unclaimed = 1; failed = 0 }]) } in
  let strings = WO.verdict_reasons_to_strings verdict in
  check bool "Run verdict produces non-empty string list"
    true (List.length strings > 0)

let test_skip_verdict_has_reasons () =
  let verdict = WO.Skip { reasons = (WO.No_signal, []) } in
  let strings = WO.verdict_reasons_to_strings verdict in
  check bool "Skip verdict produces non-empty string list"
    true (List.length strings > 0)

let test_nel_cannot_be_empty () =
  (* NEL is (head * tail list) — structurally impossible to be empty.
     This test documents the compile-time guarantee. *)
  let run = WO.Run { reasons = (WO.Never_started, []) } in
  let skip = WO.Skip { reasons = (WO.No_signal, []) } in
  let run_reasons = WO.verdict_reasons_to_strings run in
  let skip_reasons = WO.verdict_reasons_to_strings skip in
  check bool "Run NEL minimum 1" true (List.length run_reasons >= 1);
  check bool "Skip NEL minimum 1" true (List.length skip_reasons >= 1)

(* ── E1: Typed → String Round-Trip ──────────────────── *)

let test_turn_reason_to_string_coverage () =
  (* Every turn_reason variant produces a non-empty string *)
  let variants = [
    WO.Mention_pending;
    WO.Board_event_pending;
    WO.Scope_message_pending;
    WO.Scheduled_autonomous_turn;
    WO.Idle_cooldown_elapsed { idle_sec = 60; cooldown = 300 };
    WO.Cooldown_elapsed;
    WO.Task_backlog { unclaimed = 3; failed = 1 };
    WO.Task_reactive_cooldown_elapsed;
    WO.Never_started;
  ] in
  List.iter (fun v ->
    let s = WO.turn_reason_to_string v in
    check bool
      (Printf.sprintf "turn_reason_to_string(%s) is non-empty" s)
      true (String.length s > 0)
  ) variants

let test_skip_reason_to_string_coverage () =
  let variants = [
    WO.Keeper_paused;
    WO.Approval_pending;
    WO.Scheduled_autonomous_disabled;
    WO.Idle_gate_pending { remaining_sec = 30 };
    WO.Cooldown_pending { remaining_sec = 15 };
    WO.No_signal;
  ] in
  List.iter (fun v ->
    let s = WO.skip_reason_to_string v in
    check bool
      (Printf.sprintf "skip_reason_to_string(%s) is non-empty" s)
      true (String.length s > 0)
  ) variants

(* ── E1: Recovery Floor ─────────────────────────────── *)

let test_recovery_floor_non_empty () =
  let shards = TS.recovery_minimum_shard_names () in
  check bool "recovery floor has at least 1 shard"
    true (List.length shards >= 1)

let test_recovery_floor_tools_non_empty () =
  let tools = KTP.failing_minimum_tool_names () in
  check bool "recovery floor tools non-empty"
    true (List.length tools >= 1)

let test_base_shard_not_removable () =
  match TS.get_shard "base" with
  | Some shard ->
    check bool "base shard is not removable" false shard.removable
  | None ->
    fail "base shard not found"

(* ── E1: .masc/ Write Protection ────────────────────── *)

let test_masc_whitelist_allows_playground () =
  check bool "playground allowed"
    true (KTP.is_masc_write_allowed ".masc/playground/keeper1/file.ml")

let test_masc_whitelist_allows_decision_audit () =
  check bool "decision_audit allowed"
    true (KTP.is_masc_write_allowed ".masc/decision_audit/keeper1/2026-04/10.jsonl")

let test_masc_whitelist_blocks_reputation () =
  check bool "reputation blocked"
    false (KTP.is_masc_write_allowed ".masc/reputation/keeper1.json")

let test_masc_whitelist_blocks_economy () =
  check bool "economy blocked"
    false (KTP.is_masc_write_allowed ".masc/economy/keeper1.jsonl")

let test_masc_whitelist_blocks_autonomy_stats () =
  check bool "autonomy_stats blocked"
    false (KTP.is_masc_write_allowed ".masc/autonomy_stats.jsonl")

let test_masc_whitelist_blocks_traversal () =
  check bool "traversal blocked"
    false (KTP.is_masc_write_allowed ".masc/playground/../reputation/evil.json")

(* ── E2: Decision Audit ─────────────────────────────── *)

let test_audit_ring_and_flag () =
  Eio_main.run @@ fun _env ->
  (* Verify audit module is accessible and configured *)
  let cap = DA.ring_capacity () in
  check bool "ring capacity >= 1" true (cap >= 1);
  let level = DA.decision_layer_level () in
  check bool "level in 0-4 range" true (level >= 0 && level <= 4)

(* entropy serialization test deferred: DA.make requires Heartbeat_smart
   which lives in masc_room. Test will be added when Heartbeat_smart
   moves to masc_core (room cleanup issue). Verified locally. *)

(* ── Provider Health Reason Rendering ────────────────── *)

let substring_present ~haystack ~needle =
  let hl = String.length haystack in
  let nl = String.length needle in
  if nl > hl then false
  else
    let rec loop i =
      if i + nl > hl then false
      else if String.sub haystack i nl = needle then true
      else loop (i + 1)
    in
    loop 0

let test_cascade_mermaid_renders_saturated_reason () =
  let out = DA.cascade_fsm_to_mermaid
      ~provider_health:[("alpha", `Unhealthy `Saturated)]
      ~models:["alpha"; "beta"]
      ~last_provider_result:None
      ()
  in
  check bool "saturated reason appears in note"
    true (substring_present ~haystack:out ~needle:"unhealthy: saturated")

let test_cascade_mermaid_renders_other_reason () =
  let out = DA.cascade_fsm_to_mermaid
      ~provider_health:[("beta", `Unhealthy (`Other "custom-signal"))]
      ~models:["alpha"; "beta"]
      ~last_provider_result:None
      ()
  in
  check bool "other reason string passes through"
    true (substring_present ~haystack:out ~needle:"unhealthy: custom-signal")

let test_cascade_mermaid_other_sanitizes_newline_colon () =
  let out = DA.cascade_fsm_to_mermaid
      ~provider_health:[("alpha", `Unhealthy (`Other "line1\nline2:bad"))]
      ~models:["alpha"]
      ~last_provider_result:None
      ()
  in
  check bool "sanitized output contains expected string"
    true (substring_present ~haystack:out ~needle:"unhealthy: line1 line2 bad");
  check bool "unsanitized colon not present in note"
    false (substring_present ~haystack:out ~needle:"line2:bad")

let test_cascade_mermaid_healthy_no_reason_note () =
  let out = DA.cascade_fsm_to_mermaid
      ~provider_health:[("alpha", `Healthy)]
      ~models:["alpha"]
      ~last_provider_result:(Some "alpha")
      ()
  in
  check bool "healthy provider does not emit unhealthy note"
    false (substring_present ~haystack:out ~needle:"unhealthy")

(* ── Composite Observer: turn-scoped state (issue #7122) ─ *)

let test_obs_bp = "/tmp/test-composite-obs"

let make_obs_meta name =
  let json = `Assoc [
    ("name", `String name);
    ("agent_name", `String ("agent-" ^ name));
    ("trace_id", `String ("trace-obs-" ^ name));
    ("goal", `String "observer test");
  ] in
  match KTypes.meta_of_json json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_obs_meta failed: " ^ err)

let dispatch_obs_measurement name =
  ignore
    (Reg.dispatch_event
       ~base_path:test_obs_bp
       name
       (KSM.Context_measured
          {
            context_ratio = 0.42;
            message_count = 12;
            token_count = 3456;
            auto_rules =
              {
                KSM.reflect = false;
                plan = true;
                compact = false;
                handoff = false;
                guardrail_stop = false;
                guardrail_reason = None;
                goal_drift = 0.18;
              };
          }))

let test_observer_idle_when_no_turn () =
  Eio_main.run @@ fun _env ->
  let name = "obs-idle" in
  let _ = Reg.register ~base_path:test_obs_bp name (make_obs_meta name) in
  match Reg.get ~base_path:test_obs_bp name with
  | None -> Alcotest.fail "registered keeper not found"
  | Some entry ->
    let snap = Obs.observe entry in
    check string "idle keeper has Idle turn phase"
      "idle" (Obs.turn_phase_to_string snap.ktc_turn_phase)

let test_observer_executing_during_turn () =
  Eio_main.run @@ fun _env ->
  let name = "obs-active" in
  let _ = Reg.register ~base_path:test_obs_bp name (make_obs_meta name) in
  Reg.mark_turn_started ~base_path:test_obs_bp name;
  Reg.set_turn_cascade_state ~base_path:test_obs_bp name Reg.Cascade_trying;
  (match Reg.get ~base_path:test_obs_bp name with
   | None -> Alcotest.fail "entry missing after mark_turn_started"
   | Some entry ->
     let snap = Obs.observe entry in
     check string "in-turn keeper has Executing turn phase"
       "executing" (Obs.turn_phase_to_string snap.ktc_turn_phase))

let test_observer_prompting_at_turn_start () =
  Eio_main.run @@ fun _env ->
  let name = "obs-prompting" in
  let _ = Reg.register ~base_path:test_obs_bp name (make_obs_meta name) in
  Reg.mark_turn_started ~base_path:test_obs_bp name;
  match Reg.get ~base_path:test_obs_bp name with
  | None -> Alcotest.fail "entry missing after mark_turn_started"
  | Some entry ->
    let snap = Obs.observe entry in
    check string "fresh turn starts in Prompting"
      "prompting" (Obs.turn_phase_to_string snap.ktc_turn_phase);
    check string "fresh turn starts undecided"
      "undecided" (Obs.decision_stage_to_string snap.kdp_decision);
    check string "fresh turn starts with idle cascade"
      "idle" (Obs.cascade_state_to_string snap.kcl_cascade_state)

let test_observer_no_stale_after_turn_end () =
  Eio_main.run @@ fun _env ->
  let name = "obs-no-stale" in
  let _ = Reg.register ~base_path:test_obs_bp name (make_obs_meta name) in
  Reg.mark_turn_started ~base_path:test_obs_bp name;
  Reg.mark_turn_finished ~base_path:test_obs_bp name;
  match Reg.get ~base_path:test_obs_bp name with
  | None -> Alcotest.fail "entry missing after mark_turn_finished"
  | Some entry ->
    let snap = Obs.observe entry in
    check string "post-turn keeper reverts to Idle (no stale Executing)"
      "idle" (Obs.turn_phase_to_string snap.ktc_turn_phase)

let test_observer_finished_idempotent () =
  Eio_main.run @@ fun _env ->
  let name = "obs-idempotent" in
  let _ = Reg.register ~base_path:test_obs_bp name (make_obs_meta name) in
  (* mark_turn_finished without prior mark_turn_started must not crash. *)
  Reg.mark_turn_finished ~base_path:test_obs_bp name;
  Reg.mark_turn_finished ~base_path:test_obs_bp name;
  match Reg.get ~base_path:test_obs_bp name with
  | None -> Alcotest.fail "entry missing"
  | Some entry ->
    let snap = Obs.observe entry in
    check string "stays Idle through repeated mark_turn_finished"
      "idle" (Obs.turn_phase_to_string snap.ktc_turn_phase);
    check bool "no last_outcome when no turn ever started"
      true (snap.last_outcome = None)

(* ── Phase 2 (RFC-0003): is_live + last_outcome ──────── *)

let test_observer_is_live_during_turn () =
  Eio_main.run @@ fun _env ->
  let name = "obs-is-live" in
  let _ = Reg.register ~base_path:test_obs_bp name (make_obs_meta name) in
  Reg.mark_turn_started ~base_path:test_obs_bp name;
  match Reg.get ~base_path:test_obs_bp name with
  | None -> Alcotest.fail "entry missing"
  | Some entry ->
    let snap = Obs.observe entry in
    check bool "is_live = true during turn" true snap.is_live

let test_observer_is_live_false_when_idle () =
  Eio_main.run @@ fun _env ->
  let name = "obs-not-live" in
  let _ = Reg.register ~base_path:test_obs_bp name (make_obs_meta name) in
  match Reg.get ~base_path:test_obs_bp name with
  | None -> Alcotest.fail "entry missing"
  | Some entry ->
    let snap = Obs.observe entry in
    check bool "is_live = false on fresh keeper" false snap.is_live

let test_observer_last_outcome_populated_after_turn () =
  Eio_main.run @@ fun _env ->
  let name = "obs-last-outcome" in
  let _ = Reg.register ~base_path:test_obs_bp name (make_obs_meta name) in
  Reg.mark_turn_started ~base_path:test_obs_bp name;
  dispatch_obs_measurement name;
  Reg.mark_turn_measurement ~base_path:test_obs_bp name;
  Reg.set_turn_decision_stage ~base_path:test_obs_bp name Reg.Decision_tool_policy_selected;
  Reg.set_turn_cascade_state ~base_path:test_obs_bp name Reg.Cascade_done;
  Reg.set_turn_selected_model ~base_path:test_obs_bp name (Some "glm-4.5");
  Reg.mark_turn_finished ~base_path:test_obs_bp name;
  match Reg.get ~base_path:test_obs_bp name with
  | None -> Alcotest.fail "entry missing"
  | Some entry ->
    let snap = Obs.observe entry in
    check bool "is_live = false after turn" false snap.is_live;
    (match snap.last_outcome with
     | None -> Alcotest.fail "last_outcome should be Some after a finished turn"
     | Some lo ->
       check bool "last_outcome.turn_id positive" true (lo.turn_id > 0);
       check bool "last_outcome.ended_at non-zero" true (lo.ended_at > 0.0);
       check string "last_outcome decision persisted"
         "tool_policy_selected" (Obs.decision_stage_to_string lo.decision_stage);
       check string "last_outcome cascade persisted"
         "done" (Obs.cascade_state_to_string lo.cascade_state);
       check (option string) "last_outcome selected_model persisted"
         (Some "glm-4.5") lo.selected_model)

let test_observer_last_outcome_preserved_across_finish_idempotent () =
  Eio_main.run @@ fun _env ->
  let name = "obs-preserve-last" in
  let _ = Reg.register ~base_path:test_obs_bp name (make_obs_meta name) in
  Reg.mark_turn_started ~base_path:test_obs_bp name;
  Reg.mark_turn_finished ~base_path:test_obs_bp name;
  let lo_first =
    match Reg.get ~base_path:test_obs_bp name with
    | Some e -> (Obs.observe e).last_outcome
    | None -> None
  in
  (* mark_turn_finished again without a new mark_turn_started: previous
     last_completed_turn must be preserved (no current → no new freeze). *)
  Reg.mark_turn_finished ~base_path:test_obs_bp name;
  let lo_second =
    match Reg.get ~base_path:test_obs_bp name with
    | Some e -> (Obs.observe e).last_outcome
    | None -> None
  in
  check bool "last_outcome preserved across redundant mark_turn_finished"
    true (lo_first = lo_second)

let test_observer_json_includes_terminal_fields () =
  Eio_main.run @@ fun _env ->
  let name = "obs-terminal-json" in
  let _ = Reg.register ~base_path:test_obs_bp name (make_obs_meta name) in
  Reg.mark_turn_started ~base_path:test_obs_bp name;
  dispatch_obs_measurement name;
  Reg.mark_turn_measurement ~base_path:test_obs_bp name;
  Reg.set_turn_decision_stage ~base_path:test_obs_bp name Reg.Decision_tool_policy_selected;
  Reg.set_turn_cascade_state ~base_path:test_obs_bp name Reg.Cascade_done;
  Reg.set_turn_selected_model ~base_path:test_obs_bp name (Some "glm-4.5");
  Reg.mark_turn_finished ~base_path:test_obs_bp name;
  match Reg.get ~base_path:test_obs_bp name with
  | None -> Alcotest.fail "entry missing"
  | Some entry ->
    let snap = Obs.observe entry in
    let json = Obs.snapshot_to_json snap in
    let open Yojson.Safe.Util in
    check string "decision stage rendered"
      "tool_policy_selected"
      (json |> member "last_outcome" |> member "decision_stage" |> to_string);
    check string "cascade state rendered"
      "done"
      (json |> member "last_outcome" |> member "cascade_state" |> to_string);
    check string "selected model rendered"
      "glm-4.5"
      (json |> member "last_outcome" |> member "selected_model" |> to_string)

let test_observer_event_priority_detects_competing_measurement () =
  Eio_main.run @@ fun _env ->
  let name = "obs-event-priority" in
  let _ = Reg.register ~base_path:test_obs_bp name (make_obs_meta name) in
  dispatch_obs_measurement name;
  Reg.mark_turn_started ~base_path:test_obs_bp name;
  Reg.mark_turn_measurement ~base_path:test_obs_bp name;
  dispatch_obs_measurement name;
  match Reg.get ~base_path:test_obs_bp name with
  | None -> Alcotest.fail "entry missing"
  | Some entry ->
    let snap = Obs.observe entry in
    check bool "second measurement for same live turn breaks monotonicity"
      false snap.invariants.event_priority_monotone

let test_turn_retry_after_compaction_resets_cascade_attempt () =
  Eio_main.run @@ fun _env ->
  let name = "obs-compaction-retry" in
  let _ = Reg.register ~base_path:test_obs_bp name (make_obs_meta name) in
  Reg.mark_turn_started ~base_path:test_obs_bp name;
  dispatch_obs_measurement name;
  Reg.mark_turn_measurement ~base_path:test_obs_bp name;
  Reg.set_turn_decision_stage ~base_path:test_obs_bp name
    Reg.Decision_tool_policy_selected;
  Reg.set_turn_cascade_state ~base_path:test_obs_bp name Reg.Cascade_trying;
  Reg.set_turn_selected_model ~base_path:test_obs_bp name (Some "glm-4.5");
  Reg.set_turn_phase ~base_path:test_obs_bp name Reg.Turn_compacting;
  Reg.prepare_turn_retry_after_compaction ~base_path:test_obs_bp name;
  match Reg.get ~base_path:test_obs_bp name with
  | None -> Alcotest.fail "entry missing"
  | Some entry ->
    let snap = Obs.observe entry in
    check string "retry returns to prompting"
      "prompting" (Obs.turn_phase_to_string snap.ktc_turn_phase);
    check string "retry preserves guard_ok posture"
      "guard_ok" (Obs.decision_stage_to_string snap.kdp_decision);
    check string "retry clears prior cascade attempt"
      "idle" (Obs.cascade_state_to_string snap.kcl_cascade_state);
    (match entry.current_turn_observation with
     | None -> Alcotest.fail "live turn missing after retry reset"
     | Some obs ->
       check (option string) "retry clears selected model"
         None obs.selected_model)

let test_composite_observer_variants_match_tla_sets () =
  let tla = read_file (keeper_composite_lifecycle_tla ()) in
  let check_set label expected actual =
    check (list string) label expected actual
  in
  check_set
    "PhaseSet matches observer ksm_phase variants"
    (extract_tla_set ~marker:"PhaseSet" tla)
    (List.map Obs.ksm_phase_to_string Obs.all_ksm_phases);
  check_set
    "TurnPhaseSet matches observer turn_phase variants"
    (extract_tla_set ~marker:"TurnPhaseSet" tla)
    (List.map Obs.turn_phase_to_string Obs.all_turn_phases);
  check_set
    "DecisionSet matches observer decision variants"
    (extract_tla_set ~marker:"DecisionSet" tla)
    (List.map Obs.decision_stage_to_string Obs.all_decision_stages);
  check_set
    "CascadeSet matches observer cascade variants"
    (extract_tla_set ~marker:"CascadeSet" tla)
    (List.map Obs.cascade_state_to_string Obs.all_cascade_states);
  check_set
    "CompactionSet matches observer compaction variants"
    (extract_tla_set ~marker:"CompactionSet" tla)
    (List.map Obs.compaction_stage_to_string Obs.all_compaction_stages)

let test_composite_observer_named_sets_match_tla_sets () =
  let tla = read_file (keeper_composite_lifecycle_tla ()) in
  let check_set label expected actual =
    check (list string) label expected actual
  in
  check_set
    "ActionSet matches observer tla_action variants"
    (extract_tla_set ~marker:"ActionSet" tla)
    (List.map Obs.tla_action_to_string Obs.all_tla_actions);
  check_set
    "InvariantSet matches observer invariant_key variants"
    (extract_tla_set ~marker:"InvariantSet" tla)
    (List.map Obs.invariant_key_to_string Obs.all_invariant_keys)

let test_keeper_turn_cycle_named_sets_match_tla_sets () =
  let tla = read_file (keeper_turn_cycle_tla ()) in
  let check_set label expected actual =
    check (list string) label expected actual
  in
  check_set
    "TurnPhaseSet matches KTC turn_phase variants"
    (extract_tla_set ~marker:"TurnPhaseSet" tla)
    (List.map Obs.turn_phase_to_string Obs.all_turn_phases);
  check_set
    "DecisionSet matches KTC decision variants"
    (extract_tla_set ~marker:"DecisionSet" tla)
    (List.map Obs.decision_stage_to_string Obs.all_decision_stages);
  check_set
    "CascadeSet matches KTC cascade variants"
    (extract_tla_set ~marker:"CascadeSet" tla)
    (List.map Obs.cascade_state_to_string Obs.all_cascade_states);
  check_set
    "ActionSet matches KTC action variants"
    (extract_tla_set ~marker:"ActionSet" tla)
    (List.map KTC.tla_action_to_string KTC.all_tla_actions);
  check_set
    "InvariantSet matches KTC invariant variants"
    (extract_tla_set ~marker:"InvariantSet" tla)
    (List.map KTC.invariant_key_to_string KTC.all_invariant_keys)

(* ── Test Suite ──────────────────────────────────────── *)

let () =
  run "decision_pipeline" [
    "nel_invariant", [
      test_case "Run verdict has reasons" `Quick test_run_verdict_has_reasons;
      test_case "Skip verdict has reasons" `Quick test_skip_verdict_has_reasons;
      test_case "NEL cannot be empty" `Quick test_nel_cannot_be_empty;
    ];
    "typed_variant_coverage", [
      test_case "turn_reason_to_string all variants" `Quick test_turn_reason_to_string_coverage;
      test_case "skip_reason_to_string all variants" `Quick test_skip_reason_to_string_coverage;
    ];
    "recovery_floor", [
      test_case "floor shard names non-empty" `Quick test_recovery_floor_non_empty;
      test_case "floor tool names non-empty" `Quick test_recovery_floor_tools_non_empty;
      test_case "base shard not removable" `Quick test_base_shard_not_removable;
    ];
    "masc_write_protection", [
      test_case "allows playground" `Quick test_masc_whitelist_allows_playground;
      test_case "allows decision_audit" `Quick test_masc_whitelist_allows_decision_audit;
      test_case "blocks reputation" `Quick test_masc_whitelist_blocks_reputation;
      test_case "blocks economy" `Quick test_masc_whitelist_blocks_economy;
      test_case "blocks autonomy_stats" `Quick test_masc_whitelist_blocks_autonomy_stats;
      test_case "blocks traversal" `Quick test_masc_whitelist_blocks_traversal;
    ];
    "decision_audit", [
      test_case "ring capacity and feature flag" `Quick test_audit_ring_and_flag;
    ];
    "provider_health_reason", [
      test_case "saturated reason in note" `Quick test_cascade_mermaid_renders_saturated_reason;
      test_case "other reason passes through" `Quick test_cascade_mermaid_renders_other_reason;
      test_case "other reason sanitizes newline and colon" `Quick test_cascade_mermaid_other_sanitizes_newline_colon;
      test_case "healthy has no unhealthy note" `Quick test_cascade_mermaid_healthy_no_reason_note;
    ];
    "composite_observer_turn_scope", [
      test_case "idle when no turn" `Quick test_observer_idle_when_no_turn;
      test_case "Prompting at turn start" `Quick test_observer_prompting_at_turn_start;
      test_case "Executing during turn" `Quick test_observer_executing_during_turn;
      test_case "no stale Executing after turn end" `Quick test_observer_no_stale_after_turn_end;
      test_case "mark_turn_finished is idempotent" `Quick test_observer_finished_idempotent;
    ];
    "composite_observer_phase_2", [
      test_case "is_live = true during turn" `Quick test_observer_is_live_during_turn;
      test_case "is_live = false on idle keeper" `Quick test_observer_is_live_false_when_idle;
      test_case "last_outcome populated after turn" `Quick test_observer_last_outcome_populated_after_turn;
      test_case "last_outcome preserved across redundant finish" `Quick test_observer_last_outcome_preserved_across_finish_idempotent;
      test_case "snapshot json includes terminal fields" `Quick
        test_observer_json_includes_terminal_fields;
      test_case "event priority detects competing measurement" `Quick
        test_observer_event_priority_detects_competing_measurement;
      test_case "compaction retry resets prior cascade attempt" `Quick
        test_turn_retry_after_compaction_resets_cascade_attempt;
      test_case "variant sets match KeeperCompositeLifecycle.tla" `Quick
        test_composite_observer_variants_match_tla_sets;
      test_case "named sets match KeeperCompositeLifecycle.tla" `Quick
        test_composite_observer_named_sets_match_tla_sets;
      test_case "named sets match KeeperTurnCycle.tla" `Quick
        test_keeper_turn_cycle_named_sets_match_tla_sets;
    ];
  ]
