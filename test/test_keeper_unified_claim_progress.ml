open Alcotest

module KAR = Masc_mcp.Keeper_agent_run
module KARAC = Masc_mcp.Keeper_agent_run_actionable_contract
module KCC = Masc_mcp.Keeper_contract_classifier
module KIPR = Masc_mcp.Agent_tool_in_process_runtime
module KTO = Masc_mcp.Keeper_tool_outcome
module KTP = Masc_mcp.Keeper_tool_progress

let unclaimed_task_context =
  KCC.make_actionable_signal_context
    ~tool_gate_required:false
    ~actionable_signal:KCC.Has_unclaimed_tasks
;;

let no_actionable_context =
  KCC.make_actionable_signal_context
    ~tool_gate_required:false
    ~actionable_signal:KCC.No_actionable_signal
;;

let contains_substring haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    if i + needle_len > hay_len
    then false
    else if String.sub haystack i needle_len = needle
    then true
    else loop (i + 1)
  in
  needle_len = 0 || loop 0
;;

let test_claim_tool_classification_covers_supported_claim_tools () =
  check
    bool
    "keeper claim is claim tool"
    true
    (KTP.is_claim_tool_name "keeper_task_claim");
  check
    bool
    "masc claim next is claim tool"
    true
    (KTP.is_claim_tool_name "masc_claim_next");
  check
    bool
    "removed claim task alias is not claim tool"
    false
    (KTP.is_claim_tool_name "masc_claim_task");
  check
    bool
    "task creation is not claim tool"
    false
    (KTP.is_claim_tool_name "keeper_task_create");
  check
    bool
    "task list is not claim tool"
    false
    (KTP.is_claim_tool_name "keeper_tasks_list")
;;

let test_claim_contract_result_counts_initial_claim_as_execution () =
  let result ?(had_owned_active_task_at_turn_start = false) tools =
    KAR.tool_contract_result_for_observed_tools
      ~missing_visible_required:[]
      ~had_owned_active_task_at_turn_start
      ~actual_keeper_tool_names:tools
    |> Masc_mcp.Keeper_execution_receipt.tool_contract_result_to_string
  in
  check
    string
    "initial claim is execution progress"
    "satisfied_execution"
    (result [ "keeper_task_claim" ]);
  check
    string
    "initial claim plus passive reads is still progress"
    "satisfied_execution"
    (result [ "keeper_task_claim"; "keeper_tasks_list" ]);
  check
    string
    "claim after already owning task stays diagnostic"
    "claim_only_after_owned_task"
    (result ~had_owned_active_task_at_turn_start:true [ "keeper_task_claim" ]);
  ()
;;

let tool_call_detail ?(outcome = "ok") tool_name : KAR.tool_call_detail =
  { tool_name
  ; provider = "test"
  ; outcome
  ; typed_outcome = None
  ; latency_ms = 1.0
  ; task_id = None
  ; route_evidence = None
  }
;;

let test_contract_progress_filters_no_progress_tool_results () =
  let allowed_tool_names = [ "keeper_task_claim"; "tool_execute" ] in
  let no_progress_only =
    [ tool_call_detail ~outcome:"ok_no_progress" "keeper_task_claim" ]
  in
  check
    (list string)
    "claim-only result is not contract progress"
    []
    (KAR.For_testing.progress_keeper_tool_names_for_contract
       ~allowed_tool_names
       ~actual_keeper_tool_names:[ "keeper_task_claim" ]
       ~tool_calls:no_progress_only);
  check
    (list string)
    "claim remains visible as no-progress success"
    [ "keeper_task_claim" ]
    (KAR.For_testing.no_progress_success_tool_names_for_contract
       ~allowed_tool_names
       ~tool_calls:no_progress_only);
  check
    (list string)
    "follow-up shell keeps the turn as progress"
    [ "tool_execute" ]
    (KAR.For_testing.progress_keeper_tool_names_for_contract
       ~allowed_tool_names
       ~actual_keeper_tool_names:[ "keeper_task_claim"; "tool_execute" ]
       ~tool_calls:
         [ tool_call_detail ~outcome:"ok_no_progress" "keeper_task_claim"
         ; tool_call_detail "tool_execute"
         ])
;;

