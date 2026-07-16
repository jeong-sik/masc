module Operation = Keeper_compaction_operation
module Codec = Keeper_compaction_operation_codec
module Operation_json = Keeper_compaction_operation_json
module Reducer = Keeper_compaction_operation_reducer

let ok = function Ok value -> value | Error _ -> Alcotest.fail "fixture rejected"
let operation_id = ok (Operation.Operation_id.of_string "123e4567-e89b-12d3-a456-426614174000")
let attempt_id = ok (Operation.Attempt_id.of_string "123e4567-e89b-12d3-a456-426614174001")
let keeper_name = ok (Keeper_id.Keeper_name.of_string "keeper-a")
let trace_id = ok (Keeper_id.Trace_id.of_string "trace-a")
let checkpoint bytes turn_count =
  ok
    (Keeper_checkpoint_ref.create
       ~trace_id
       ~generation:2
       ~turn_count
       ~canonical_checkpoint_bytes:bytes)
;;
let source = checkpoint "before" 7
let candidate = checkpoint "after" 7
let advanced = checkpoint "advanced" 8
let evidence : Keeper_compaction_evidence.t =
  { selected_runtime_id = Some "compact-runtime"
  ; before_checkpoint_bytes = 100
  ; after_checkpoint_bytes = 50
  ; before_message_count = 10
  ; after_message_count = 4
  ; summarized_message_count = 6
  ; dropped_message_count = 0
  ; before_tool_use_count = 2
  ; after_tool_use_count = 1
  ; before_tool_result_count = 2
  ; after_tool_result_count = 1
  }
