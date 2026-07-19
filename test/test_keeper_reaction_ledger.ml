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

let fusion_completed_stimulus ?(run_id = "fus-ledger-1") () :
  Keeper_event_queue.stimulus
  =
  { post_id = "fusion-run:" ^ run_id
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = 1234.5
  ; payload =
      Keeper_event_queue.Fusion_completed
        { run_id
        ; terminal = Keeper_event_queue.Fusion_succeeded "use approach B"
        ; board_post_id = "post-fus"
        ; channel = Keeper_continuation_channel.unrouted "test fixture"
        }
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

let manual_compaction_stimulus () : Keeper_event_queue.stimulus =
  { post_id = Keeper_event_queue.manual_compaction_post_id
  ; urgency = Keeper_event_queue.Immediate
  ; arrived_at = 1234.5
  ; payload = Keeper_event_queue.Manual_compaction_requested
  }
;;

let no_compaction_settlement ~turn_count reason :
  Keeper_event_queue_state.settlement
  =
  let trace_id =
    Keeper_id.Trace_id.of_string "trace-ledger-no-compaction"
    |> require_ok "parse no-compaction trace"
  in
  let source =
    Keeper_checkpoint_ref.of_persisted
      ~trace_id
      ~generation:3
      ~turn_count
      ~sha256:(String.make 64 'a')
    |> Result.get_ok
  in
  Keeper_event_queue_state.No_compaction { source; reason }
;;

let persist_transition_outbox ~base_path ~keeper_name ~settlement stimuli =
  Keeper_event_queue_persistence.update_result
    ~base_path
    ~keeper_name
    (fun pending -> List.fold_left Keeper_event_queue.enqueue pending stimuli)
  |> require_ok "persist transition sources";
  let lease =
    (match stimuli with
     | [ _ ] ->
       Keeper_event_queue_persistence.claim_when_result
         ~base_path
         ~keeper_name
         ~claimed_at:1235.0
         ~ready:(fun _ -> true)
         ()
     | _ ->
       Keeper_event_queue_persistence.claim_board_result
         ~base_path
         ~keeper_name
         ~claimed_at:1235.0
         ())
    |> require_ok "claim transition receipt stimulus"
  in
  let lease =
    match lease with
    | Some lease -> lease
    | None -> fail "transition receipt stimulus was not claimed"
  in
  let receipt =
    Keeper_event_queue_persistence.settle_result
      ~base_path
      ~keeper_name
      ~settled_at:1236.0
      ~lease
      ~settlement
      ()
    |> require_ok "settle transition receipt stimulus"
    |> function
    | Keeper_event_queue_persistence.Settled receipt -> receipt
    | Keeper_event_queue_persistence.Already_settled _ ->
      fail "first transition receipt settlement was already settled"
    | Keeper_event_queue_persistence.Committed_followup_failed { detail; _ } ->
      failf "settlement follow-up failed: %s" detail
  in
  (match
     Keeper_event_queue_persistence.transition_outbox_result
       ~base_path
       ~keeper_name
     |> require_ok "read persisted transition outbox"
   with
   | [ entry ] ->
     check bool "outbox retains the settled receipt" true
       (Keeper_event_queue_state.transition_receipt_equal entry.receipt receipt)
   | [] | _ :: _ :: _ -> fail "settled transition did not produce one outbox entry");
  receipt
;;

let check_member_string label expected key json =
  check string label expected (json |> member key |> to_string)
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

let reaction_ledger_dir ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat
       (Filename.concat
          (Filename.concat (Common.masc_dir_from_base_path ~base_path) "keepers")
          keeper_name)
       "reaction-ledger")
    "v4"
;;

let reaction_ledger_store ~base_path ~keeper_name =
  Dated_jsonl.create
    ~base_dir:(reaction_ledger_dir ~base_path ~keeper_name)
    ()
;;

let read_recent_rows ~base_path ~keeper_name ~limit =
  match
    Dated_jsonl.read_recent_result
      (reaction_ledger_store ~base_path ~keeper_name)
      limit
  with
  | Error error -> fail (Dated_jsonl.read_error_to_string error)
  | Ok entries ->
    List.map
      (function
        | Dated_jsonl.Parsed row -> row
        | Dated_jsonl.Malformed_json { path; line_number; detail } ->
          failf
            "unexpected malformed test row %s%s: %s"
            path
            (match line_number with
             | Some value -> Printf.sprintf ":%d" value
             | None -> "")
            detail)
      entries
