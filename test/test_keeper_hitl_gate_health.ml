open Alcotest

module H = Keeper_hitl_gate_health
module Q = Keeper_approval_queue_rules_types
module R = Masc.Keeper_tool_approval_registry

let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

let section = testable Yojson.Safe.pp Yojson.Safe.equal

let field name = function
  | `Assoc fields -> List.assoc name fields
  | _ -> failwith "section is not an object"

let assoc_int name json =
  match field name json with
  | `Int n -> n
  | other -> failwith (Printf.sprintf "%s is not an int: %s" name (Yojson.Safe.to_string other))

let assoc_string name json =
  match field name json with
  | `String s -> s
  | other -> failwith (Printf.sprintf "%s is not a string: %s" name (Yojson.Safe.to_string other))

let assoc_bool name json =
  match field name json with
  | `Bool b -> b
  | other -> failwith (Printf.sprintf "%s is not a bool: %s" name (Yojson.Safe.to_string other))

let wait ~tool_call_id ~asked_at =
  { R.keeper_name = "keeper.one"
  ; tool_call_id
  ; tool_name = "Execute"
  ; args = "{}"
  ; question = "run?"
  ; because = "policy: ask"
  ; asked_at
  ; timeout_sec = 180.0
  }

let entry ~id ~requested_at ~summary_status ~exact_attempt ~disposition =
  let module Q = Keeper_approval_queue_rules_types in
  {
    Q.id
  ; keeper_name = "keeper.one"
  ; tool_name = "Execute"
  ; input_hash = "input-hash"
  ; input = `Assoc []
  ; sequence = 1
  ; requested_at
  ; turn_id = None
  ; request_context = None
  ; observation = None
  ; task_id = None
  ; goal_id = None
  ; continuation_channel = Keeper_continuation_channel.unrouted id
  ; audit_base_path = "/base"
  ; summary_status
  ; exact_attempt
  ; summary_attempt_disposition = disposition
  }

let not_requested ~id ~requested_at =
  entry ~id ~requested_at
    ~summary_status:Q.Summary_not_requested
    ~exact_attempt:Q.Exact_unbound
    ~disposition:Q.Summary_attempt_ready

(* The state [Exact_transition.bind] writes for the whole judgment call: an
   in-flight summary over a dispatch-uncertain exact attempt, the pair the
   codec admits for a pending summary. Live or stranded is not in the row. *)
let in_flight ~id ~requested_at =
  let binding =
    Q.make_exact_attempt_binding ~approval_id:id ~input_hash:"h" ~sequence:1
      ~slot_id:"slot" ~call_id:"call" ~plan_fingerprint:"p"
      ~request_body_sha256:"s" ()
  in
  entry ~id ~requested_at
    ~summary_status:Q.Summary_pending
    ~exact_attempt:(Q.Exact_bound binding)
    ~disposition:Q.Summary_attempt_in_flight

(* The restart-behind pair (design B3): [in_flight] with no live admission. *)
let residual = in_flight

(* A start reservation held before any exact attempt is bound. *)
let start_reserved ~id ~requested_at =
  entry ~id ~requested_at
    ~summary_status:Q.Summary_pending
    ~exact_attempt:Q.Exact_unbound
    ~disposition:
      (Q.Summary_attempt_pre_worker_unavailable
         { Q.reason_code = Q.Summary_pre_worker_start_reserved
         ; operator_detail = "start reserved"
         })

let finalizable ~id ~requested_at =
  let binding =
    Q.make_exact_attempt_binding ~approval_id:id ~input_hash:"h" ~sequence:1
      ~slot_id:"slot" ~call_id:"call" ~plan_fingerprint:"p"
      ~request_body_sha256:"s" ()
  in
  let binding =
    Q.exact_attempt_binding_with_status binding Q.Exact_completed
  in
  entry ~id ~requested_at
    ~summary_status:(Q.Summary_failed { reason = "provider dropped" })
    ~exact_attempt:(Q.Exact_bound binding)
    ~disposition:Q.Summary_attempt_in_flight

let aggregate ?(is_live = fun _ -> false) ?(unread_entries = 0)
    ?(late_uncertain = 0) ~now waits entries =
  H.aggregate ~now ~is_live ~waits ~entries ~unread_entries
    ~answered_total:0 ~timed_out_total:0 ~late_uncertain

let test_empty_queue_is_ok () =
  let section = aggregate ~now:100.0 [] [] in
  check string "an empty gate is ok" "ok" (assoc_string "status" section);
  check bool "an empty gate asks nothing of the operator" false
    (assoc_bool "operator_action_required" section);
  check int "no open approvals" 0 (assoc_int "approvals_open" section);
  check bool "oldest is null" true (field "oldest" section = `Null);
  check bool "the durable counts are complete" true
    (assoc_bool "counts_complete" section)

