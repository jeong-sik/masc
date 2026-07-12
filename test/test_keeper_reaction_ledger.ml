open Alcotest
open Masc
open Yojson.Safe.Util

let with_temp_base f =
  let base_path = Filename.temp_file "masc-krl-" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o755;
  f base_path
;;

let board_payload ?updated_at ~post_id:(_ : string) () :
  Keeper_event_queue.stimulus_payload
  =
  Keeper_event_queue.Board_signal
    { kind = Keeper_event_queue.Post_created
    ; author = "operator"
    ; title = "Ship reaction ledger"
    ; content = "Please react"
    ; hearth = None
    ; updated_at
    }
;;

let board_stimulus ?(post_id = "post-42") ?updated_at () :
  Keeper_event_queue.stimulus
  =
  { post_id
  ; urgency = Immediate
  ; arrived_at = 1234.5
  ; payload = board_payload ?updated_at ~post_id ()
  }
;;

let no_progress_recovery_stimulus ?(keeper_name = "no-progress-keeper") () :
  Keeper_event_queue.stimulus
  =
  { post_id = "no-progress-loop:" ^ keeper_name
  ; urgency = Immediate
  ; arrived_at = 1234.5
  ; payload = Keeper_event_queue.No_progress_recovery
  }
;;

let fusion_completed_stimulus ?(run_id = "fus-ledger-1") () :
  Keeper_event_queue.stimulus
  =
  { post_id = "fusion-run:" ^ run_id
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = 1234.5
  ; payload =
      Keeper_event_queue.Fusion_completed
        { run_id; ok = true; resolved_answer = "use approach B"; board_post_id = "post-fus" }
  }
;;

let schedule_due_stimulus ?(schedule_id = "sched-ledger-1") () :
  Keeper_event_queue.stimulus
  =
  { post_id = "schedule-due:" ^ schedule_id
  ; urgency = Keeper_event_queue.Immediate
  ; arrived_at = 1234.5
  ; payload =
      Keeper_event_queue.Schedule_due
        { schedule_id
        ; due_at = 1200.0
        ; payload_digest = "payload-digest"
        ; title = Some "Wake"
        ; message = "Scheduled lane wake"
        }
  }
;;

let failure_judgment_stimulus () : Keeper_event_queue.stimulus =
  let judgment : Keeper_event_queue.failure_judgment =
    { fj_runtime_id = "failed-runtime"
    ; fj_judgment = Keeper_runtime_failure_route.Config_mismatch
    ; fj_provenance = Keeper_runtime_failure_route.Oas_config_error
    ; fj_detail = "configuration unavailable"
    }
  in
  { post_id = Keeper_event_queue.failure_judgment_post_id judgment
  ; urgency = Keeper_event_queue.Immediate
  ; arrived_at = 1234.5
  ; payload = Keeper_event_queue.Failure_judgment judgment
  }
;;

let require_ok label = function
  | Ok value -> value
  | Error message -> failf "%s: %s" label message
;;

let transition_receipt ~settlement stimulus =
  let pending = Keeper_event_queue.enqueue Keeper_event_queue.empty stimulus in
  let state = Keeper_event_queue_state.with_pending pending Keeper_event_queue_state.empty in
  let state, lease =
    Keeper_event_queue_state.claim_when
      ~claimed_at:1235.0
      ~ready:(fun _ -> true)
      state
    |> require_ok "claim transition receipt stimulus"
  in
  let lease =
    match lease with
    | Some lease -> lease
    | None -> fail "transition receipt stimulus was not claimed"
  in
  let _state, result =
    Keeper_event_queue_state.settle
      ~settled_at:1236.0
      ~lease
      ~settlement
      state
    |> require_ok "settle transition receipt stimulus"
  in
  match result with
  | Keeper_event_queue_state.Settled receipt -> receipt
  | Keeper_event_queue_state.Already_settled _ ->
    fail "first transition receipt settlement was already settled"
;;

let check_member_string label expected key json =
  check string label expected (json |> member key |> to_string)
;;