;;
let cause = ok (Operation.Cause.of_string "operator request")
let producer =
  let request_id = ok (Mcp_transport_protocol.request_id_of_yojson (`String "req-1")) in
  ok (Tool_invocation_ref.external_mcp ~request_id ~session_id:"session-1")
  |> Operation.tool_invocation_producer_ref
;;
let overflow_delivery =
  ok (Operation.event_queue_lease_delivery_ref ~sequence:1L)
;;
let overflow_producer =
  Operation.provider_overflow_producer_ref
    ~source_checkpoint:source
    ~source_delivery:overflow_delivery
;;

let request_event () =
  Operation.requested
    ~operation_id
    ~keeper_name
    ~source_checkpoint:source
    ~trigger:Compaction_trigger.Manual
    ~cause
    ~producer:(Some producer)
;;

let attempt_event () = Operation.attempt_started ~operation_id ~attempt_id

let candidate_event () =
  Operation.candidate_prepared
    ~operation_id
    ~attempt_id
    ~source_checkpoint:source
    ~candidate_checkpoint:candidate
    ~evidence
;;

let test_requested_view () =
  let event =
    Operation.requested
      ~operation_id
      ~keeper_name
      ~source_checkpoint:source
      ~trigger:Compaction_trigger.Manual
      ~cause
      ~producer:(Some producer)
  in
  Alcotest.(check bool)
    "operation identity"
    true
    (Operation.Operation_id.equal operation_id (Operation.operation_id event));
  match Operation.view event with
  | Operation.Requested request ->
    Alcotest.(check bool)
      "keeper identity"
      true
      (Keeper_id.Keeper_name.equal keeper_name request.keeper_name);
    Alcotest.(check bool)
      "source identity"
      true
      (Keeper_checkpoint_ref.equal source request.source_checkpoint);
    Alcotest.(check bool)
      "producer identity"
      true
      (Option.exists (Operation.producer_ref_equal producer) request.producer)
  | _ -> Alcotest.fail "requested event changed shape"
;;

let test_provider_delivery_ref_is_typed () =
  (match Operation.event_queue_lease_delivery_ref ~sequence:0L with
   | Error (Operation.Non_positive_event_queue_lease_sequence 0L) -> ()
   | Ok _ | Error _ ->
     Alcotest.fail "non-positive event queue lease identity was accepted");
  let same =
    Operation.provider_overflow_producer_ref
      ~source_checkpoint:source
      ~source_delivery:
        (ok (Operation.event_queue_lease_delivery_ref ~sequence:1L))
  in
  let next =
    Operation.provider_overflow_producer_ref
      ~source_checkpoint:source
      ~source_delivery:
        (ok (Operation.event_queue_lease_delivery_ref ~sequence:2L))
  in
  let request_id =
    ok (Keeper_chat_delivery_identity.Request_id.of_string "delivery-1")
  in
  let chat =
    Operation.provider_overflow_producer_ref
      ~source_checkpoint:source
      ~source_delivery:
        (Operation.keeper_chat_delivery_ref
           (Keeper_chat_delivery_identity.Direct_request request_id))
  in
  let turn =
    Operation.provider_overflow_producer_ref
      ~source_checkpoint:source
      ~source_delivery:
        (Operation.keeper_turn_delivery_ref
           (Ids.Turn_ref.make ~trace_id:"trace-a" ~absolute_turn:7))
  in
  Alcotest.(check bool)
    "same typed lease is stable"
    true
    (Operation.producer_ref_equal overflow_producer same);
  Alcotest.(check bool)
    "lease sequence participates"
    false
    (Operation.producer_ref_equal overflow_producer next);
  Alcotest.(check bool)
    "chat identity kind participates"
    false
    (Operation.producer_ref_equal overflow_producer chat);
  Alcotest.(check bool)
    "turn identity kind participates"
    false
    (Operation.producer_ref_equal overflow_producer turn);
  match overflow_producer with
  | Operation.Provider_overflow
      { source_delivery = Operation.Event_queue_lease 1L; _ } -> ()
  | Operation.Provider_overflow _ | Operation.Tool_invocation _ ->
    Alcotest.fail "typed source delivery was discarded after construction"
;;

let test_candidate_views () =
  let prepared =
    Operation.candidate_prepared
      ~operation_id
      ~attempt_id
      ~source_checkpoint:source
      ~candidate_checkpoint:candidate
      ~evidence
  in
  let reconciled =
    Operation.commit_reconciliation_required
      ~operation_id
      ~attempt_id
      ~source_checkpoint:source
      ~candidate_checkpoint:candidate
      ~evidence
      ~reason:Operation.Transaction_outcome_unknown
  in
  let check_candidate = function
    | Operation.Candidate_prepared value
    | Operation.Commit_reconciliation_required (value, _) ->
      Alcotest.(check bool)
        "candidate identity"
        true
        (Keeper_checkpoint_ref.equal candidate value.candidate_checkpoint)
    | _ -> Alcotest.fail "candidate event changed shape"
  in
  check_candidate (Operation.view prepared);
  check_candidate (Operation.view reconciled)
;;

let test_failure_and_reinjection_views () =
  let failure =
    Operation.attempt_failed
      ~operation_id
      ~attempt_id
      ~failure:
        (Operation.Candidate_not_installed
           { cause; observed_checkpoint = source })
  in
  let turn = Ids.Turn_ref.make ~trace_id:"trace-a" ~absolute_turn:8 in
  let reinjected =
    Operation.reinjected
      ~operation_id
      ~adopted_checkpoint:candidate
      ~adopting_turn:turn
  in
  (match Operation.view failure with
   | Operation.Attempt_failed
       (_, Operation.Candidate_not_installed { observed_checkpoint; _ }) ->
     Alcotest.(check bool)
       "observed canonical source"
       true
       (Keeper_checkpoint_ref.equal source observed_checkpoint)
   | _ -> Alcotest.fail "failure event changed shape");
  match Operation.view reinjected with
  | Operation.Reinjected (checkpoint, adopting_turn) ->
    Alcotest.(check bool)
      "adopted checkpoint"
      true
      (Keeper_checkpoint_ref.equal candidate checkpoint);
    Alcotest.(check string)
      "adopting turn"
      "trace-a#8"
      (Ids.Turn_ref.to_string adopting_turn)
  | _ -> Alcotest.fail "reinjected event changed shape"
;;

let test_reducer_happy_path () =
  let turn = Ids.Turn_ref.make ~trace_id:"trace-a" ~absolute_turn:8 in
  let state =
    ok
      (Reducer.fold
         [ request_event ()
         ; attempt_event ()
         ; candidate_event ()
         ; Operation.compacted
             ~operation_id
             ~attempt_id
             ~source_checkpoint:source
             ~committed_checkpoint:candidate
             ~evidence
         ; Operation.reinjected
             ~operation_id
             ~adopted_checkpoint:candidate
             ~adopting_turn:turn
         ])
  in
  let snapshot = Reducer.snapshot state in
  Alcotest.(check bool) "adopted phase" true (snapshot.phase = Reducer.Adopted);
  Alcotest.(check bool)
    "adopted exact checkpoint"
    true
    (Option.exists
       (Keeper_checkpoint_ref.equal candidate)
       snapshot.adopted_checkpoint)
;;

let test_reducer_confirmed_failure () =
  let pre_commit_state =
    ok (Reducer.fold [ request_event (); attempt_event () ])
  in
  let pre_commit_failure =
    Operation.attempt_failed
      ~operation_id
      ~attempt_id
      ~failure:(Operation.Pre_commit_failure cause)
  in
  let pre_commit_state =
    ok (Reducer.apply (Some pre_commit_state) pre_commit_failure)
  in
  let pre_commit_snapshot = Reducer.snapshot pre_commit_state in
  Alcotest.(check bool)
    "pre-commit failure is terminal"
    true
    (pre_commit_snapshot.phase = Reducer.Failed);
  (match pre_commit_snapshot.failure with
   | Some (Operation.Pre_commit_failure actual_cause) ->
     Alcotest.(check bool)
       "pre-commit cause retained"
       true
       (Operation.Cause.equal cause actual_cause)
   | Some (Operation.Candidate_not_installed _) | None ->
     Alcotest.fail "pre-commit failure evidence was lost");
  let state = ok (Reducer.fold [ request_event (); attempt_event (); candidate_event () ]) in
  let wrong =
    Operation.attempt_failed
      ~operation_id
      ~attempt_id
      ~failure:
        (Operation.Candidate_not_installed
           { cause; observed_checkpoint = candidate })
  in
  (match Reducer.apply (Some state) wrong with
   | Error Reducer.Source_mismatch -> ()
   | Ok _ | Error _ -> Alcotest.fail "third checkpoint was treated as not-installed");
  let confirmed =
    Operation.attempt_failed
      ~operation_id
      ~attempt_id
      ~failure:
        (Operation.Candidate_not_installed
           { cause; observed_checkpoint = source })
  in
  let state = ok (Reducer.apply (Some state) confirmed) in
  let snapshot = Reducer.snapshot state in
  Alcotest.(check bool)
    "confirmed non-install is terminal"
    true
    (Reducer.phase state = Reducer.Failed);
  (match snapshot.failure with
   | Some
       (Operation.Candidate_not_installed
          { cause = actual_cause; observed_checkpoint }) ->
     Alcotest.(check bool)
       "failure cause retained"
       true
       (Operation.Cause.equal cause actual_cause);
     Alcotest.(check bool)
       "observed source retained"
       true
       (Keeper_checkpoint_ref.equal source observed_checkpoint)
   | Some (Operation.Pre_commit_failure _) | None ->
     Alcotest.fail "terminal failure evidence was lost");
  match Reducer.apply (Some state) (attempt_event ()) with
  | Error (Reducer.Invalid_transition (Some Reducer.Failed)) -> ()
  | Ok _ | Error _ -> Alcotest.fail "terminal failure accepted another attempt"
;;

let test_reducer_reconciliation () =
  let state = ok (Reducer.fold [ request_event (); attempt_event (); candidate_event () ]) in
  let event =
    Operation.commit_reconciliation_required
      ~operation_id
      ~attempt_id
      ~source_checkpoint:source
      ~candidate_checkpoint:candidate
      ~evidence
      ~reason:Operation.Commit_durability_unknown
  in
  let state = ok (Reducer.apply (Some state) event) in
  let snapshot = Reducer.snapshot state in
  Alcotest.(check bool)
    "unknown outcome remains reconciliation"
    true
    (snapshot.reconciliation_reason = Some Operation.Commit_durability_unknown)
;;

let test_reducer_source_superseded () =
  let superseded =
    Operation.source_superseded
      ~operation_id
      ~attempt_id
      ~observed_checkpoint:(Some advanced)
  in
  let before_candidate =
    ok (Reducer.fold [ request_event (); attempt_event (); superseded ])
  in
  let before_snapshot = Reducer.snapshot before_candidate in
  Alcotest.(check bool)
    "preparation-free supersession is terminal"
    true
    (before_snapshot.phase = Reducer.Superseded);
  Alcotest.(check bool)
    "observed checkpoint retained"
    true
    (Option.exists
       (Keeper_checkpoint_ref.equal advanced)
       before_snapshot.superseded_by_checkpoint);
  let source_removed =
    Operation.source_superseded
      ~operation_id
      ~attempt_id
      ~observed_checkpoint:None
  in
  let removed =
    ok (Reducer.fold [ request_event (); attempt_event (); source_removed ])
  in
  let removed_snapshot = Reducer.snapshot removed in
  Alcotest.(check bool)
    "missing exact source is terminal"
    true
    (removed_snapshot.phase = Reducer.Superseded
     && Option.is_none removed_snapshot.superseded_by_checkpoint);
  let after_candidate =
    ok
      (Reducer.fold
         [ request_event (); attempt_event (); candidate_event (); superseded ])
  in
  let after_snapshot = Reducer.snapshot after_candidate in
  Alcotest.(check bool)
    "prepared candidate remains observable"
    true
    (Option.exists
       (Keeper_checkpoint_ref.equal candidate)
       after_snapshot.candidate_checkpoint);
  let compacted =
    Operation.compacted
      ~operation_id
      ~attempt_id
      ~source_checkpoint:source
      ~committed_checkpoint:candidate
      ~evidence
  in
  let after_commit =
    ok
      (Reducer.fold
         [ request_event ()
         ; attempt_event ()
         ; candidate_event ()
         ; compacted
         ; superseded
         ])
  in
  let committed_snapshot = Reducer.snapshot after_commit in
  Alcotest.(check bool)
    "superseded operation retains prior commit"
    true
    (Option.exists
       (Keeper_checkpoint_ref.equal candidate)
       committed_snapshot.committed_checkpoint);
  match Reducer.apply (Some after_candidate) (attempt_event ()) with
  | Error (Reducer.Invalid_transition (Some Reducer.Superseded)) -> ()
  | Ok _ | Error _ -> Alcotest.fail "superseded operation restarted"
;;

let test_reducer_rejects_false_supersession () =
  let running = ok (Reducer.fold [ request_event (); attempt_event () ]) in
  let event observed_checkpoint =
    Operation.source_superseded
      ~operation_id
      ~attempt_id
      ~observed_checkpoint:(Some observed_checkpoint)
  in
  (match Reducer.apply (Some running) (event source) with
   | Error Reducer.Supersession_not_observed -> ()
   | Ok _ | Error _ -> Alcotest.fail "source equality was called superseded");
  let prepared = ok (Reducer.apply (Some running) (candidate_event ())) in
  (match Reducer.apply (Some prepared) (event candidate) with
   | Error Reducer.Supersession_candidate_installed -> ()
   | Ok _ | Error _ -> Alcotest.fail "installed candidate was called superseded");
  let committed =
    ok
      (Reducer.apply
         (Some prepared)
         (Operation.compacted
            ~operation_id
            ~attempt_id
            ~source_checkpoint:source
            ~committed_checkpoint:candidate
            ~evidence))
  in
  (match Reducer.apply (Some committed) (event source) with
   | Ok state when Reducer.phase state = Reducer.Superseded -> ()
   | Ok _ | Error _ ->
     Alcotest.fail "post-commit source restoration was not superseded");
  let other_trace = ok (Keeper_id.Trace_id.of_string "trace-b") in
  let other =
    ok
      (Keeper_checkpoint_ref.create
         ~trace_id:other_trace
         ~generation:2
         ~turn_count:8
         ~canonical_checkpoint_bytes:"other")
  in
  match Reducer.apply (Some running) (event other) with
  | Error Reducer.Supersession_trace_mismatch -> ()
  | Ok _ | Error _ -> Alcotest.fail "cross-trace supersession was accepted"
;;

let test_reducer_invalid_transition () =
  match Reducer.fold [ request_event (); candidate_event () ] with
  | Error (Reducer.Invalid_transition (Some Reducer.Request_pending)) -> ()
  | Ok _ | Error _ -> Alcotest.fail "candidate without attempt was accepted"
;;

let test_reducer_rejects_provider_source_mismatch () =
  let mismatched =
    Operation.requested
      ~operation_id
      ~keeper_name
      ~source_checkpoint:advanced
      ~trigger:(Compaction_trigger.Provider_overflow { limit_tokens = None })
      ~cause
      ~producer:(Some overflow_producer)
  in
  match Reducer.apply None mismatched with
  | Error Reducer.Producer_source_mismatch -> ()
  | Ok _ | Error _ ->
    Alcotest.fail "provider producer was detached from its exact source"
;;

let test_reducer_requires_typed_provider_producer () =
  let request ~trigger ~producer =
    Operation.requested
      ~operation_id
      ~keeper_name
      ~source_checkpoint:source
      ~trigger
      ~cause
      ~producer
  in
  (match
     Reducer.apply
       None
       (request
          ~trigger:(Compaction_trigger.Provider_overflow { limit_tokens = None })
          ~producer:None)
   with
   | Error Reducer.Provider_overflow_producer_required -> ()
   | Ok _ | Error _ ->
     Alcotest.fail "provider overflow without exact producer was accepted");
  match
    Reducer.apply
      None
      (request ~trigger:Compaction_trigger.Manual ~producer:(Some overflow_producer))
  with
  | Error Reducer.Producer_trigger_mismatch -> ()
  | Ok _ | Error _ ->
    Alcotest.fail "provider producer was attached to a manual trigger"
;;

let test_canonical_json_projection () =
  let turn = Ids.Turn_ref.make ~trace_id:"trace-a" ~absolute_turn:8 in
  let events =
    [ request_event ()
    ; attempt_event ()
    ; candidate_event ()
    ; Operation.attempt_failed
        ~operation_id
        ~attempt_id
        ~failure:(Operation.Pre_commit_failure cause)
    ; Operation.attempt_failed
        ~operation_id
        ~attempt_id
        ~failure:
          (Operation.Candidate_not_installed
             { cause; observed_checkpoint = source })
    ; Operation.commit_reconciliation_required
        ~operation_id
        ~attempt_id
        ~source_checkpoint:source
        ~candidate_checkpoint:candidate
        ~evidence
        ~reason:Operation.Commit_durability_unknown
    ; Operation.source_superseded
        ~operation_id
        ~attempt_id
        ~observed_checkpoint:(Some advanced)
    ; Operation.compacted
        ~operation_id
        ~attempt_id
        ~source_checkpoint:source
        ~committed_checkpoint:candidate
        ~evidence
    ; Operation.reinjected
        ~operation_id
        ~adopted_checkpoint:candidate
        ~adopting_turn:turn
    ]
  in
  let kinds =
    List.map
      (fun event ->
         Operation_json.to_json event
         |> Yojson.Safe.Util.member "kind"
         |> Yojson.Safe.Util.to_string)
      events
  in
  Alcotest.(check (list string))
    "closed event labels"
    [ "requested"
    ; "attempt_started"
    ; "candidate_prepared"
    ; "attempt_failed"
    ; "attempt_failed"
    ; "commit_reconciliation_required"
    ; "source_superseded"
    ; "compacted"
    ; "reinjected"
    ]
    kinds;
  let requested = Operation_json.to_json (List.hd events) in
  Alcotest.(check string)
    "exact producer request id"
    "req-1"
    (requested
     |> Yojson.Safe.Util.member "payload"
     |> Yojson.Safe.Util.member "producer"
     |> Yojson.Safe.Util.member "invocation"
     |> Yojson.Safe.Util.member "request_id"
     |> Yojson.Safe.Util.to_string)
;;

let test_codec_roundtrip_all_events () =
  let turn = Ids.Turn_ref.make ~trace_id:"trace-a" ~absolute_turn:8 in
  let failed failure =
    Operation.attempt_failed ~operation_id ~attempt_id ~failure
  in
  let reconcile reason =
    Operation.commit_reconciliation_required
      ~operation_id
      ~attempt_id
      ~source_checkpoint:source
      ~candidate_checkpoint:candidate
      ~evidence
      ~reason
  in
  let events =
    [ request_event ()
    ; Operation.requested
        ~operation_id
        ~keeper_name
        ~source_checkpoint:source
        ~trigger:(Compaction_trigger.Provider_overflow { limit_tokens = None })
        ~cause
        ~producer:(Some overflow_producer)
    ; attempt_event ()
    ; candidate_event ()
    ; failed (Operation.Pre_commit_failure cause)
    ; failed
        (Operation.Candidate_not_installed
           { cause; observed_checkpoint = source })
    ; reconcile Operation.Commit_durability_unknown
    ; reconcile Operation.Transaction_outcome_unknown
    ; Operation.source_superseded
        ~operation_id
        ~attempt_id
        ~observed_checkpoint:(Some advanced)
    ; Operation.compacted
        ~operation_id
        ~attempt_id
        ~source_checkpoint:source
        ~committed_checkpoint:candidate
        ~evidence
    ; Operation.reinjected
        ~operation_id
        ~adopted_checkpoint:candidate
        ~adopting_turn:turn
    ]
  in
  List.iter
    (fun event ->
       let json = Codec.to_json event in
       match Codec.of_json json with
       | Ok decoded ->
         Alcotest.(check (testable Yojson.Safe.pp Yojson.Safe.equal))
           "canonical roundtrip"
           json
           (Codec.to_json decoded)
       | Error _ -> Alcotest.fail "canonical event was rejected")
    events
;;

let replace_field name value = function
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (field, current) ->
            if String.equal field name then field, value else field, current)
         fields)
  | json -> json
;;

let expect_field_error message expected json =
  match Codec.of_json json with
  | Error (Codec.Invalid_field actual) when actual = expected -> ()
  | Ok _ | Error _ -> Alcotest.fail message
;;

let test_codec_rejects_nested_unknown_field () =
  let json = Codec.to_json (request_event ()) in
  let payload = Yojson.Safe.Util.member "payload" json in
  let prepend name value = function
    | `Assoc fields -> `Assoc ((name, value) :: fields)
    | current -> current
  in
  let remove name = function
    | `Assoc fields -> `Assoc (List.remove_assoc name fields)
    | current -> current
  in
  let with_unknown name =
    prepend name `Null
  in
  expect_field_error
    "event accepted an unknown top field"
    (Codec.Unknown_field { path = "$"; field = "unexpected_top" })
    (with_unknown "unexpected_top" json);
  expect_field_error
    "event accepted a duplicate top field"
    (Codec.Duplicate_field { path = "$"; field = "kind" })
    (prepend "kind" (`String "requested") json);
  expect_field_error
    "event accepted a missing top field"
    (Codec.Missing_field { path = "$"; field = "payload" })
    (remove "payload" json);
  expect_field_error
    "event accepted a wrong-type top field"
    (Codec.Wrong_type { path = "$"; field = "operation_id"; expected = "string" })
    (replace_field "operation_id" (`Int 1) json);
  let payload_unknown =
    replace_field "payload" (with_unknown "unexpected_payload" payload) json
  in
  expect_field_error
    "event accepted an unknown payload field"
    (Codec.Unknown_field { path = "payload"; field = "unexpected_payload" })
    payload_unknown;
  let trigger =
    `Assoc [ "kind", `String "manual"; "unexpected", `Null ]
  in
  let malformed = replace_field "payload" (replace_field "trigger" trigger payload) json in
  expect_field_error
    "event accepted an unknown trigger field"
    (Codec.Unknown_field { path = "payload.trigger"; field = "unexpected" })
    malformed
;;

let test_codec_rejects_invalid_provider_delivery () =
  let event =
    Operation.requested
      ~operation_id
      ~keeper_name
      ~source_checkpoint:source
      ~trigger:(Compaction_trigger.Provider_overflow { limit_tokens = None })
      ~cause
      ~producer:(Some overflow_producer)
  in
  let json = Codec.to_json event in
  let payload = Yojson.Safe.Util.member "payload" json in
  let producer = Yojson.Safe.Util.member "producer" payload in
  let source_delivery = Yojson.Safe.Util.member "source_delivery" producer in
  let malformed_producer =
    replace_field
      "source_delivery"
      (replace_field "sequence" (`String "0") source_delivery)
      producer
  in
  let malformed =
    replace_field
      "payload"
      (replace_field "producer" malformed_producer payload)
      json
  in
  match Codec.of_json malformed with
  | Error
      (Codec.Invalid_provider_delivery
         (Operation.Non_positive_event_queue_lease_sequence 0L)) -> ()
  | Ok _ | Error _ -> Alcotest.fail "invalid typed provider delivery was accepted"