let test_held_call_is_visible_without_raising_the_grade () =
  let waits = [ wait ~tool_call_id:"call-1" ~asked_at:90.0 ] in
  let section = aggregate ~now:100.0 waits [] in
  check string "a held call is normal operation, not a degraded subsystem"
    "ok" (assoc_string "status" section);
  check bool "and demands no operator" false
    (assoc_bool "operator_action_required" section);
  check int "the wait is counted" 1 (assoc_int "approvals_open" section);
  (match field "oldest" section with
   | `Assoc oldest ->
     check string "the oldest row is the held call" "held_call"
       (match List.assoc "kind" oldest with
        | `String s -> s
        | other -> failwith (Printf.sprintf "kind is not a string: %s" (Yojson.Safe.to_string other)));
     check string "it names the tool call" "call-1"
       (match List.assoc "tool_call_id" oldest with
        | `String s -> s
        | other -> failwith (Printf.sprintf "tool_call_id is not a string: %s" (Yojson.Safe.to_string other)));
     check (float 0.0001) "its age is measured" 10.0
       (match List.assoc "age_sec" oldest with
        | `Float f -> f
        | _ -> failwith "age_sec is not a float")
   | _ -> failwith "oldest is not an object")

let test_not_requested_counts_without_raising_the_grade () =
  let entries = [ not_requested ~id:"a1" ~requested_at:80.0 ] in
  let section = aggregate ~now:100.0 [] entries in
  check string "a queued ask waiting for its summary is ok" "ok"
    (assoc_string "status" section);
  check bool "it still demands no operator" false
    (assoc_bool "operator_action_required" section);
  check int "the count names it" 1
    (assoc_int "summary_not_requested" section)

let test_residual_is_the_attention_row () =
  let entries = [ residual ~id:"a2" ~requested_at:70.0 ] in
  let section = aggregate ~now:100.0 [] entries in
  check string "a restart-behind residual row is the attention grade"
    "warning" (assoc_string "status" section);
  check bool "it demands an operator" true
    (assoc_bool "operator_action_required" section);
  check (list string) "the reason names the residual count"
    [ "exact_bound_residual=1" ]
    (match field "operator_action_reasons" section with
     | `List reasons ->
       List.map (function `String s -> s | _ -> failwith "not a string") reasons
     | _ -> failwith "reasons is not a list");
  check int "the residual count is carried" 1
    (assoc_int "exact_bound_residual" section)

let test_finalizable_is_not_an_attention_row () =
  let entries = [ finalizable ~id:"a3" ~requested_at:60.0 ] in
  let section = aggregate ~now:100.0 [] entries in
  check string "a provably finalizable row is working as designed" "ok"
    (assoc_string "status" section);
  check bool "it demands no operator" false
    (assoc_bool "operator_action_required" section);
  check int "and is counted as its own kind" 1
    (assoc_int "summary_finalizable" section)

let reasons section =
  match field "operator_action_reasons" section with
  | `List reasons ->
    List.map (function `String s -> s | _ -> failwith "not a string") reasons
  | _ -> failwith "reasons is not a list"

let test_live_judgment_is_not_an_attention_row () =
  let row = in_flight ~id:"live" ~requested_at:70.0 in
  let section =
    aggregate ~is_live:(fun (e : Q.pending_approval) -> e.Q.id = "live")
      ~now:100.0 [] [ row ]
  in
  check string "a judgment this process is running is working as designed"
    "ok" (assoc_string "status" section);
  check bool "and demands no operator" false
    (assoc_bool "operator_action_required" section);
  check int "it is the finalizer's own work" 1
    (assoc_int "summary_finalizable" section);
  check int "not a residual" 0 (assoc_int "exact_bound_residual" section)

let test_stranded_judgment_is_the_attention_row () =
  let row = in_flight ~id:"gone" ~requested_at:70.0 in
  let section = aggregate ~now:100.0 [] [ row ] in
  check string "the same row without a live admission is stranded" "warning"
    (assoc_string "status" section);
  check int "and counted as a residual" 1
    (assoc_int "exact_bound_residual" section)

let test_start_reservation_is_pending_start () =
  let section =
    aggregate ~now:100.0 [] [ start_reserved ~id:"r" ~requested_at:70.0 ]
  in
  check string "a start reservation is the finalizer's claim" "ok"
    (assoc_string "status" section);
  check int "counted as pending start" 1
    (assoc_int "summary_pending_start" section);
  check int "never a residual" 0 (assoc_int "exact_bound_residual" section)