let result_count_by_label json label =
  json
  |> member "completion_contract_result_counts"
  |> to_list
  |> List.find_opt (fun item ->
    match item |> member "result" with
    | `String value -> String.equal value label
    | _ -> false)
;;

let check_list_has_string label expected json =
  check bool label true
    (json
     |> to_list
     |> List.exists (fun item -> String.equal expected (to_string item)))
;;

let rec mkdir_p path =
  if path = "" || path = "." || path = "/"
  then ()
  else if Sys.file_exists path
  then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)
;;

let event_queue_snapshot_path ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
    "event-queue.json"
;;

let latest_row rows =
  match List.rev rows with
  | row :: _ -> row
  | [] -> fail "expected at least one reaction ledger row"
;;

let test_event_queue_stimulus_and_turn_reaction () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "ledger-keeper" in
  let stimulus = board_stimulus () in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  Keeper_reaction_ledger.record_event_queue_reaction
    ~base_path
    ~keeper_name
    ~reaction_kind:Keeper_reaction_ledger.Turn_started
    stimulus;
  let rows =
    Keeper_reaction_ledger.read_recent_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check int "two rows persisted" 2 (List.length rows);
  let stimulus_row = List.nth rows 0 in
  check_member_string "stimulus schema" "keeper.reaction_ledger.v1" "schema" stimulus_row;
  check_member_string "stimulus record kind" "stimulus" "record_kind" stimulus_row;
  check_member_string "board stimulus id" "board:post-42" "stimulus_id" stimulus_row;
  check_member_string
    "stimulus kind"
    "board_signal"
    "kind"
    (stimulus_row |> member "stimulus");
  let reaction_row = List.nth rows 1 in
  check_member_string "reaction record kind" "reaction" "record_kind" reaction_row;
  check_member_string "reaction stimulus id" "board:post-42" "stimulus_id" reaction_row;
  check_member_string
    "reaction kind"
    "turn_started"
    "kind"
    (reaction_row |> member "reaction")
;;

let test_event_queue_reaction_evidence_matches_exact_stimulus_id () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "ledger-schedule-keeper" in
  let stimulus = schedule_due_stimulus () in
  let unrelated = schedule_due_stimulus ~schedule_id:"sched-ledger-other" () in
  let stimulus_id = Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    unrelated;
  let stimulus_only =
    Keeper_reaction_ledger.event_queue_reaction_evidence
      ~base_path
      ~keeper_name
      ~stimulus_id
  in
  check bool "exact stimulus seen" true stimulus_only.stimulus_seen;
  check bool "turn reaction absent" false stimulus_only.turn_started_seen;
  check bool "event queue ack absent" false stimulus_only.event_queue_ack_seen;
  check int "one exact row before reaction" 1 stimulus_only.matched_record_count;
  Keeper_reaction_ledger.record_event_queue_reaction
    ~base_path
    ~keeper_name
    ~reaction_kind:Keeper_reaction_ledger.Turn_started
    stimulus;
  let reacted =
    Keeper_reaction_ledger.event_queue_reaction_evidence
      ~base_path
      ~keeper_name
      ~stimulus_id
  in
  check bool "exact stimulus still seen" true reacted.stimulus_seen;
  check bool "turn reaction seen" true reacted.turn_started_seen;
  check bool "event queue ack still absent" false reacted.event_queue_ack_seen;
  check int "two exact rows after reaction" 2 reacted.matched_record_count;
  Keeper_reaction_ledger.record_event_queue_reaction
    ~base_path
    ~keeper_name
    ~reaction_kind:Keeper_reaction_ledger.Event_queue_ack
    stimulus;
  let acknowledged =
    Keeper_reaction_ledger.event_queue_reaction_evidence
      ~base_path
      ~keeper_name
      ~stimulus_id
  in
  check bool "event queue ack seen" true acknowledged.event_queue_ack_seen;
  check int "three exact rows after ack" 3 acknowledged.matched_record_count;
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check int "summary counts event queue ack" 1
    (summary |> member "event_queue_ack_count" |> to_int);
  check int "event queue ack is not unknown" 0
    (summary |> member "unknown_reaction_count" |> to_int);
  let missing =
    Keeper_reaction_ledger.event_queue_reaction_evidence
      ~base_path
      ~keeper_name
      ~stimulus_id:"stimulus:missing"
  in
  check bool "missing stimulus absent" false missing.stimulus_seen;
  check bool "missing reaction absent" false missing.turn_started_seen;
  check bool "missing ack absent" false missing.event_queue_ack_seen;
  check int "missing exact rows" 0 missing.matched_record_count
;;

let test_failure_judgment_operator_attention_is_typed_and_visible () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "judgment-attention-keeper" in
  let stimulus = failure_judgment_stimulus () in
  let receipt =
    transition_receipt
      ~settlement:
        (Keeper_event_queue_state.Escalate
           { reason =
               Keeper_event_queue_state.Failure_judgment_operator_required
                 { judge_runtime_id = "opaque-judge-runtime"
                 ; rationale = "Operator-owned configuration must change."
                 }
           ; successor = None
           })
      stimulus
  in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  Keeper_reaction_ledger.record_event_queue_transition_reaction_result
    ~base_path
    ~keeper_name
    ~reaction_kind:Keeper_reaction_ledger.Event_queue_escalated
    ~receipt
    stimulus
  |> require_ok "record operator-required judgment transition";
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "operator-required judgment degrades" "degraded" "status" summary;
  check bool "operator-required judgment requires action" true
    (summary |> member "operator_action_required" |> to_bool);
  check int "terminal judgment attention counted" 1
    (summary |> member "event_queue_operator_attention_count" |> to_int);
  check int "typed transition receipt parsed" 0
    (summary |> member "event_queue_transition_parse_error_count" |> to_int);
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[ keeper_name ]
      ~limit_per_keeper:10
  in
  check bool "fleet judgment attention requires action" true
    (fleet |> member "operator_action_required" |> to_bool);
  check int "fleet judgment attention counted" 1
    (fleet |> member "event_queue_operator_attention_count" |> to_int);
  check_list_has_string
    "fleet explains judgment attention"
    "event_queue_operator_attention"
    (fleet |> member "status_reasons")
;;

let test_cursor_ack_is_replayable_state_entry () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "cursor-keeper" in
  Keeper_reaction_ledger.record_board_cursor_ack
    ~base_path
    ~keeper_name
    ~cursor_ts:5678.25
    ~post_id:(Some "post-99")
    ();
  let row =
    Keeper_reaction_ledger.read_recent_for_keeper ~base_path ~keeper_name ~limit:1
    |> latest_row
  in
  check_member_string "cursor ack record kind" "cursor_ack" "record_kind" row;
  check_member_string "cursor ack stimulus id" "board:post-99" "stimulus_id" row;
  check (float 0.0001) "cursor timestamp" 5678.25
    (row |> member "cursor" |> member "cursor_ts" |> to_float);
  check_member_string "cursor post id" "post-99" "post_id" (row |> member "cursor");
  check bool "cursor acked" true
    (row |> member "reaction" |> member "cursor_acked" |> to_bool)
;;

let test_execution_receipt_links_to_reaction_ledger () =
  with_temp_base @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let keeper_name = "receipt-keeper" in
  let receipt_json =
    `Assoc
      [ "schema", `String "keeper.execution_receipt.v1"
      ; "trace_id", `String "trace-1"
      ; "outcome", `String "receipt_failed"
      ; "terminal_reason_code", `String "completion_contract_violation"
      ]
  in
  Keeper_reaction_ledger.record_execution_receipt_reaction
    config
    ~keeper_name
    ~trace_id:"trace-1"
    ~turn_count:7
    ~current_task_id:(Some "task-275")
    ~goal_ids:[ "goal-world-reactivity-p0-20260517" ]
    ~outcome:"receipt_failed"
    ~reaction_kind:Keeper_reaction_ledger.Terminal_reason
    ~terminal_reason_code:"completion_contract_violation"
    ~receipt_json
    ();
  let row =
    Keeper_reaction_ledger.read_recent_for_keeper ~base_path ~keeper_name ~limit:1
    |> latest_row
  in
  check_member_string "receipt reaction record kind" "reaction" "record_kind" row;
  check_member_string "receipt reaction stimulus id" "task:task-275" "stimulus_id" row;
  let reaction = row |> member "reaction" in
  check_member_string "terminal reaction kind" "terminal_reason" "kind" reaction;
  check_member_string
    "terminal reason"
    "completion_contract_violation"
    "terminal_reason_code"
    reaction;
  check_member_string
    "embedded receipt schema"
    "keeper.execution_receipt.v1"
    "schema"
    (reaction |> member "receipt")
;;

let test_summary_observes_passive_only_without_attention () =
  with_temp_base @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let keeper_name = "contract-attention-keeper" in
  let record ?(terminal_reason_code = "success") ?current_task_id
        ~trace_id ~completion_contract_result () =
    let receipt_json =
      `Assoc
        [ "schema", `String "keeper.execution_receipt.v1"
        ; "trace_id", `String trace_id
        ; "outcome", `String "receipt_done"
        ; "terminal_reason_code", `String terminal_reason_code
        ; "operator_disposition", `String "pause_human"
        ; "operator_disposition_reason", `String "completion_contract_unsatisfied"
        ; "completion_contract_result", `String completion_contract_result
        ]
    in
    Keeper_reaction_ledger.record_execution_receipt_reaction
      config
      ~keeper_name
      ~trace_id
      ~turn_count:1
      ~current_task_id
      ~goal_ids:[]
      ~outcome:"receipt_done"
      ~reaction_kind:Keeper_reaction_ledger.Execution_receipt
      ~terminal_reason_code
      ~receipt_json
      ()
  in
  record
    ~trace_id:"trace-passive-1"
    ~current_task_id:"task-passive-1"
    ~completion_contract_result:"passive_only"
    ();
  record
    ~trace_id:"trace-passive-2"
    ~current_task_id:"task-passive-2"
    ~completion_contract_result:"passive_only"
    ();
  record
    ~trace_id:"trace-satisfied"
    ~current_task_id:"task-satisfied"
    ~completion_contract_result:"satisfied_execution"
    ();
  record
    ~trace_id:"trace-violated"
    ~current_task_id:"task-violated"
    ~completion_contract_result:"violated"
    ();
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "contract summary remains mechanically ok" "ok" "status" summary;
  check int "completion contract attention count" 1
    (summary |> member "completion_contract_attention_count" |> to_int);
  check int "passive-only observation count" 2
    (summary |> member "completion_contract_passive_only_count" |> to_int);
  check string "latest contract attention" "violated"
    (summary |> member "latest_completion_contract_attention" |> to_string);
  let result_count =
    match result_count_by_label summary "passive_only" with
    | Some value -> value
    | None -> fail "passive_only observation count missing"
  in
  check_member_string "contract result label" "passive_only" "result" result_count;
  check int "contract result count" 2 (result_count |> member "count" |> to_int);
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[ keeper_name ]
      ~limit_per_keeper:10
  in
  check int "fleet contract attention count" 1
    (fleet |> member "completion_contract_attention_count" |> to_int);
  check int "fleet passive-only observation count" 2
    (fleet |> member "completion_contract_passive_only_count" |> to_int);
  let keeper_attention =
    fleet
    |> member "completion_contract_attention_by_keeper"
    |> to_list
    |> List.hd
  in
  check_member_string
    "fleet contract attention keeper"
    keeper_name
    "keeper_name"
    keeper_attention;
  check int "fleet keeper contract attention count" 1
    (keeper_attention |> member "completion_contract_attention_count" |> to_int)