;;

let () =
  Alcotest.run
    "keeper compaction operation events"
    [ ( "events"
      , [ Alcotest.test_case "requested typed view" `Quick test_requested_view
        ; Alcotest.test_case
            "provider delivery reference is typed"
            `Quick
            test_provider_delivery_ref_is_typed
        ; Alcotest.test_case "candidate typed views" `Quick test_candidate_views
        ; Alcotest.test_case
            "failure and reinjection typed views"
            `Quick
            test_failure_and_reinjection_views
        ; Alcotest.test_case "reducer happy path" `Quick test_reducer_happy_path
        ; Alcotest.test_case
            "reducer confirmed failure"
            `Quick
            test_reducer_confirmed_failure
        ; Alcotest.test_case
            "reducer reconciliation"
            `Quick
            test_reducer_reconciliation
        ; Alcotest.test_case
            "reducer source superseded"
            `Quick
            test_reducer_source_superseded
        ; Alcotest.test_case
            "reducer rejects false supersession"
            `Quick
            test_reducer_rejects_false_supersession
        ; Alcotest.test_case
            "reducer invalid transition"
            `Quick
            test_reducer_invalid_transition
        ; Alcotest.test_case
            "provider producer source invariant"
            `Quick
            test_reducer_rejects_provider_source_mismatch
        ; Alcotest.test_case
            "provider trigger requires typed producer"
            `Quick
            test_reducer_requires_typed_provider_producer
        ; Alcotest.test_case
            "canonical JSON projection"
            `Quick
            test_canonical_json_projection
        ; Alcotest.test_case
            "codec roundtrip all events"
            `Quick
            test_codec_roundtrip_all_events
        ; Alcotest.test_case
            "codec rejects nested unknown field"
            `Quick
            test_codec_rejects_nested_unknown_field
        ; Alcotest.test_case
            "codec rejects invalid provider delivery"
            `Quick
            test_codec_rejects_invalid_provider_delivery
        ] )
    ]