let test_actionable_tool_contract_allows_execution_tools () =
  check
    (option string)
    "execution tool satisfies actionable signal"
    None
    (KTP.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "tool_execute"; "masc_status" ]
       ());
  check
    (option string)
    "board workspace can satisfy non-owned board signal"
    None
    (KTP.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "keeper_board_comment" ]
       ());
  check
    (option string)
    "owned task board activity counts as workspace progress"
    None
    (KTP.actionable_tool_contract_violation_reason
       ~claim_context_allowed:false
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "keeper_board_post"; "keeper_tasks_list" ]
       ());
  check
    (option string)
    "worktree creation satisfies owned task progress"
    None
    (KTP.actionable_tool_contract_violation_reason
       ~claim_context_allowed:false
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "tool_execute" ]
       ());
  check
    (option string)
    "PR creation satisfies owned task progress"
    None
    (KTP.actionable_tool_contract_violation_reason
       ~claim_context_allowed:false
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "tool_execute" ]
       ());
  check
    (option string)
    "non-actionable no-op remains allowed"
    None
    (KTP.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:no_actionable_context
       ~tool_names:[]
       ())
;;

let test_stay_silent_requires_typed_no_work_proof_on_actionable_signal () =
  check
    bool
    "stay_silent satisfies required contract"
    true
    (KTP.tool_name_can_satisfy_required_contract "keeper_stay_silent");
  check
    bool
    "completion tool set includes stay_silent"
    true
    (KTP.is_completion_tool_name "keeper_stay_silent");
  (match
     KTP.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "keeper_stay_silent"; "keeper_tasks_list" ]
       ()
   with
   | Some reason ->
     check
       bool
       "reason mentions typed no-work proof"
       true
       (contains_substring reason "typed no-work proof")
   | None -> fail "expected stay_silent actionable violation");
  check
    (option string)
    "execution plus stay_silent remains accepted"
    None
    (KTP.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "keeper_board_comment"; "keeper_stay_silent" ]
       ());
  check
    (option string)
    "owned-task progress plus stay_silent remains accepted"
    None
    (KTP.actionable_tool_contract_violation_reason
       ~claim_context_allowed:false
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "tool_execute"; "keeper_stay_silent" ]
       ());
  check
    (option string)
    "non-actionable stay_silent remains allowed"
    None
    (KTP.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:no_actionable_context
       ~tool_names:[ "keeper_stay_silent" ]
       ());
  check
    bool
    "passive-only still violates"
    true
    (Option.is_some
       (KTP.actionable_tool_contract_violation_reason
          ~claim_context_allowed:true
          ~actionable_signal_context:unclaimed_task_context
          ~tool_names:[ "keeper_tasks_list"; "masc_status" ]
          ()))
;;

(* Typed no-work proof parsing (the constraint-trap escape carrier). The escape
   only fires when the round-trip from the stay_silent [no_work_reason] arg to a
   [No_progress] outcome holds, so guard both the accept and reject paths. *)
let test_stay_silent_no_work_reason_parsing () =
  List.iter
    (fun reason ->
       match KTO.no_work_reason_of_stay_silent_arg reason with
       | Some (KTO.No_progress _) -> ()
       | Some (KTO.Progress | KTO.Error _) | None ->
         fail (reason ^ ": expected a No_progress proof"))
    KTO.stay_silent_no_work_reasons;
  check
    bool
    "unknown reason yields no proof"
    true
    (Option.is_none (KTO.no_work_reason_of_stay_silent_arg "unrecognized_reason"));
  check
    bool
    "empty reason yields no proof"
    true
    (Option.is_none (KTO.no_work_reason_of_stay_silent_arg ""))
;;

(* The unit-level escape: with a typed proof present, a stay_silent-under-signal
   turn is no longer a violation; without it, it still is. Path-1 (no signal) and
   path-3 (work-ignoring silence still blocked) are covered alongside. *)
let test_stay_silent_typed_proof_escapes_violation () =
  check
    (option string)
    "stay_silent with typed no-work proof completes the turn under a signal"
    None
    (KTP.actionable_tool_contract_violation_reason
       ~stay_silent_has_no_work_proof:true
       ~claim_context_allowed:true
       ~actionable_signal_context:unclaimed_task_context
       ~tool_names:[ "keeper_stay_silent"; "keeper_tasks_list" ]
       ());
  check
    bool
    "bare stay_silent without proof still violates under a signal"
    true
    (Option.is_some
       (KTP.actionable_tool_contract_violation_reason
          ~stay_silent_has_no_work_proof:false
          ~claim_context_allowed:true
          ~actionable_signal_context:unclaimed_task_context
          ~tool_names:[ "keeper_stay_silent"; "keeper_tasks_list" ]
          ()));
  check
    (option string)
    "stay_silent with proof but no signal stays valid"
    None
    (KTP.actionable_tool_contract_violation_reason
       ~stay_silent_has_no_work_proof:true
       ~claim_context_allowed:true
       ~actionable_signal_context:no_actionable_context
       ~tool_names:[ "keeper_stay_silent" ]
       ());
  check
    bool
    "passive-only without stay_silent ignores the proof flag (still violates)"
    true
    (Option.is_some
       (KTP.actionable_tool_contract_violation_reason
          ~stay_silent_has_no_work_proof:true
          ~claim_context_allowed:true
          ~actionable_signal_context:unclaimed_task_context
          ~tool_names:[ "keeper_tasks_list"; "masc_status" ]
          ()))