;;

let test_summary_degrades_unknown_completion_contract_result () =
  with_temp_base @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let keeper_name = "contract-unknown-keeper" in
  let record ~trace_id ~completion_contract_result () =
    let receipt_json =
      `Assoc
        [ "schema", `String "keeper.execution_receipt.v1"
        ; "trace_id", `String trace_id
        ; "outcome", `String "receipt_done"
        ; "terminal_reason_code", `String "success"
        ; "operator_disposition", `String "continue"
        ; "operator_disposition_reason", `String "none"
        ; "completion_contract_result", `String completion_contract_result
        ]
    in
    Keeper_reaction_ledger.record_execution_receipt_reaction
      config
      ~keeper_name
      ~trace_id
      ~turn_count:1
      ~current_task_id:None
      ~goal_ids:[]
      ~outcome:"receipt_done"
      ~reaction_kind:Keeper_reaction_ledger.Execution_receipt
      ~terminal_reason_code:"success"
      ~receipt_json
      ()
  in
  record ~trace_id:"trace-unknown" ~completion_contract_result:"passive-only" ();
  record
    ~trace_id:"trace-satisfied"
    ~completion_contract_result:"satisfied_execution"
    ();
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string
    "unknown contract result degrades summary"
    "degraded"
    "status"
    summary;
  check bool "unknown contract result requires operator action" true
    (summary |> member "operator_action_required" |> to_bool);
  check int "unknown contract result is not attention" 0
    (summary |> member "completion_contract_attention_count" |> to_int);
  check int "unknown contract result counted" 1
    (summary |> member "completion_contract_unknown_result_count" |> to_int);
  check int "unknown contract result does not use reaction bucket" 0
    (summary |> member "unknown_reaction_count" |> to_int);
  let unknown_result_count =
    summary
    |> member "completion_contract_unknown_result_counts"
    |> to_list
    |> List.hd
  in
  check_member_string "unknown contract result label" "passive-only" "result"
    unknown_result_count;
  check int "unknown contract result label count" 1
    (unknown_result_count |> member "count" |> to_int);
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[ keeper_name ]
      ~limit_per_keeper:10
  in
  check_member_string "fleet unknown contract result degrades" "degraded" "status"
    fleet;
  check bool "fleet unknown contract result requires operator action" true
    (fleet |> member "operator_action_required" |> to_bool);
  check int "fleet unknown contract result counted" 1
    (fleet |> member "completion_contract_unknown_result_count" |> to_int);
  let keeper_unknown =
    fleet
    |> member "completion_contract_unknown_results_by_keeper"
    |> to_list
    |> List.hd
  in
  check_member_string
    "fleet unknown contract result keeper"
    keeper_name
    "keeper_name"
    keeper_unknown;
  check int "fleet keeper unknown contract result count" 1
    (keeper_unknown |> member "completion_contract_unknown_result_count" |> to_int)
;;

let test_completion_contract_result_canonical_roundtrip () =
  let module Receipt = Keeper_execution_receipt_types in
  let cases =
    [ Receipt.Contract_unknown, false
    ; Receipt.Contract_not_dispatched, false
    ; Receipt.Contract_violated, true
    ; Receipt.Contract_surface_mismatch, true
    ; Receipt.Contract_no_capable_provider, true
    ; Receipt.Contract_claim_only_after_owned_task, true
    ; Receipt.Contract_needs_execution_progress, true
    ; Receipt.Contract_passive_only, false
    ; Receipt.Contract_satisfied_completion, false
    ; Receipt.Contract_satisfied_execution, false
    ]
  in
  List.iter
    (fun (result, requires_attention) ->
       let label = Receipt.completion_contract_result_to_string result in
       let parsed_label =
         Receipt.completion_contract_result_of_string label
         |> Option.map Receipt.completion_contract_result_to_string
       in
       check
         (option string)
         ("completion-contract parser roundtrip: " ^ label)
         (Some label)
         parsed_label;
       check
         bool
         ("completion-contract attention classification: " ^ label)
         requires_attention
         (Receipt.completion_contract_result_requires_attention result))
    cases;
  check
    (option string)
    "completion-contract parser rejects prose drift"
    None
    (Receipt.completion_contract_result_of_string "passive-only"
     |> Option.map Receipt.completion_contract_result_to_string)
;;

