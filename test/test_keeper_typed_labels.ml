(** test_keeper_typed_labels — label uniqueness for the keeper-side ADTs
    landed by the bloodflow restoration plan.

    Step 15 (partial): catches the silent regression where two
    constructors of the same ADT collapse to the same string label. A
    label collision would cause Otel_metric_store dimensions to merge across
    distinct semantic states, hiding the very signal these ADTs were
    introduced to make legible.

    Coverage:
    - [Keeper_turn_fsm.cancel_reason] (4 variants, Step 4a)
    - [Keeper_turn_fsm.failure_reason] (6 variants, Step 4a)
    - [Keeper_turn_fsm.turn_state]     (10 variants, Step 4a)
    - [Keeper_contract_classifier.actionable_signal] (3 variants, Step 6a)
    - [Keeper_profile_load_failure_site.t] typed metric labels
    - [Keeper_turn_fsm.pp_failure_reason] surfaces record-bearing fields
*)

open Masc

(* ── Helpers ─────────────────────────────────────────────────── *)

(** Returns the duplicate labels in a list, or [] if all unique. *)
let duplicates labels =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun s ->
      let dup = Hashtbl.mem seen s in
      Hashtbl.replace seen s ();
      dup)
    labels

let format_to_string pp v =
  let buf = Buffer.create 32 in
  let fmt = Format.formatter_of_buffer buf in
  pp fmt v;
  Format.pp_print_flush fmt ();
  Buffer.contents buf

(* ── Keeper_turn_fsm.cancel_reason ───────────────────────────── *)

let all_cancel_reasons : Keeper_turn_fsm.cancel_reason list =
  [
    Cancelled_supervisor_stop;
    Cancelled_external;
    Cancelled_phase_gate_close;
    Cancelled_provider_timeout;
    Cancelled_fleet_shutdown;
    Cancelled_input_required;
  ]

let test_cancel_reason_labels_unique () =
  let labels =
    List.map Keeper_turn_fsm.cancel_reason_label all_cancel_reasons
  in
  Alcotest.(check (list string))
    "no duplicate cancel_reason labels" [] (duplicates labels)

(* ── Keeper_turn_fsm.failure_reason ──────────────────────────── *)

let all_failure_reasons : Keeper_turn_fsm.failure_reason list =
  [
    Failure_runtime_unavailable { base = "x"; resolved = None };
    Failure_no_capable_provider { runtime_id = "x"; detail = "d" };
    Failure_provider_error { kind = "k"; detail = "d" };
    Failure_receipt_lost { primary_error = "e"; fallback_path = None };
    Failure_runtime_error "msg";
    Failure_unexpected_exception { exn = "exn"; backtrace = None };
  ]

let test_failure_reason_labels_unique () =
  let labels =
    List.map Keeper_turn_fsm.failure_reason_label all_failure_reasons
  in
  Alcotest.(check (list string))
    "no duplicate failure_reason labels" [] (duplicates labels)

let test_pp_failure_reason_includes_payload () =
  let s =
    format_to_string Keeper_turn_fsm.pp_failure_reason
      (Failure_runtime_unavailable
         { base = "claude_api"; resolved = Some "claude_code" })
  in
  Alcotest.(check bool)
    "pp_failure_reason surfaces base"
    true
    (try
       ignore (Str.search_forward (Str.regexp_string "claude_api") s 0);
       true
     with Not_found -> false);
  Alcotest.(check bool)
    "pp_failure_reason surfaces resolved"
    true
    (try
       ignore (Str.search_forward (Str.regexp_string "claude_code") s 0);
       true
     with Not_found -> false)

(* ── Keeper_turn_fsm.turn_state ──────────────────────────────── *)

let all_turn_states : Keeper_turn_fsm.any_state list =
  [
    Keeper_turn_fsm.Any Idle;
    Keeper_turn_fsm.Any Phase_gating;
    Keeper_turn_fsm.Any Runtime_routing;
    Keeper_turn_fsm.Any Awaiting_provider;
    Keeper_turn_fsm.Any Streaming;
    Keeper_turn_fsm.Any Awaiting_tool_result;
    Keeper_turn_fsm.Any Completing;
    Keeper_turn_fsm.Any Done;
    Keeper_turn_fsm.Any (Failed (Failure_runtime_error "x"));
    Keeper_turn_fsm.Any (Cancelled Cancelled_supervisor_stop);
  ]

let test_turn_state_labels_unique () =
  let labels = List.map Keeper_turn_fsm.any_state_label all_turn_states in
  Alcotest.(check (list string))
    "no duplicate turn_state labels" [] (duplicates labels)

let test_failed_label_carries_reason () =
  let s =
    Keeper_turn_fsm.any_state_label
      (Keeper_turn_fsm.Any (Failed (Failure_runtime_unavailable { base = "b"; resolved = None })))
  in
  Alcotest.(check string)
    "Failed label uses 'failed:' prefix + reason"
    "failed:runtime_unavailable" s

let test_cancelled_label_carries_reason () =
  let s =
    Keeper_turn_fsm.any_state_label (Keeper_turn_fsm.Any (Cancelled Cancelled_fleet_shutdown))
  in
  Alcotest.(check string)
    "Cancelled label uses 'cancelled:' prefix + reason"
    "cancelled:fleet_shutdown" s