;;

let require_complete_evidence label = function
  | Error error ->
    failf
      "%s: %s"
      label
      (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string error)
  | Ok (Keeper_reaction_ledger.Evidence_complete evidence) -> evidence
  | Ok (Keeper_reaction_ledger.Evidence_quarantined { first_reason; _ }) ->
    failf
      "%s: quarantined (%s)"
      label
      (Keeper_reaction_ledger.row_quarantine_reason_to_string first_reason)
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
  Keeper_reaction_ledger.record_event_queue_turn_started
    ~base_path
    ~keeper_name
    stimulus;
  let rows =
    read_recent_rows ~base_path ~keeper_name ~limit:10
  in
  check int "two rows persisted" 2 (List.length rows);
  let stimulus_row = List.nth rows 0 in
  check_member_string "stimulus schema" "keeper.reaction_ledger.v4" "schema" stimulus_row;
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
  check string "scheduled ledger id preserves occurrence" stimulus.post_id stimulus_id;
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    unrelated;
  let stimulus_only =
    Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path
      ~keeper_name
      ~stimulus_id
    |> require_complete_evidence "stimulus-only evidence"
  in
  check bool "exact stimulus seen" true stimulus_only.stimulus_seen;
  check bool "turn reaction absent" false stimulus_only.turn_started_seen;
  check bool "event queue ack absent" false stimulus_only.event_queue_ack_seen;
  check int "one exact row before reaction" 1 stimulus_only.matched_record_count;
  Keeper_reaction_ledger.record_event_queue_turn_started
    ~base_path
    ~keeper_name
    stimulus;
  let reacted =
    Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path
      ~keeper_name
      ~stimulus_id
    |> require_complete_evidence "turn-started evidence"
  in
  check bool "exact stimulus still seen" true reacted.stimulus_seen;
  check bool "turn reaction seen" true reacted.turn_started_seen;
  check bool "event queue ack still absent" false reacted.event_queue_ack_seen;
  check int "two exact rows after reaction" 2 reacted.matched_record_count;
  ignore
    (persist_transition_outbox
       ~base_path
       ~keeper_name
       ~settlement:Keeper_event_queue_state.Ack
       [ stimulus ]);
  Keeper_reaction_ledger.project_event_queue_transition_outbox_result
    ~base_path
    ~keeper_name
  |> require_ok "record event queue ack";
  let acknowledged =
    Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path
      ~keeper_name
      ~stimulus_id
    |> require_complete_evidence "acknowledged evidence"
  in
  check bool "event queue ack seen" true acknowledged.event_queue_ack_seen;
  check int "three exact rows after ack" 3 acknowledged.matched_record_count;
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check int "summary counts event queue ack" 1
    (summary |> member "event_queue_ack_count" |> to_int);
  check int "current rows are not quarantined" 0
    (summary |> member "quarantined_row_count" |> to_int);
  let missing =
    Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path
      ~keeper_name
      ~stimulus_id:"stimulus:missing"
    |> require_complete_evidence "missing evidence"
  in
  check bool "missing stimulus absent" false missing.stimulus_seen;
  check bool "missing reaction absent" false missing.turn_started_seen;
  check bool "missing ack absent" false missing.event_queue_ack_seen;
  check int "missing exact rows" 0 missing.matched_record_count;
  match
    Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path
      ~keeper_name
      ~stimulus_id:""
  with
  | Error Keeper_reaction_ledger.Evidence_invalid_stimulus_id -> ()
  | Error (Keeper_reaction_ledger.Evidence_read_error _) ->
    fail "empty evidence identity reached storage"
  | Ok _ -> fail "empty evidence identity was accepted"
;;