let test_summary_observes_passive_only_without_work_scope_attention () =
  with_temp_base @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let keeper_name = "passive-no-work-keeper" in
  let receipt_json =
    `Assoc
      [ "schema", `String "keeper.execution_receipt.v1"
      ; "trace_id", `String "trace-passive-no-work"
      ; "outcome", `String "receipt_done"
      ; "terminal_reason_code", `String "success"
      ; "operator_disposition", `String "pass"
      ; "operator_disposition_reason", `String "healthy"
      ; "completion_contract_result", `String "passive_only"
      ]
  in
  Keeper_reaction_ledger.record_execution_receipt_reaction
    config
    ~keeper_name
    ~trace_id:"trace-passive-no-work"
    ~turn_count:1
    ~current_task_id:None
    ~goal_ids:[]
    ~outcome:"receipt_done"
    ~reaction_kind:Keeper_reaction_ledger.Execution_receipt
    ~terminal_reason_code:"success"
    ~receipt_json
    ();
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check int "passive-only no-work attention not counted" 0
    (summary |> member "completion_contract_attention_count" |> to_int);
  check int "passive-only no-work observation counted" 1
    (summary |> member "completion_contract_passive_only_count" |> to_int);
  check
    string
    "passive-only no-work summary remains ok"
    "ok"
    (summary |> member "status" |> to_string);
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[ keeper_name ]
      ~limit_per_keeper:10
  in
  check int "fleet passive-only no-work attention not counted" 0
    (fleet |> member "completion_contract_attention_count" |> to_int);
  check int "fleet passive-only no-work observation counted" 1
    (fleet |> member "completion_contract_passive_only_count" |> to_int)
;;

let test_summary_marks_unreacted_and_reacted_stimuli () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "summary-keeper" in
  let stimulus = board_stimulus ~post_id:"post-summary" () in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  let pending_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "pending summary status" "degraded" "status" pending_summary;
  check bool "pending summary asks for operator visibility" true
    (pending_summary |> member "operator_action_required" |> to_bool);
  check int "pending stimulus count" 1
    (pending_summary |> member "pending_stimulus_count" |> to_int);
  check string "pending stimulus id" "board:post-summary"
    (pending_summary
     |> member "pending_stimulus_ids"
     |> to_list
     |> List.hd
     |> to_string);
  Keeper_reaction_ledger.record_event_queue_reaction
    ~base_path
    ~keeper_name
    ~reaction_kind:Keeper_reaction_ledger.Turn_started
    stimulus;
  let reacted_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "reacted summary status" "ok" "status" reacted_summary;
  check bool "reacted summary clears operator action" false
    (reacted_summary |> member "operator_action_required" |> to_bool);
  check int "reacted pending stimulus count" 0
    (reacted_summary |> member "pending_stimulus_count" |> to_int);
  check int "turn started count" 1
    (reacted_summary |> member "turn_started_count" |> to_int)
;;

let test_summary_cursor_ack_sweeps_covered_board_stimuli () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "cursor-sweep-keeper" in
  let first = board_stimulus ~post_id:"post-1" ~updated_at:10.0 () in
  let second = board_stimulus ~post_id:"post-2" ~updated_at:20.0 () in
  let third = board_stimulus ~post_id:"post-3" ~updated_at:30.0 () in
  List.iter
    (Keeper_reaction_ledger.record_event_queue_stimulus ~base_path ~keeper_name)
    [ first; second ];
  Keeper_reaction_ledger.record_board_cursor_ack
    ~base_path
    ~keeper_name
    ~cursor_ts:20.0
    ~post_id:(Some "post-2")
    ();
  let swept_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "cursor-swept summary status" "ok" "status" swept_summary;
  check int "cursor-swept pending count" 0
    (swept_summary |> member "pending_stimulus_count" |> to_int);
  check int "cursor sweep count" 2
    (swept_summary |> member "cursor_swept_stimulus_count" |> to_int);
  Keeper_reaction_ledger.record_event_queue_stimulus ~base_path ~keeper_name third;
  let future_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "future stimulus remains degraded" "degraded" "status" future_summary;
  check int "future pending count" 1
    (future_summary |> member "pending_stimulus_count" |> to_int);
  check string "future pending stimulus id" "board:post-3"
    (future_summary
     |> member "pending_stimulus_ids"
     |> to_list
     |> List.hd
     |> to_string)
;;

let test_summary_cursor_ack_respects_post_id_tiebreaker () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "cursor-tiebreaker-keeper" in
  let first = board_stimulus ~post_id:"post-1" ~updated_at:50.0 () in
  let second = board_stimulus ~post_id:"post-2" ~updated_at:50.0 () in
  List.iter
    (Keeper_reaction_ledger.record_event_queue_stimulus ~base_path ~keeper_name)
    [ first; second ];
  Keeper_reaction_ledger.record_board_cursor_ack
    ~base_path
    ~keeper_name
    ~cursor_ts:50.0
    ~post_id:(Some "post-1")
    ();
  let partial_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "partial cursor summary status" "degraded" "status" partial_summary;
  check int "one post remains pending" 1
    (partial_summary |> member "pending_stimulus_count" |> to_int);
  check string "later same-timestamp post remains pending" "board:post-2"
    (partial_summary
     |> member "pending_stimulus_ids"
     |> to_list
     |> List.hd
     |> to_string);
  Keeper_reaction_ledger.record_board_cursor_ack
    ~base_path
    ~keeper_name
    ~cursor_ts:50.0
    ~post_id:(Some "post-2")
    ();
  let complete_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "complete cursor summary status" "ok" "status" complete_summary;
  check int "same timestamp posts cleared" 0
    (complete_summary |> member "pending_stimulus_count" |> to_int)
;;

let test_no_progress_recovery_stimulus_is_typed () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "no-progress-keeper" in
  let stimulus = no_progress_recovery_stimulus ~keeper_name () in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  let row =
    Keeper_reaction_ledger.read_recent_for_keeper ~base_path ~keeper_name ~limit:1
    |> latest_row
  in
  check_member_string
    "no-progress stimulus kind"
    "no_progress_recovery"
    "kind"
    (row |> member "stimulus");
  check string "stable stimulus prefix" "stimulus:"
    (String.sub (row |> member "stimulus_id" |> to_string) 0 9)
;;

let test_no_progress_recovery_reaction_clears_pending () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "no-progress-keeper" in
  let stimulus = no_progress_recovery_stimulus ~keeper_name () in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  let pending_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "pending recovery summary status" "degraded" "status" pending_summary;
  check int "recovery stimulus pending" 1
    (pending_summary |> member "pending_stimulus_count" |> to_int);
  check int "pending recovery stimulus kind counted" 1
    (pending_summary |> member "pending_no_progress_recovery_count" |> to_int);
  check int "pending recovery stimulus id surfaced" 1
    (pending_summary
     |> member "pending_no_progress_recovery_ids"
     |> to_list
     |> List.length);
  Keeper_reaction_ledger.record_event_queue_reaction
    ~base_path
    ~keeper_name
    ~reaction_kind:Keeper_reaction_ledger.Turn_started
    stimulus;
  let reacted_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "reacted recovery summary status" "ok" "status" reacted_summary;
  check bool "reacted recovery needs no operator action" false
    (reacted_summary |> member "operator_action_required" |> to_bool);
  check int "recovery stimulus cleared" 0
    (reacted_summary |> member "pending_stimulus_count" |> to_int);
  check int "pending recovery stimulus kind cleared" 0
    (reacted_summary |> member "pending_no_progress_recovery_count" |> to_int);
  check int "turn-start reaction counted" 1
    (reacted_summary |> member "turn_started_count" |> to_int)