;;

(* Transport-shape: a [No_progress] typed_outcome embedded on the stay_silent
   tool_call_detail (the value the PostToolUse hook threads from the handler) must
   be read as proof present. A bare stay_silent, a stay_silent with a non-proof
   outcome, or a No_progress outcome on a different tool must all read as absent.
   This is the link the gate depends on; if it silently returns false the entire
   escape no-ops (the of_json / transport-wrap failure mode). *)
let test_stay_silent_no_work_proof_present_reads_typed_outcome () =
  let with_outcome ?(tool_name = "keeper_stay_silent") outcome : KAR.tool_call_detail =
    { (tool_call_detail tool_name) with typed_outcome = outcome }
  in
  let proof = KTO.no_work_reason_of_stay_silent_arg "no_actionable_fit" in
  check
    bool
    "stay_silent with No_progress proof reads as present"
    true
    (KARAC.stay_silent_no_work_proof_present [ with_outcome proof ]);
  check
    bool
    "bare stay_silent reads as absent"
    false
    (KARAC.stay_silent_no_work_proof_present [ tool_call_detail "keeper_stay_silent" ]);
  check
    bool
    "stay_silent with Progress outcome reads as absent"
    false
    (KARAC.stay_silent_no_work_proof_present [ with_outcome (Some KTO.Progress) ]);
  check
    bool
    "No_progress on a non-stay_silent tool does not count as stay_silent proof"
    false
    (KARAC.stay_silent_no_work_proof_present
       [ with_outcome ~tool_name:"keeper_task_claim" proof ])
;;

(* The full transport seam: handler output string -> Keeper_tool_outcome.of_json,
   the exact path the PostToolUse hook runs. of_json is a hand-written string match
   (a missed/typo'd arm silently returns None), so assert the real round-trip, not
   just the in-memory constructor. A bare call emits no proof field. *)
let test_handle_stay_silent_round_trips_typed_outcome () =
  let typed_outcome_of_handler args =
    match Yojson.Safe.from_string (KIPR.handle_stay_silent ~args) with
    | `Assoc fields ->
      (match List.assoc_opt "typed_outcome" fields with
       | Some nested -> KTO.of_json nested
       | None -> None)
    | _ -> None
  in
  (match
     typed_outcome_of_handler (`Assoc [ "no_work_reason", `String "no_actionable_fit" ])
   with
   | Some (KTO.No_progress _) -> ()
   | Some (KTO.Progress | KTO.Error _) | None ->
     fail "handler with recognized reason must emit a No_progress typed_outcome");
  check
    bool
    "bare stay_silent emits no typed_outcome"
    true
    (Option.is_none (typed_outcome_of_handler (`Assoc [])));
  check
    bool
    "unknown reason emits no typed_outcome"
    true
    (Option.is_none
       (typed_outcome_of_handler (`Assoc [ "no_work_reason", `String "bogus" ])))
;;

let () =
  run
    "keeper_unified_claim_progress"
    [ ( "claim_progress"
      , [ test_case
            "claim tool classification covers supported claim tools"
            `Quick
            test_claim_tool_classification_covers_supported_claim_tools
        ; test_case
            "initial claim counts as contract progress"
            `Quick
            test_claim_contract_result_counts_initial_claim_as_execution
        ; test_case
            "contract progress filters no-progress tool results"
            `Quick
            test_contract_progress_filters_no_progress_tool_results
        ; test_case
            "actionable signal allows execution tools"
            `Quick
            test_actionable_tool_contract_allows_execution_tools
        ; test_case
            "stay_silent needs typed no-work proof on actionable signal"
            `Quick
            test_stay_silent_requires_typed_no_work_proof_on_actionable_signal
        ; test_case
            "stay_silent no_work_reason parsing accepts known, rejects unknown"
            `Quick
            test_stay_silent_no_work_reason_parsing
        ; test_case
            "typed no-work proof escapes the stay_silent violation"
            `Quick
            test_stay_silent_typed_proof_escapes_violation
        ; test_case
            "stay_silent proof presence is read from typed_outcome"
            `Quick
            test_stay_silent_no_work_proof_present_reads_typed_outcome
        ; test_case
            "handle_stay_silent round-trips typed_outcome through of_json"
            `Quick
            test_handle_stay_silent_round_trips_typed_outcome
        ] )
    ]
;;