let test_failure_judgment_external_input_is_typed_history () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "judgment-attention-keeper" in
  let stimulus = failure_judgment_stimulus () in
  ignore
    (persist_transition_outbox
       ~base_path
       ~keeper_name
      ~settlement:
        (Keeper_event_queue_state.Escalate
           { reason =
               Keeper_event_queue_state.Failure_judgment_external_input_requested
                 { judge_runtime_id = "opaque-judge-runtime"
                 ; rationale = "Required external input is unavailable."
                 }
           ; successor = None
           })
       [ stimulus ]);
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  Keeper_reaction_ledger.project_event_queue_transition_outbox_result
    ~base_path
    ~keeper_name
  |> require_ok "record external-input judgment transition";
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "resolved judgment is historical" "ok" "status" summary;
  check bool "historical judgment is not current action" false
    (summary |> member "operator_action_required" |> to_bool);
  check int "external-input judgment counted" 1
    (summary |> member "event_queue_external_input_count" |> to_int);
  check int "typed transition row is current" 0
    (summary |> member "quarantined_row_count" |> to_int);
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[ keeper_name ]
      ~limit_per_keeper:10
  in
  check bool "fleet history is not current action" false
    (fleet |> member "operator_action_required" |> to_bool);
  check int "fleet external-input history counted" 1
    (fleet |> member "event_queue_external_input_count" |> to_int);
  check (list string) "fleet has no false current reason" []
    (fleet |> member "status_reasons" |> to_list |> List.map to_string)
;;

let test_transition_reactions_distinguish_ordered_sources () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "batch-projection-keeper" in
  let first = board_stimulus ~post_id:"shared-post" ~updated_at:1.0 () in
  let second = board_stimulus ~post_id:"shared-post" ~updated_at:2.0 () in
  let receipt =
    persist_transition_outbox
      ~base_path
      ~keeper_name
      ~settlement:Keeper_event_queue_state.Ack
      [ first; second ]
  in
  Keeper_reaction_ledger.project_event_queue_transition_outbox_result
    ~base_path
    ~keeper_name
  |> require_ok "record ordered settlement sources";
  let rows =
    read_recent_rows
      ~base_path
      ~keeper_name
      ~limit:10
  in
  check (list string)
    "ordered source ids are collision-free"
    [ receipt.event_id ^ ":source:0"; receipt.event_id ^ ":source:1" ]
    (List.map (fun row -> row |> member "event_id" |> to_string) rows);
  check (list int)
    "source index remains observable"
    [ 0; 1 ]
    (List.map
       (fun row -> row |> member "reaction" |> member "source_index" |> to_int)
       rows);
  check (list int)
    "every source is bound to the exact outbox cardinality"
    [ 2; 2 ]
    (List.map
       (fun row -> row |> member "reaction" |> member "source_count" |> to_int)
       rows);
  check (list string)
    "shared stimulus id does not collapse ordered sources"
    [ "board:shared-post"; "board:shared-post" ]
    (List.map (fun row -> row |> member "stimulus_id" |> to_string) rows);
  Dated_jsonl.append
    (reaction_ledger_store ~base_path ~keeper_name)
    (List.hd rows);
  let evidence =
    Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path
      ~keeper_name
      ~stimulus_id:"board:shared-post"
    |> require_complete_evidence "crash replay evidence"
  in
  check bool "replayed transition remains acknowledged" true
    evidence.event_queue_ack_seen;
  check int "deterministic event identity deduplicates crash replay" 2
    evidence.matched_record_count
;;