;;

let test_no_progress_recovery_unrelated_reaction_does_not_clear_pending () =
  with_temp_base @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let keeper_name = "no-progress-unrelated-reaction-keeper" in
  let stimulus = no_progress_recovery_stimulus ~keeper_name () in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  let pending_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "pending recovery summary status" "degraded" "status" pending_summary;
  check int "recovery stimulus initially pending" 1
    (pending_summary |> member "pending_no_progress_recovery_count" |> to_int);
  let receipt_json =
    `Assoc
      [ "schema", `String "keeper.execution_receipt.v1"
      ; "trace_id", `String "trace-later-reaction"
      ; "outcome", `String "receipt_done"
      ; "terminal_reason_code", `String "success"
      ; "operator_disposition", `String "pass"
      ; "operator_disposition_reason", `String "healthy"
      ; "completion_contract_result", `String "satisfied_execution"
      ]
  in
  Keeper_reaction_ledger.record_execution_receipt_reaction
    config
    ~keeper_name
    ~trace_id:"trace-later-reaction"
    ~turn_count:1
    ~current_task_id:None
    ~goal_ids:[]
    ~outcome:"receipt_done"
    ~reaction_kind:Keeper_reaction_ledger.Execution_receipt
    ~terminal_reason_code:"success"
    ~receipt_json
    ();
  let unrelated_reaction_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string
    "unrelated reaction recovery summary remains degraded"
    "degraded"
    "status"
    unrelated_reaction_summary;
  check bool "unrelated reaction recovery still needs operator action" true
    (unrelated_reaction_summary |> member "operator_action_required" |> to_bool);
  check int "unrelated reaction leaves recovery stimulus pending" 1
    (unrelated_reaction_summary |> member "pending_stimulus_count" |> to_int);
  check int "unrelated reaction leaves no-progress recovery kind pending" 1
    (unrelated_reaction_summary |> member "pending_no_progress_recovery_count" |> to_int);
  check int "execution receipt reaction still counted" 1
    (unrelated_reaction_summary |> member "execution_receipt_count" |> to_int)
;;

let test_no_progress_recovery_cursor_ack_does_not_clear_pending () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "no-progress-cursor-only-keeper" in
  let stimulus = no_progress_recovery_stimulus ~keeper_name () in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  let pending_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  let stimulus_id =
    pending_summary
    |> member "pending_no_progress_recovery_ids"
    |> to_list
    |> List.hd
    |> to_string
  in
  Keeper_reaction_ledger.record_board_cursor_ack
    ~base_path
    ~keeper_name
    ~stimulus_id
    ~cursor_ts:9999.0
    ~post_id:(Some "cursor-only-post")
    ();
  let cursor_only_summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string
    "cursor-only recovery summary remains degraded"
    "degraded"
    "status"
    cursor_only_summary;
  check bool "cursor-only recovery still needs operator action" true
    (cursor_only_summary |> member "operator_action_required" |> to_bool);
  check int "cursor-only recovery stimulus remains pending" 1
    (cursor_only_summary |> member "pending_stimulus_count" |> to_int);
  check int "cursor-only recovery kind remains pending" 1
    (cursor_only_summary |> member "pending_no_progress_recovery_count" |> to_int);
  check int "cursor ack still counted" 1
    (cursor_only_summary |> member "cursor_ack_count" |> to_int);
  check int "cursor ack does not sweep non-board recovery stimulus" 0
    (cursor_only_summary |> member "cursor_swept_stimulus_count" |> to_int)
;;

let test_summary_links_passive_only_observation_to_pending_recovery () =
  with_temp_base @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let keeper_name = "passive-recovery-keeper" in
  let receipt_json =
    `Assoc
      [ "schema", `String "keeper.execution_receipt.v1"
      ; "trace_id", `String "trace-passive"
      ; "outcome", `String "receipt_done"
      ; "terminal_reason_code", `String "success"
      ; "operator_disposition", `String "pause_human"
      ; "operator_disposition_reason", `String "completion_contract_unsatisfied"
      ; "completion_contract_result", `String "passive_only"
      ]
  in
  Keeper_reaction_ledger.record_execution_receipt_reaction
    config
    ~keeper_name
    ~trace_id:"trace-passive"
    ~turn_count:1
    ~current_task_id:(Some "task-passive")
    ~goal_ids:[]
    ~outcome:"receipt_done"
    ~reaction_kind:Keeper_reaction_ledger.Terminal_reason
    ~terminal_reason_code:"success"
    ~receipt_json
    ();
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    (no_progress_recovery_stimulus ~keeper_name ());
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check int "passive-only observation counted" 1
    (summary |> member "completion_contract_passive_only_count" |> to_int);
  check int "passive-only does not count as attention" 0
    (summary |> member "completion_contract_attention_count" |> to_int);
  check int "pending no-progress recovery counted" 1
    (summary |> member "pending_no_progress_recovery_count" |> to_int);
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[ keeper_name ]
      ~limit_per_keeper:10
  in
  check int "fleet passive-only observation counted" 1
    (fleet |> member "completion_contract_passive_only_count" |> to_int);
  check int "fleet passive-only does not count as attention" 0
    (fleet |> member "completion_contract_attention_count" |> to_int);
  check int "fleet pending no-progress recovery counted" 1
    (fleet |> member "pending_no_progress_recovery_count" |> to_int);
  let recovery_keeper =
    fleet
    |> member "pending_no_progress_recovery_by_keeper"
    |> to_list
    |> List.hd
  in
  check_member_string
    "fleet pending recovery keeper"
    keeper_name
    "keeper_name"
    recovery_keeper;
  check int "fleet keeper pending recovery count" 1
    (recovery_keeper |> member "pending_no_progress_recovery_count" |> to_int)
;;