let test_late_uncertain_is_an_attention_reason () =
  let section = aggregate ~late_uncertain:2 ~now:100.0 [] [] in
  check string "an unknown late-answer outcome raises the grade" "warning"
    (assoc_string "status" section);
  check bool "and demands an operator" true
    (assoc_bool "operator_action_required" section);
  check (list string) "naming the count" [ "late_uncertain=2" ]
    (reasons section)

let test_unread_rows_make_the_counts_a_lower_bound () =
  let section = aggregate ~unread_entries:1 ~now:100.0 [] [] in
  check bool "the counts are not complete" false
    (assoc_bool "counts_complete" section);
  check string "so the section is not ok" "warning"
    (assoc_string "status" section);
  check (list string) "naming the unreadable rows"
    [ "pending_rows_unreadable=1" ] (reasons section)

let test_late_journal_unavailable_demands_an_operator () =
  let section = H.late_journal_unavailable_json ~error:"corrupt row 3" in
  check string "a fenced journal is unavailable" "unavailable"
    (assoc_string "status" section);
  check bool "the rollup reads the operator requirement" true
    (assoc_bool "operator_action_required" section);
  check (list string) "with the reason" [ "late_approval_journal_unavailable" ]
    (reasons section)

let test_oldest_spans_both_sources () =
  let waits = [ wait ~tool_call_id:"call-1" ~asked_at:90.0 ] in
  let entries = [ not_requested ~id:"a1" ~requested_at:80.0 ] in
  let section = aggregate ~now:100.0 waits entries in
  (match field "oldest" section with
   | `Assoc oldest ->
     check string "the durable ask is older than the live wait" "queued_ask"
       (match List.assoc "kind" oldest with
        | `String s -> s
        | other -> failwith (Printf.sprintf "kind is not a string: %s" (Yojson.Safe.to_string other)))
   | _ -> failwith "oldest is not an object")

let test_no_workspace_keeps_the_live_side () =
  let waits = [ wait ~tool_call_id:"call-1" ~asked_at:90.0 ] in
  let section =
    H.no_workspace_json ~now:100.0 ~waits ~answered_total:3 ~timed_out_total:1
      ~late_uncertain:0 ()
  in
  check string "no workspace state is not an error" "snapshot_not_ready"
    (assoc_string "status" section);
  check int "the live waits are still real" 1
    (assoc_int "approvals_open" section);
  check bool "the durable side says it was not read" false
    (assoc_bool "counts_complete" section);
  check bool "and no operator is demanded" false
    (assoc_bool "operator_action_required" section)

let test_queue_unreadable_never_reads_as_empty () =
  let section = H.queue_unreadable_json ~error:"permission denied" in
  check string "an unread queue is unavailable" "unavailable"
    (assoc_string "status" section);
  check bool "it demands an operator" true
    (assoc_bool "operator_action_required" section);
  check (list string) "the reason names the unread authority"
    [ "approval_queue_unreadable" ]
    (match field "operator_action_reasons" section with
     | `List reasons ->
       List.map (function `String s -> s | _ -> failwith "not a string") reasons
     | _ -> failwith "reasons is not a list")

let () =
  run
    "keeper_hitl_gate_health"
    [ ( "visibility"
      , [ test_case "an empty queue is ok" `Quick test_empty_queue_is_ok
        ; test_case
            "a held call is visible without raising the grade" `Quick
            test_held_call_is_visible_without_raising_the_grade
        ; test_case
            "a summary never requested counts without raising the grade"
            `Quick test_not_requested_counts_without_raising_the_grade
        ; test_case "the oldest row spans both sources" `Quick
            test_oldest_spans_both_sources
        ] )
    ; ( "attention"
      , [ test_case "a residual row is the attention row" `Quick
            test_residual_is_the_attention_row
        ; test_case "a finalizable row is not an attention row" `Quick
            test_finalizable_is_not_an_attention_row
        ; test_case "a live judgment is not an attention row" `Quick
            test_live_judgment_is_not_an_attention_row
        ; test_case "a stranded judgment is the attention row" `Quick
            test_stranded_judgment_is_the_attention_row
        ; test_case "a start reservation is pending start" `Quick
            test_start_reservation_is_pending_start
        ; test_case "late uncertain is an attention reason" `Quick
            test_late_uncertain_is_an_attention_reason
        ] )
    ; ( "degradation"
      , [ test_case "no workspace keeps the live side" `Quick
            test_no_workspace_keeps_the_live_side
        ; test_case "an unread queue never reads as empty" `Quick
            test_queue_unreadable_never_reads_as_empty
        ; test_case "unread rows make the counts a lower bound" `Quick
            test_unread_rows_make_the_counts_a_lower_bound
        ; test_case "a fenced journal demands an operator" `Quick
            test_late_journal_unavailable_demands_an_operator
        ] )
    ]