(* ── Keeper_contract_classifier.actionable_signal ────────────── *)

let all_actionable_signals
    : Keeper_contract_classifier.actionable_signal list =
  [
    Has_unclaimed_tasks;
    Has_board_activity;
    No_actionable_signal;
  ]

let test_actionable_signal_labels_unique () =
  let labels =
    List.map Keeper_contract_classifier.actionable_signal_label
      all_actionable_signals
  in
  Alcotest.(check (list string))
    "no duplicate actionable_signal labels" [] (duplicates labels)

(* Precedence is documented contract in [keeper_contract_classifier.mli]:
   unclaimed_tasks > board_activity. The caller in
   [keeper_agent_run.ml] (issue #11266 Track 2c) relies on this ordering
   to attribute violation log lines to the strongest available signal. *)
let test_classify_precedence_unclaimed_dominates_board () =
  let o : Keeper_contract_classifier.world_observation =
    { unclaimed_task_count = 1
    ; board_activity_count = 1
    }
  in
  match Keeper_contract_classifier.classify_actionable_signal o with
  | Has_unclaimed_tasks -> ()
  | other ->
      Alcotest.failf
        "expected Has_unclaimed_tasks (highest precedence), got %s"
        (Keeper_contract_classifier.actionable_signal_label other)

let test_classify_board_signal () =
  let o : Keeper_contract_classifier.world_observation =
    { unclaimed_task_count = 0
    ; board_activity_count = 1
    }
  in
  match Keeper_contract_classifier.classify_actionable_signal o with
  | Has_board_activity -> ()
  | other ->
      Alcotest.failf
        "expected Has_board_activity, got %s"
        (Keeper_contract_classifier.actionable_signal_label other)

let test_classify_no_signal_returns_no_actionable () =
  let o : Keeper_contract_classifier.world_observation =
    { unclaimed_task_count = 0
    ; board_activity_count = 0
    }
  in
  match Keeper_contract_classifier.classify_actionable_signal o with
  | No_actionable_signal -> ()
  | other ->
      Alcotest.failf
        "expected No_actionable_signal, got %s"
        (Keeper_contract_classifier.actionable_signal_label other)

let test_is_actionable_matches_variants () =
  Alcotest.(check bool) "Has_unclaimed_tasks is actionable" true
    (Keeper_contract_classifier.is_actionable Has_unclaimed_tasks);
  Alcotest.(check bool) "Has_board_activity is actionable" true
    (Keeper_contract_classifier.is_actionable Has_board_activity);
  Alcotest.(check bool) "No_actionable_signal is not actionable" false
    (Keeper_contract_classifier.is_actionable No_actionable_signal)

(* ── Keeper_profile_load_failure_site.t ──────────────────────── *)

let all_profile_load_failure_sites : Keeper_profile_load_failure_site.t list =
  [
    Personas_root;
    Personas_dirs_resolve;
    Toml_discovery_error;
    Materializable_check;
    Load_persona_extended;
    Agent_md_read;
    List_persona_summaries;
  ]

let test_profile_load_failure_site_labels_unique () =
  let labels =
    List.map Keeper_profile_load_failure_site.to_label
      all_profile_load_failure_sites
  in
  Alcotest.(check (list string))
    "no duplicate profile load failure site labels"
    []
    (duplicates labels)

let test_materializable_check_site_label () =
  Alcotest.(check string)
    "materializable check label"
    "materializable_check"
    Keeper_profile_load_failure_site.(to_label Materializable_check)

(* ── Test runner ─────────────────────────────────────────────── *)

let () =
  Alcotest.run "keeper_typed_labels"
    [
      ( "cancel_reason",
        [
          Alcotest.test_case "labels unique" `Quick
            test_cancel_reason_labels_unique;
        ] );
      ( "failure_reason",
        [
          Alcotest.test_case "labels unique" `Quick
            test_failure_reason_labels_unique;
          Alcotest.test_case "pp surfaces payload" `Quick
            test_pp_failure_reason_includes_payload;
        ] );
      ( "turn_state",
        [
          Alcotest.test_case "labels unique" `Quick
            test_turn_state_labels_unique;
          Alcotest.test_case "Failed carries reason" `Quick
            test_failed_label_carries_reason;
          Alcotest.test_case "Cancelled carries reason" `Quick
            test_cancelled_label_carries_reason;
        ] );
      ( "actionable_signal",
        [
          Alcotest.test_case "labels unique" `Quick
            test_actionable_signal_labels_unique;
          Alcotest.test_case "precedence: unclaimed > board" `Quick
            test_classify_precedence_unclaimed_dominates_board;
          Alcotest.test_case "board signal" `Quick
            test_classify_board_signal;
          Alcotest.test_case "empty observation → No_actionable_signal" `Quick
            test_classify_no_signal_returns_no_actionable;
          Alcotest.test_case "is_actionable matches all variants" `Quick
            test_is_actionable_matches_variants;
        ] );
      ( "profile_load_failure_site",
        [
          Alcotest.test_case "labels unique" `Quick
            test_profile_load_failure_site_labels_unique;
          Alcotest.test_case "materializable check label" `Quick
            test_materializable_check_site_label;
        ] );
    ]