let test_fleet_summary_surfaces_durable_event_queue_backlog () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "durable-backlog-keeper" in
  Keeper_registry_event_queue.enqueue
    ~base_path
    keeper_name
    (board_stimulus ~post_id:"post-live-backlog" ());
  Keeper_registry_event_queue.enqueue
    ~base_path
    keeper_name
    (no_progress_recovery_stimulus ~keeper_name ());
  Keeper_event_queue_persistence.record_inflight
    ~base_path
    ~keeper_name
    [ fusion_completed_stimulus () ];
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[ keeper_name ]
      ~limit_per_keeper:10
  in
  check_member_string "durable queue backlog degrades fleet summary" "degraded" "status" fleet;
  check_list_has_string
    "durable queue stale reason is explicit"
    "durable_event_queue_stale"
    (fleet |> member "status_reasons");
  check bool "durable queue backlog requires operator action" true
    (fleet |> member "operator_action_required" |> to_bool);
  check int "ledger pending rows stay independent" 0
    (fleet |> member "pending_stimulus_count" |> to_int);
  check int "durable queue backlog counted" 3
    (fleet |> member "durable_event_queue_count" |> to_int);
  check int "durable queue pending backlog counted" 2
    (fleet |> member "durable_event_queue_pending_count" |> to_int);
  check int "durable queue inflight backlog counted" 1
    (fleet |> member "durable_event_queue_inflight_count" |> to_int);
  check (float 0.001) "default durable queue stale threshold preserves prior behavior"
    0.0
    (fleet |> member "durable_event_queue_stale_after_sec" |> to_float);
  check int "durable queue stale backlog counted" 3
    (fleet |> member "durable_event_queue_stale_count" |> to_int);
  check int "durable queue stale keeper counted" 1
    (fleet |> member "durable_event_queue_stale_keeper_count" |> to_int);
  let keeper_queue =
    fleet |> member "durable_event_queue_by_keeper" |> to_list |> List.hd
  in
  check_member_string
    "durable queue keeper name"
    keeper_name
    "keeper_name"
    keeper_queue;
  check int "keeper durable queue backlog counted" 3
    (keeper_queue |> member "durable_event_queue_count" |> to_int);
  check int "keeper durable queue pending backlog counted" 2
    (keeper_queue |> member "durable_event_queue_pending_count" |> to_int);
  check int "keeper durable queue inflight backlog counted" 1
    (keeper_queue |> member "durable_event_queue_inflight_count" |> to_int);
  check int "keeper immediate durable queue backlog counted" 2
    (keeper_queue |> member "immediate_count" |> to_int);
  check bool "keeper durable queue is stale by default" true
    (keeper_queue |> member "stale" |> to_bool);
  check int "stale keeper list mirrors stale backlog" 1
    (fleet |> member "durable_event_queue_stale_by_keeper" |> to_list |> List.length);
  let payload_counts =
    fleet |> member "durable_event_queue_payload_counts" |> to_list
  in
  check bool "board_signal durable payload count is surfaced" true
    (List.exists
       (fun json ->
         String.equal (json |> member "payload_kind" |> to_string) "board_signal"
         && json |> member "count" |> to_int = 1)
       payload_counts);
  check bool "no_progress_recovery durable payload count is surfaced" true
    (List.exists
       (fun json ->
         String.equal
           (json |> member "payload_kind" |> to_string)
           "no_progress_recovery"
         && json |> member "count" |> to_int = 1)
       payload_counts);
  check bool "inflight fusion_completed durable payload count is surfaced" true
    (List.exists
       (fun json ->
         String.equal (json |> member "payload_kind" |> to_string) "fusion_completed"
         && json |> member "count" |> to_int = 1)
       payload_counts)
;;

let test_fleet_summary_discovers_durable_event_queue_backlog_without_meta_name () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "durable-only-keeper" in
  Keeper_registry_event_queue.enqueue
    ~base_path
    keeper_name
    (board_stimulus ~post_id:"post-durable-only" ());
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[]
      ~limit_per_keeper:10
  in
  check_member_string
    "durable-only queue degrades fleet summary"
    "degraded"
    "status"
    fleet;
  check int "durable-only keeper is included in fleet count" 1
    (fleet |> member "keeper_count" |> to_int);
  check_list_has_string
    "durable-only keeper name is discovered"
    keeper_name
    (fleet |> member "keeper_names");
  check int "durable-only discovery counted" 1
    (fleet |> member "durable_event_queue_discovered_keeper_count" |> to_int);
  check_list_has_string
    "durable-only discovery names keeper"
    keeper_name
    (fleet |> member "durable_event_queue_discovered_keeper_names");
  check bool "durable-only discovery has no read error" true
    (match fleet |> member "durable_event_queue_discovery_error" with
     | `Null -> true
     | _ -> false);
  check int "durable-only queue backlog counted" 1
    (fleet |> member "durable_event_queue_count" |> to_int);
  let keeper_queue =
    fleet |> member "durable_event_queue_by_keeper" |> to_list |> List.hd
  in
  check_member_string
    "durable-only queue keeper name"
    keeper_name
    "keeper_name"
    keeper_queue;
  check int "durable-only keeper queue backlog counted" 1
    (keeper_queue |> member "durable_event_queue_count" |> to_int)
;;

let test_fleet_summary_surfaces_durable_event_queue_discovery_error () =
  with_temp_base @@ fun base_path ->
  let invalid_keeper_name = "invalid keeper name" in
  let invalid_keeper_dir =
    Filename.concat
      (Common.keepers_runtime_dir_of_base ~base_path)
      invalid_keeper_name
  in
  mkdir_p invalid_keeper_dir;
  write_file
    (Filename.concat invalid_keeper_dir "event-queue.json")
    (Yojson.Safe.to_string (Keeper_event_queue.queue_to_yojson Keeper_event_queue.empty));
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[]
      ~limit_per_keeper:10
  in
  check_member_string
    "durable queue discovery error makes fleet status unknown"
    "unknown"
    "status"
    fleet;
  check_list_has_string
    "durable queue discovery error reason is explicit"
    "durable_event_queue_discovery_error"
    (fleet |> member "status_reasons");
  check bool "durable queue discovery error requires operator action" true
    (fleet |> member "operator_action_required" |> to_bool);
  check int "durable queue discovery error counted" 1
    (fleet |> member "durable_event_queue_discovery_error_count" |> to_int);
  check bool "durable queue discovery error message is surfaced" true
    (match fleet |> member "durable_event_queue_discovery_error" with
     | `String value -> not (String.equal value "")
     | _ -> false);
  check int "invalid durable queue keeper is not accepted as a keeper" 0
    (fleet |> member "keeper_count" |> to_int)
;;