let test_transition_reaction_rejects_recombined_stimulus_identity () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "receipt-binding-keeper" in
  let stimulus = board_stimulus ~post_id:"receipt-source" () in
  ignore
    (persist_transition_outbox
       ~base_path
       ~keeper_name
       ~settlement:Keeper_event_queue_state.Ack
       [ stimulus ]);
  Keeper_reaction_ledger.project_event_queue_transition_outbox_result
    ~base_path
    ~keeper_name
  |> require_ok "record receipt-bound settlement";
  let valid_row =
    read_recent_rows ~base_path ~keeper_name ~limit:1 |> latest_row
  in
  let forged_stimulus_id = "board:recombined-source" in
  let recombined_row =
    match valid_row with
    | `Assoc fields ->
      `Assoc
        (("stimulus_id", `String forged_stimulus_id)
         :: List.remove_assoc "stimulus_id" fields)
    | _ -> fail "settlement writer did not emit an object"
  in
  Dated_jsonl.append
    (reaction_ledger_store ~base_path ~keeper_name)
    recombined_row;
  match
    Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path
      ~keeper_name
      ~stimulus_id:forged_stimulus_id
  with
  | Ok
      (Keeper_reaction_ledger.Evidence_quarantined
        { evidence; first_reason }) ->
    check bool "recombined receipt cannot become an ack" false
      evidence.event_queue_ack_seen;
    check int "recombined row is quarantined" 1
      evidence.quarantined_record_count;
    check string
      "source binding failure is typed"
      "transition_source_identity_mismatch"
      (Keeper_reaction_ledger.row_quarantine_reason_to_string first_reason)
  | Ok (Keeper_reaction_ledger.Evidence_complete _) ->
    fail "recombined receipt evidence was accepted"
  | Error error ->
    fail
      (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string error)
;;

let test_current_rows_require_complete_writer_shape () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "closed-row-shape-keeper" in
  let stimulus = board_stimulus ~post_id:"closed-row" () in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  Keeper_reaction_ledger.record_event_queue_turn_started
    ~base_path
    ~keeper_name
    stimulus;
  let rows = read_recent_rows ~base_path ~keeper_name ~limit:2 in
  let remove_nested_field outer inner = function
    | `Assoc fields ->
      let nested =
        match List.assoc_opt outer fields with
        | Some (`Assoc nested_fields) ->
          `Assoc (List.remove_assoc inner nested_fields)
        | _ -> failf "missing nested object %s" outer
      in
      `Assoc ((outer, nested) :: List.remove_assoc outer fields)
    | _ -> fail "ledger writer did not emit an object"
  in
  Dated_jsonl.append
    (reaction_ledger_store ~base_path ~keeper_name)
    (remove_nested_field "stimulus" "urgency" (List.nth rows 0));
  Dated_jsonl.append
    (reaction_ledger_store ~base_path ~keeper_name)
    (remove_nested_field "reaction" "post_id" (List.nth rows 1));
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check int "incomplete current rows are quarantined" 2
    (summary |> member "quarantined_row_count" |> to_int);
  let reasons =
    summary
    |> member "quarantine_reason_counts"
    |> to_list
    |> List.map (fun item -> item |> member "reason" |> to_string)
  in
  check bool "missing stimulus urgency is typed" true
    (List.mem "missing_stimulus_urgency" reasons);
  check bool "missing reaction post id is typed" true
    (List.mem "missing_reaction_post_id" reasons)
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
    read_recent_rows ~base_path ~keeper_name ~limit:1
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
  Keeper_reaction_ledger.record_event_queue_turn_started
    ~base_path
    ~keeper_name
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
    (board_stimulus ~post_id:"post-live-backlog-2" ());
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
         && json |> member "count" |> to_int = 2)
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

let test_unknown_reaction_is_quarantined_without_clearing_pending () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "unknown-reaction-keeper" in
  let stimulus = board_stimulus ~post_id:"post-unknown-reaction" () in
  let stimulus_id = Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  Dated_jsonl.append
    (reaction_ledger_store ~base_path ~keeper_name)
    (`Assoc
        [ "schema", `String "keeper.reaction_ledger.v4"
        ; "record_kind", `String "reaction"
        ; "event_id", `String (stimulus_id ^ ":reaction:turn_started")
        ; "keeper_name", `String keeper_name
        ; "recorded_at_unix", `Float 1235.0
        ; "stimulus_id", `String stimulus_id
        ; ( "reaction"
          , `Assoc
              [ "kind", `String "unknown_custom"
              ; "source", `String "keeper_event_queue"
              ] )
        ]);
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check_member_string "unknown reaction summary status" "degraded" "status" summary;
  check bool "unknown reaction requires operator action" true
    (summary |> member "operator_action_required" |> to_bool);
  check int "unknown reaction quarantined" 1
    (summary |> member "quarantined_row_count" |> to_int);
  check int "unknown reaction contributes no current reaction" 0
    (summary |> member "reaction_count" |> to_int);
  check int "unknown reaction cannot clear pending" 1
    (summary |> member "pending_stimulus_count" |> to_int);
  match
    Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path
      ~keeper_name
      ~stimulus_id
  with
  | Ok
      (Keeper_reaction_ledger.Evidence_quarantined
        { evidence; first_reason }) ->
    check int "only current stimulus matches" 1 evidence.matched_record_count;
    check int "matching invalid row is explicit" 1 evidence.quarantined_record_count;
    check bool "invalid reaction is not a turn" false evidence.turn_started_seen;
    check string
      "typed quarantine reason"
      "unknown_reaction_kind"
      (Keeper_reaction_ledger.row_quarantine_reason_to_string first_reason)
  | Error error ->
    fail
      (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string error)
  | Ok (Keeper_reaction_ledger.Evidence_complete _) ->
    fail "matching invalid row was projected as complete evidence"
;;

(* RFC-0020: the stimulus payload is a typed closed variant, so a malformed
   payload is unrepresentable — the prior [test_malformed_typed_payload_degrades_summary]
   covered a parse-error path that can no longer occur and was removed. *)

(* RFC-0266 regression: a recorded [Fusion_completed] stimulus is a recognized
   closed-sum kind and must NOT be miscounted as an unsupported stimulus.  The
   prior string whitelist
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
  check int "fusion_completed survives the closed row decoder" 0
    (summary |> member "quarantined_row_count" |> to_int)
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
    ; Keeper_reaction_ledger.Fusion_completed
    ; Keeper_reaction_ledger.Bg_completed
    ; Keeper_reaction_ledger.Schedule_due
    ; Keeper_reaction_ledger.Connector_attention
    ; Keeper_reaction_ledger.Hitl_resolved
    ; Keeper_reaction_ledger.Failure_judgment
    ; Keeper_reaction_ledger.Manual_compaction
    ; Keeper_reaction_ledger.Goal_assigned
    ];
  check bool "unknown stimulus kind string is None" true
    (Option.is_none (Keeper_reaction_ledger.stimulus_kind_of_string "totally_unknown"))
;;

(* Drift guard: known reaction labels round-trip through the closed decoder;
   unknown labels remain typed failures and never enter the reaction algebra. *)
let test_reaction_kind_string_roundtrip () =
  let roundtrips k =
    match
      Keeper_reaction_ledger.reaction_kind_of_string
        (Keeper_reaction_ledger.reaction_kind_to_string k)
    with
    | Ok parsed ->
      String.equal
        (Keeper_reaction_ledger.reaction_kind_to_string parsed)
        (Keeper_reaction_ledger.reaction_kind_to_string k)
    | Error _ -> false
  in
  List.iter
    (fun k ->
      check bool "reaction_kind round-trips through string" true (roundtrips k))
    [ Keeper_reaction_ledger.Turn_started
    ; Keeper_reaction_ledger.Event_queue_ack
    ; Keeper_reaction_ledger.Event_queue_no_compaction
    ; Keeper_reaction_ledger.Event_queue_cancelled
    ; Keeper_reaction_ledger.Event_queue_requeued
    ; Keeper_reaction_ledger.Event_queue_escalated
    ; Keeper_reaction_ledger.Cursor_ack
    ];
  match Keeper_reaction_ledger.reaction_kind_of_string "unknown_custom" with
  | Error (Keeper_reaction_ledger.Unknown_reaction_kind value) ->
    check string "unknown reaction decoder preserves evidence" "unknown_custom" value
  | Ok _ -> fail "unknown reaction string must not decode"
;;

let test_cancelled_transition_is_projected_as_typed_history () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "cancelled-transition-keeper" in
  let stimulus = board_stimulus () in
  let pending = Keeper_event_queue.enqueue Keeper_event_queue.empty stimulus in
  let state = Keeper_event_queue_state.with_pending pending Keeper_event_queue_state.empty in
  let claimed, lease =
    Keeper_event_queue_state.claim_when
      ~claimed_at:1235.0
      ~ready:(fun _ -> true)
      state
    |> require_ok "claim cancellation stimulus"
  in
  let lease =
    match lease with
    | Some lease -> lease
    | None -> fail "cancellation stimulus was not claimed"
  in
  let cancellation : Keeper_event_queue_state.accepted_cancellation =
    { source_revision = Keeper_event_queue_state.revision claimed
    ; owner_generation = 7
    ; operator_operation_id = "operator-cancel-1"
    ; reason = "operator rejected paused work"
    }
  in
  let cancelled, _ =
    Keeper_event_queue_state.cancel_accepted
      ~current_owner_generation:7
      ~settled_at:1236.0
      ~lease
      ~cancellation
      claimed
    |> require_ok "commit cancellation receipt"
  in
  let snapshot_path = event_queue_snapshot_path ~base_path ~keeper_name in
  mkdir_p (Filename.dirname snapshot_path);
  write_file
    snapshot_path
    (Yojson.Safe.to_string (Keeper_event_queue_state.to_yojson cancelled));
  Keeper_reaction_ledger.project_event_queue_transition_outbox_result
    ~base_path
    ~keeper_name
  |> require_ok "project cancellation receipt";
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check int "summary counts accepted cancellation" 1
    (summary |> member "event_queue_cancelled_count" |> to_int);
  check int "typed cancellation row is current" 0
    (summary |> member "quarantined_row_count" |> to_int)
;;

let test_unexpected_schema_rows_are_quarantined_without_double_counting () =
  with_temp_base
  @@ fun base_path ->
  let keeper_name = "sangsu" in
  let stimulus = board_stimulus () in
  let stimulus_id = Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name
    stimulus;
  let current_event_id =
    read_recent_rows ~base_path ~keeper_name ~limit:1
    |> latest_row
    |> member "event_id"
    |> to_string
  in
  let store = reaction_ledger_store ~base_path ~keeper_name in
  Dated_jsonl.append
    store
    (`Assoc
        [ "schema", `String "keeper.reaction_ledger.foreign"
        ; "record_kind", `String "stimulus"
        ; "event_id", `String current_event_id
        ; "keeper_name", `String keeper_name
        ; "recorded_at_unix", `Float 1200.0
        ; "stimulus_id", `String stimulus_id
        ; ( "stimulus"
          , `Assoc
              [ "kind", `String "board_signal"
              ; "source", `String "keeper_event_queue"
              ; "post_id", `String stimulus.post_id
              ] )
        ]);
  Dated_jsonl.append
    store
    (`Assoc
        [ "schema", `String "keeper.reaction_ledger.foreign"
        ; "record_kind", `String "reaction"
        ; "event_id", `String (stimulus_id ^ ":reaction:turn_started")
        ; "keeper_name", `String keeper_name
        ; "recorded_at_unix", `Float 1201.0
        ; "stimulus_id", `String stimulus_id
        ; ( "reaction"
          , `Assoc
              [ "kind", `String "turn_started"
              ; "source", `String "keeper_event_queue"
              ] )
        ]);
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check
    int
    "only the current generation contributes"
    1
    (summary |> member "stimulus_count" |> to_int);
  check int "unexpected reaction contributes zero" 0
    (summary |> member "reaction_count" |> to_int);
  check int "unexpected reaction cannot clear current pending" 1
    (summary |> member "pending_stimulus_count" |> to_int);
  check
    int
    "both unexpected rows are quarantined"
    2
    (summary |> member "quarantined_row_count" |> to_int);
  let unexpected_reason =
    summary |> member "quarantine_reason_counts" |> to_list |> List.hd
  in
  check_member_string
    "unexpected schema reason is typed"
    "unexpected_schema"
    "reason"
    unexpected_reason;
  check int "unexpected schema reason count" 2
    (unexpected_reason |> member "count" |> to_int);
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[ keeper_name ]
      ~limit_per_keeper:10
  in
  check int "fleet exposes quarantined rows" 2
    (fleet |> member "quarantined_row_count" |> to_int);
  check_list_has_string
    "fleet status names quarantine"
    "reaction_ledger_quarantined_row"
    (fleet |> member "status_reasons")
;;

let test_quarantine_is_keeper_local () =
  with_temp_base
  @@ fun base_path ->
  let quarantined_keeper = "quarantined-keeper" in
  let healthy_keeper = "healthy-keeper" in
  let quarantined_stimulus = board_stimulus ~post_id:"post-quarantined" () in
  let quarantined_stimulus_id =
    Keeper_reaction_ledger.stimulus_id_of_event_queue quarantined_stimulus
  in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name:quarantined_keeper
    quarantined_stimulus;
  Dated_jsonl.append
    (reaction_ledger_store ~base_path ~keeper_name:quarantined_keeper)
    (`Assoc
        [ "schema", `String "keeper.reaction_ledger.v2"
        ; "record_kind", `String "reaction"
        ; ( "event_id"
          , `String (quarantined_stimulus_id ^ ":reaction:turn_started") )
        ; "keeper_name", `String quarantined_keeper
        ; "recorded_at_unix", `Float 1201.0
        ; "stimulus_id", `String quarantined_stimulus_id
        ; ( "reaction"
          , `Assoc
              [ "kind", `String "turn_started"
              ; "source", `String "keeper_event_queue"
              ] )
        ]);
  let healthy_stimulus = board_stimulus ~post_id:"post-healthy" () in
  let healthy_stimulus_id =
    Keeper_reaction_ledger.stimulus_id_of_event_queue healthy_stimulus
  in
  Keeper_reaction_ledger.record_event_queue_stimulus
    ~base_path
    ~keeper_name:healthy_keeper
    healthy_stimulus;
  Keeper_reaction_ledger.record_event_queue_turn_started
    ~base_path
    ~keeper_name:healthy_keeper
    healthy_stimulus;
  (match
     Keeper_reaction_ledger.event_queue_reaction_evidence_result
       ~base_path
       ~keeper_name:healthy_keeper
       ~stimulus_id:healthy_stimulus_id
   with
   | Ok (Keeper_reaction_ledger.Evidence_complete evidence) ->
     check bool "healthy keeper turn remains visible" true evidence.turn_started_seen;
     check int "healthy keeper has no quarantine" 0 evidence.quarantined_record_count
   | Ok (Keeper_reaction_ledger.Evidence_quarantined _) ->
     fail "quarantine leaked across keeper stores"
   | Error error ->
     fail
       ("healthy keeper read failed: "
        ^ Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string
            error));
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[ quarantined_keeper; healthy_keeper ]
      ~limit_per_keeper:10
  in
  let healthy_summary =
    fleet
    |> member "keepers"
    |> to_list
    |> List.find (fun summary ->
      String.equal (summary |> member "keeper_name" |> to_string) healthy_keeper)
  in
  check_member_string "healthy keeper summary stays ok" "ok" "status" healthy_summary;
  check int "healthy keeper pending stays cleared" 0
    (healthy_summary |> member "pending_stimulus_count" |> to_int);
  check int "healthy keeper current reaction is preserved" 1
    (healthy_summary |> member "reaction_count" |> to_int)
