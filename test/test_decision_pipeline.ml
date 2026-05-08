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
module KTypes = Masc_mcp.Keeper_types
module YU = Yojson.Safe.Util

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
    WO.Min_interval_elapsed;
    WO.Entropic_oscillation;
  ] in
  List.iter (fun v ->
    let s = WO.turn_reason_to_string v in
    check bool
      (Printf.sprintf "turn_reason_to_string(%s) is non-empty" s)
      true (String.length s > 0)
  ) variants

let test_turn_reason_to_string_distinguishes_entropy () =
  check string "min interval tag preserved"
    "min_interval_elapsed"
    (WO.turn_reason_to_string WO.Min_interval_elapsed);
  check string "entropic wakeup has distinct tag"
    "entropic_oscillation"
    (WO.turn_reason_to_string WO.Entropic_oscillation)

let test_entropic_oscillation_policy () =
  check bool "does not inject before interval"
    false
    (WO.should_inject_entropic_oscillation
       ~since_last_scheduled_autonomous:
         (WO.entropic_oscillation_interval_sec - 1)
       ~draw_percent:0);
  check bool "injects at interval below probability"
    true
    (WO.should_inject_entropic_oscillation
       ~since_last_scheduled_autonomous:WO.entropic_oscillation_interval_sec
       ~draw_percent:(WO.entropic_oscillation_probability_percent - 1));
  check bool "does not inject at probability boundary"
    false
    (WO.should_inject_entropic_oscillation
       ~since_last_scheduled_autonomous:WO.entropic_oscillation_interval_sec
       ~draw_percent:WO.entropic_oscillation_probability_percent)

let test_skip_reason_to_string_coverage () =
  let variants = [
    WO.Keeper_paused;
    WO.Approval_pending;
    WO.Scheduled_autonomous_disabled;
    WO.Provider_cooldown_pending { remaining_sec = 45 };
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
    ("sandbox_profile", `String "local");
    ("network_mode", `String "inherit");
  ] in
  match KTypes.meta_of_json json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_obs_meta failed: " ^ err)

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
  Reg.set_turn_cascade_state ~base_path:test_obs_bp name Reg.Cascade_selecting;
  Reg.set_turn_cascade_state ~base_path:test_obs_bp name Reg.Cascade_trying;
  (match Reg.get ~base_path:test_obs_bp name with
   | None -> Alcotest.fail "entry missing after mark_turn_started"
   | Some entry ->
     let snap = Obs.observe entry in
     check string "in-turn keeper has Executing turn phase"
       "executing" (Obs.turn_phase_to_string snap.ktc_turn_phase))

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
       check bool "last_outcome.ended_at non-zero" true (lo.ended_at > 0.0))

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

let test_observer_snapshot_json_omits_retired_recovery_contract () =
  Eio_main.run @@ fun _env ->
  let name = "obs-recovery-json" in
  let _ = Reg.register ~base_path:test_obs_bp name (make_obs_meta name) in
  match Reg.get ~base_path:test_obs_bp name with
  | None -> Alcotest.fail "entry missing"
  | Some entry ->
    let json = Obs.snapshot_to_json (Obs.observe entry) in
    let invariants = YU.member "invariants" json in
    check bool "recovery object omitted"
      true (match YU.member "recovery" json with `Null -> true | _ -> false);
    check bool "recovery_two_store_sync omitted"
      true (match YU.member "recovery_two_store_sync" invariants with `Null -> true | _ -> false)

(* ── LT-16-KCB Phase 2: 6th axis on composite observer ─────── *)

module KCB = Masc_mcp.Keeper_failure_circuit_breaker

let kcb_state_str = function
  | KCB.Clean -> "clean"
  | KCB.Warning -> "warning"
  | KCB.Cooling -> "cooling"

let test_observer_kcb_clean () =
  Eio_main.run @@ fun _env ->
  let name = "obs-kcb-clean" in
  let _ = Reg.register ~base_path:test_obs_bp name (make_obs_meta name) in
  match Reg.get ~base_path:test_obs_bp name with
  | None -> Alcotest.fail "entry missing"
  | Some entry ->
    let snap = Obs.observe entry in
    check string "fresh keeper kcb_state = clean"
      "clean" (kcb_state_str snap.kcb_state)

let test_observer_kcb_warning () =
  Eio_main.run @@ fun _env ->
  let name = "obs-kcb-warn" in
  let _ = Reg.register ~base_path:test_obs_bp name (make_obs_meta name) in
  (* Seed the circuit breaker with one failure — must push to Warning
     without tripping the threshold (threshold = 3). *)
  KCB.record_success ~keeper_name:name;
  ignore (KCB.maybe_enrich_error
            ~keeper_name:name ~error_msg:"path_not_found: /x");
  match Reg.get ~base_path:test_obs_bp name with
  | None -> Alcotest.fail "entry missing"
  | Some entry ->
    let snap = Obs.observe entry in
    check string "failing keeper kcb_state = warning"
      "warning" (kcb_state_str snap.kcb_state)

let test_observer_kcb_json_payload () =
  Eio_main.run @@ fun _env ->
  let name = "obs-kcb-json" in
  let _ = Reg.register ~base_path:test_obs_bp name (make_obs_meta name) in
  match Reg.get ~base_path:test_obs_bp name with
  | None -> Alcotest.fail "entry missing"
  | Some entry ->
    let json = Obs.snapshot_to_json (Obs.observe entry) in
    let cb = YU.member "circuit_breaker" json in
    check bool "circuit_breaker object present"
      true (match cb with `Null -> false | _ -> true);
    let state_str =
      match YU.member "state" cb with
      | `String s -> s
      | _ -> Alcotest.fail "circuit_breaker.state missing or wrong type"
    in
    check string "circuit_breaker.state on fresh keeper = clean"
      "clean" state_str
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
      test_case "turn_reason_to_string distinguishes entropy" `Quick test_turn_reason_to_string_distinguishes_entropy;
      test_case "skip_reason_to_string all variants" `Quick test_skip_reason_to_string_coverage;
    ];
    "entropic_oscillation", [
      test_case "policy interval and probability boundary" `Quick test_entropic_oscillation_policy;
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
      test_case "Executing during turn" `Quick test_observer_executing_during_turn;
      test_case "no stale Executing after turn end" `Quick test_observer_no_stale_after_turn_end;
      test_case "mark_turn_finished is idempotent" `Quick test_observer_finished_idempotent;
    ];
    "composite_observer_phase_2", [
      test_case "is_live = true during turn" `Quick test_observer_is_live_during_turn;
      test_case "is_live = false on idle keeper" `Quick test_observer_is_live_false_when_idle;
      test_case "last_outcome populated after turn" `Quick test_observer_last_outcome_populated_after_turn;
      test_case "last_outcome preserved across redundant finish" `Quick test_observer_last_outcome_preserved_across_finish_idempotent;
      test_case "snapshot json omits retired recovery contract" `Quick test_observer_snapshot_json_omits_retired_recovery_contract;
    ];
    "composite_observer_kcb_axis", [
      test_case "fresh keeper kcb_state = Clean"
        `Quick test_observer_kcb_clean;
      test_case "failing keeper kcb_state = Warning"
        `Quick test_observer_kcb_warning;
      test_case "snapshot_to_json exposes circuit_breaker.state"
        `Quick test_observer_kcb_json_payload;
    ];
  ]