let test_fleet_summary_allows_nonstale_durable_event_queue_backlog () =
  if Sys.getenv_opt "MASC_KEEPER_DURABLE_QUEUE_STALE_SEC" <> None then
    skip ()
  else
  Fun.protect
    ~finally:(fun () -> Config_boot_overrides.reset_for_tests ())
    (fun () ->
       Config_boot_overrides.reset_for_tests ();
       Config_boot_overrides.set "MASC_KEEPER_DURABLE_QUEUE_STALE_SEC" "1000000000000.0";
       with_temp_base @@ fun base_path ->
       let keeper_name = "fresh-durable-backlog-keeper" in
       Keeper_registry_event_queue.enqueue
         ~base_path
         keeper_name
         (board_stimulus ~post_id:"post-fresh-backlog" ());
       let fleet =
         Keeper_reaction_ledger.fleet_summary_json
           ~base_path
           ~keeper_names:[ keeper_name ]
           ~limit_per_keeper:10
       in
       check_member_string
         "fresh durable backlog remains visible but not degraded"
         "ok"
         "status"
         fleet;
       check bool "fresh durable backlog does not require operator action" false
         (fleet |> member "operator_action_required" |> to_bool);
       check int "fresh durable queue backlog counted" 1
         (fleet |> member "durable_event_queue_count" |> to_int);
       check int "fresh durable queue stale count stays zero" 0
         (fleet |> member "durable_event_queue_stale_count" |> to_int);
       check int "fresh durable queue stale keeper count stays zero" 0
         (fleet |> member "durable_event_queue_stale_keeper_count" |> to_int);
       check (float 0.001) "durable stale threshold comes from boot override"
         1000000000000.0
         (fleet |> member "durable_event_queue_stale_after_sec" |> to_float);
       let keeper_queue =
         fleet |> member "durable_event_queue_by_keeper" |> to_list |> List.hd
       in
       check bool "fresh durable queue is not stale" false
         (keeper_queue |> member "stale" |> to_bool);
       check int "fresh durable stale keeper list is empty" 0
         (fleet |> member "durable_event_queue_stale_by_keeper" |> to_list |> List.length))
;;

let test_fleet_summary_surfaces_durable_event_queue_read_error () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "broken-durable-queue-keeper" in
  let path = event_queue_snapshot_path ~base_path ~keeper_name in
  mkdir_p (Filename.dirname path);
  write_file path "{not-json";
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[ keeper_name ]
      ~limit_per_keeper:10
  in
  check_member_string
    "durable queue read error makes fleet status unknown"
    "unknown"
    "status"
    fleet;
  check_list_has_string
    "durable queue read error reason is explicit"
    "durable_event_queue_read_error"
    (fleet |> member "status_reasons");
  check bool "durable queue read error requires operator action" true
    (fleet |> member "operator_action_required" |> to_bool);
  check int "durable queue read error counted" 1
    (fleet |> member "durable_event_queue_read_error_count" |> to_int);
  let keeper_error =
    fleet |> member "durable_event_queue_read_errors_by_keeper" |> to_list |> List.hd
  in
  check_member_string
    "durable queue read error keeper name"
    keeper_name
    "keeper_name"
    keeper_error;
  check int "keeper durable queue read error counted" 1
    (keeper_error |> member "read_error_count" |> to_int);
  let read_error =
    keeper_error |> member "read_errors" |> to_list |> List.hd
  in
  check_member_string
    "durable queue read error kind"
    "read_failed"
    "kind"
    read_error;
  check_member_string "durable queue read error path" path "path" read_error
;;

let test_fleet_summary_surfaces_durable_event_queue_parse_error () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "parse-broken-durable-queue-keeper" in
  let path = event_queue_snapshot_path ~base_path ~keeper_name in
  mkdir_p (Filename.dirname path);
  write_file path {|{"schema":"keeper.event_queue.v1","items":{}}|};
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[ keeper_name ]
      ~limit_per_keeper:10
  in
  check_member_string
    "durable queue parse error makes fleet status unknown"
    "unknown"
    "status"
    fleet;
  check_list_has_string
    "durable queue parse error reason is explicit"
    "durable_event_queue_read_error"
    (fleet |> member "status_reasons");
  check bool "durable queue parse error requires operator action" true
    (fleet |> member "operator_action_required" |> to_bool);
  check int "durable queue parse error counted" 1
    (fleet |> member "durable_event_queue_read_error_count" |> to_int);
  let keeper_error =
    fleet |> member "durable_event_queue_read_errors_by_keeper" |> to_list |> List.hd
  in
  check_member_string
    "durable queue parse error keeper name"
    keeper_name
    "keeper_name"
    keeper_error;
  check int "keeper durable queue parse error counted" 1
    (keeper_error |> member "read_error_count" |> to_int);
  let read_error =
    keeper_error |> member "read_errors" |> to_list |> List.hd
  in
  check_member_string
    "durable queue parse error kind"
    "parse_failed"
    "kind"
    read_error;
  check_member_string "durable queue parse error path" path "path" read_error
;;

let test_unknown_reaction_degrades_summary () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "unknown-reaction-keeper" in
  let stimulus = board_stimulus ~post_id:"post-unknown-reaction" () in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  Keeper_reaction_ledger.record_event_queue_reaction
    ~base_path
    ~keeper_name
    ~reaction_kind:(Keeper_reaction_ledger.Unknown_reaction "legacy_custom")
    stimulus;
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "unknown reaction summary status" "degraded" "status" summary;
  check bool "unknown reaction requires operator action" true
    (summary |> member "operator_action_required" |> to_bool);
  check int "unknown reaction counted" 1
    (summary |> member "unknown_reaction_count" |> to_int);
  check int "pending cleared by reaction row" 0
    (summary |> member "pending_stimulus_count" |> to_int)
;;

(* RFC-0020: the stimulus payload is a typed closed variant, so a malformed
   payload is unrepresentable — the prior [test_malformed_typed_payload_degrades_summary]
   covered a parse-error path that can no longer occur and was removed. *)

(* RFC-0266 regression: a recorded [Fusion_completed] stimulus is a recognized
   closed-sum kind and must NOT be miscounted as an unsupported stimulus.  The
   prior string whitelist ([board_signal]/[bootstrap]/[no_progress_recovery])
   dropped [fusion_completed] into [unsupported_stimulus_count], degrading the
   summary on every async fusion wake.  (We assert only the unsupported counter:
   with no reaction row the stimulus is still legitimately pending.) *)
let test_fusion_completed_stimulus_is_supported () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "fusion-keeper" in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    (fusion_completed_stimulus ());
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check int "fusion_completed is not an unsupported stimulus" 0
    (summary |> member "unsupported_stimulus_count" |> to_int)
;;

(* Drift guard: [stimulus_kind_of_string] must stay the inverse of
   [stimulus_kind_to_string] for every closed-sum variant, and reject unknowns.
   Pairs with the exhaustive match in [note_stimulus_kind] so a new variant
   cannot silently fall back to [unsupported]. *)