;;

let test_syntax_error_does_not_claim_an_occurrence_identity () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "strict-evidence-keeper" in
  let ledger_dir = reaction_ledger_dir ~base_path ~keeper_name in
  let malformed_month = Filename.concat ledger_dir "2026-01" in
  mkdir_p malformed_month;
  let malformed_path = Filename.concat malformed_month "01.jsonl" in
  write_file malformed_path "not-json\n";
  let evidence =
    Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path
      ~keeper_name
      ~stimulus_id:"schedule:test-occurrence"
    |> require_complete_evidence "unattributed syntax row"
  in
  check int "no row is assigned to the queried occurrence" 0
    evidence.matched_record_count;
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check int "malformed summary row is quarantined" 1
    (summary |> member "quarantined_row_count" |> to_int);
  let reason = summary |> member "quarantine_reason_counts" |> to_list |> List.hd in
  check_member_string "syntax quarantine reason" "malformed_json" "reason" reason
;;

let test_missing_identity_does_not_claim_an_occurrence_identity () =
  with_temp_base @@ fun base_path ->
  let keeper_name = "identity-incomplete-keeper" in
  Dated_jsonl.append
    (reaction_ledger_store ~base_path ~keeper_name)
    (`Assoc
        [ "schema", `String "keeper.reaction_ledger.v4"
        ; "record_kind", `String "stimulus"
        ; "event_id", `String "unattributed-event"
        ; "keeper_name", `String keeper_name
        ; "recorded_at_unix", `Float 1234.0
        ; ( "stimulus"
          , `Assoc
              [ "kind", `String "schedule_due"
              ; "source", `String "keeper_event_queue"
              ] )
        ]);
  let evidence =
    Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path
      ~keeper_name
      ~stimulus_id:"schedule:test-occurrence"
    |> require_complete_evidence "identity-less row"
  in
  check int "identity-less row is not assigned to the query" 0
    evidence.matched_record_count;
  let summary =
    Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
  in
  check int "identity-less row remains operator-visible" 1
    (summary |> member "quarantined_row_count" |> to_int);
  let reason = summary |> member "quarantine_reason_counts" |> to_list |> List.hd in
  check_member_string "identity quarantine reason" "missing_stimulus_id" "reason" reason
;;

let test_fleet_summary_aggregates_no_compaction_count () =
  with_temp_base
  @@ fun base_path ->
  let record_no_compaction keeper_name =
    let stimulus = manual_compaction_stimulus () in
    ignore
      (persist_transition_outbox
         ~base_path
         ~keeper_name
         ~settlement:
           (no_compaction_settlement
              ~turn_count:7
              Keeper_event_queue_state.No_eligible_history)
         [ stimulus ]);
    Keeper_reaction_ledger.record_event_queue_stimulus
      ~base_path
      ~keeper_name
      stimulus;
    Keeper_reaction_ledger.project_event_queue_transition_outbox_result
      ~base_path
      ~keeper_name
    |> require_ok "project no-compaction transition"
  in
  let keeper_a = "no-compaction-keeper-a" in
  let keeper_b = "no-compaction-keeper-b" in
  record_no_compaction keeper_a;
  record_no_compaction keeper_b;
  List.iter
    (fun keeper_name ->
      let summary =
        Keeper_reaction_ledger.summary_for_keeper ~base_path ~keeper_name ~limit:10
      in
      check int "per-keeper no-compaction count" 1
        (summary |> member "event_queue_no_compaction_count" |> to_int))
    [ keeper_a; keeper_b ];
  let fleet =
    Keeper_reaction_ledger.fleet_summary_json
      ~base_path
      ~keeper_names:[ keeper_a; keeper_b ]
      ~limit_per_keeper:10
  in
  check int "fleet summary aggregates no-compaction across keepers" 2
    (fleet |> member "event_queue_no_compaction_count" |> to_int)
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
            "unexpected schema rows cannot double-count current occurrences"
            `Quick
            test_unexpected_schema_rows_are_quarantined_without_double_counting
        ; test_case
            "quarantine remains keeper-local"
            `Quick
            test_quarantine_is_keeper_local
        ; test_case
            "event queue reaction evidence matches exact stimulus id"
            `Quick
            test_event_queue_reaction_evidence_matches_exact_stimulus_id
        ; test_case
            "syntax error cannot claim an occurrence identity"
            `Quick
            test_syntax_error_does_not_claim_an_occurrence_identity
        ; test_case
            "missing identity cannot claim an occurrence identity"
            `Quick
            test_missing_identity_does_not_claim_an_occurrence_identity
        ; test_case
            "failure judgment external input is typed history"
            `Quick
            test_failure_judgment_external_input_is_typed_history
        ; test_case
            "transition reactions distinguish ordered sources"
            `Quick
            test_transition_reactions_distinguish_ordered_sources
        ; test_case
            "transition reaction rejects recombined stimulus identity"
            `Quick
            test_transition_reaction_rejects_recombined_stimulus_identity
        ; test_case
            "current rows require complete writer shape"
            `Quick
            test_current_rows_require_complete_writer_shape
        ; test_case
            "cursor ack is replayable state entry"
            `Quick
            test_cursor_ack_is_replayable_state_entry
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
            "unknown reaction is quarantined without clearing pending"
            `Quick
            test_unknown_reaction_is_quarantined_without_clearing_pending
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
        ; test_case
            "fleet summary aggregates no-compaction count across keepers"
            `Quick
            test_fleet_summary_aggregates_no_compaction_count
        ; test_case
            "accepted cancellation projects as typed history"
            `Quick
            test_cancelled_transition_is_projected_as_typed_history
        ] )
    ]
;;