let test_stimulus_kind_string_roundtrip () =
  let roundtrips k =
    match
      Keeper_reaction_ledger.stimulus_kind_of_string
        (Keeper_reaction_ledger.stimulus_kind_to_string k)
    with
    | Some k' ->
      String.equal
        (Keeper_reaction_ledger.stimulus_kind_to_string k')
        (Keeper_reaction_ledger.stimulus_kind_to_string k)
    | None -> false
  in
  List.iter
    (fun k ->
      check bool "stimulus_kind round-trips through string" true (roundtrips k))
    [ Keeper_reaction_ledger.Board_signal
    ; Keeper_reaction_ledger.Bootstrap
    ; Keeper_reaction_ledger.No_progress_recovery
    ; Keeper_reaction_ledger.Fusion_completed
    ; Keeper_reaction_ledger.Bg_completed
    ; Keeper_reaction_ledger.Schedule_due
    ; Keeper_reaction_ledger.Connector_attention
    ; Keeper_reaction_ledger.Hitl_resolved
    ; Keeper_reaction_ledger.Goal_verification_failed
    ; Keeper_reaction_ledger.Failure_judgment
    ; Keeper_reaction_ledger.Goal_assigned
    ; Keeper_reaction_ledger.Goal_stagnation
    ];
  check bool "unknown stimulus kind string is None" true
    (Option.is_none (Keeper_reaction_ledger.stimulus_kind_of_string "totally_unknown"))
;;

(* Drift guard: [reaction_kind_of_string] is total — known strings round-trip to
   their typed variant, unknown strings preserve the original via
   [Unknown_reaction].  Pairs with the exhaustive match in [note_reaction_kind]. *)
let test_reaction_kind_string_roundtrip () =
  let roundtrips k =
    String.equal
      (Keeper_reaction_ledger.reaction_kind_to_string
         (Keeper_reaction_ledger.reaction_kind_of_string
            (Keeper_reaction_ledger.reaction_kind_to_string k)))
      (Keeper_reaction_ledger.reaction_kind_to_string k)
  in
  List.iter
    (fun k ->
      check bool "reaction_kind round-trips through string" true (roundtrips k))
    [ Keeper_reaction_ledger.Turn_started
    ; Keeper_reaction_ledger.Event_queue_ack
    ; Keeper_reaction_ledger.Event_queue_requeued
    ; Keeper_reaction_ledger.Event_queue_escalated
    ; Keeper_reaction_ledger.Execution_receipt
    ; Keeper_reaction_ledger.Terminal_reason
    ; Keeper_reaction_ledger.Cursor_ack
    ; Keeper_reaction_ledger.Operator_escalation
    ; Keeper_reaction_ledger.Supervisor_recovery_requested
    ];
  check string "unknown reaction string preserved as Unknown_reaction" "legacy_custom"
    (Keeper_reaction_ledger.reaction_kind_to_string
       (Keeper_reaction_ledger.reaction_kind_of_string "legacy_custom"))
;;

let () =
  run
    "keeper_reaction_ledger"
    [ ( "ledger"
      , [ test_case
            "event queue stimulus and turn reaction are durable"
            `Quick
            test_event_queue_stimulus_and_turn_reaction
        ; test_case
            "event queue reaction evidence matches exact stimulus id"
            `Quick
            test_event_queue_reaction_evidence_matches_exact_stimulus_id
        ; test_case
            "failure judgment operator attention is typed and visible"
            `Quick
            test_failure_judgment_operator_attention_is_typed_and_visible
        ; test_case
            "cursor ack is replayable state entry"
            `Quick
            test_cursor_ack_is_replayable_state_entry
        ; test_case
            "execution receipt links to reaction ledger"
            `Quick
            test_execution_receipt_links_to_reaction_ledger
        ; test_case
            "summary observes passive-only without attention"
            `Quick
            test_summary_observes_passive_only_without_attention
        ; test_case
            "summary degrades unknown completion-contract result"
            `Quick
            test_summary_degrades_unknown_completion_contract_result
        ; test_case
            "completion-contract parser and attention use canonical receipt type"
            `Quick
            test_completion_contract_result_canonical_roundtrip
        ; test_case
            "summary observes passive-only without work-scope attention"
            `Quick
            test_summary_observes_passive_only_without_work_scope_attention
        ; test_case
            "summary marks unreacted and reacted stimuli"
            `Quick
            test_summary_marks_unreacted_and_reacted_stimuli
        ; test_case
            "summary cursor ack sweeps covered board stimuli"
            `Quick
            test_summary_cursor_ack_sweeps_covered_board_stimuli
        ; test_case
            "summary cursor ack respects board post id tiebreaker"
            `Quick
            test_summary_cursor_ack_respects_post_id_tiebreaker
        ; test_case
            "no-progress recovery stimulus is typed"
            `Quick
            test_no_progress_recovery_stimulus_is_typed
        ; test_case
            "no-progress recovery reaction clears pending"
            `Quick
            test_no_progress_recovery_reaction_clears_pending
        ; test_case
            "unrelated keeper reaction does not clear no-progress recovery pending"
            `Quick
            test_no_progress_recovery_unrelated_reaction_does_not_clear_pending
        ; test_case
            "cursor ack alone does not clear no-progress recovery pending"
            `Quick
            test_no_progress_recovery_cursor_ack_does_not_clear_pending
        ; test_case
            "summary links passive-only observation to pending recovery"
            `Quick
            test_summary_links_passive_only_observation_to_pending_recovery
        ; test_case
            "fleet summary surfaces durable event queue backlog"
            `Quick
            test_fleet_summary_surfaces_durable_event_queue_backlog
        ; test_case
            "fleet summary discovers durable event queue backlog without meta name"
            `Quick
            test_fleet_summary_discovers_durable_event_queue_backlog_without_meta_name
        ; test_case
            "fleet summary surfaces durable event queue discovery errors"
            `Quick
            test_fleet_summary_surfaces_durable_event_queue_discovery_error
        ; test_case
            "fleet summary separates fresh durable event queue backlog from stale"
            `Quick
            test_fleet_summary_allows_nonstale_durable_event_queue_backlog
        ; test_case
            "fleet summary surfaces durable event queue read errors"
            `Quick
            test_fleet_summary_surfaces_durable_event_queue_read_error
        ; test_case
            "fleet summary surfaces durable event queue parse errors"
            `Quick
            test_fleet_summary_surfaces_durable_event_queue_parse_error
        ; test_case
            "unknown reaction degrades summary"
            `Quick
            test_unknown_reaction_degrades_summary
        ; test_case
            "fusion_completed stimulus is supported (RFC-0266)"
            `Quick
            test_fusion_completed_stimulus_is_supported
        ; test_case
            "stimulus_kind string round-trip drift guard"
            `Quick
            test_stimulus_kind_string_roundtrip
        ; test_case
            "reaction_kind string round-trip drift guard"
            `Quick
            test_reaction_kind_string_roundtrip
        ] )
    ]
;;
