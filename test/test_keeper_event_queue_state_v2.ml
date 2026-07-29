module Queue = Keeper_event_queue
module State = Keeper_event_queue_state
module Persistence = Keeper_event_queue_persistence

let require_ok label = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s: %s" label detail
;;

let require_some label = function
  | Some value -> value
  | None -> Alcotest.failf "%s: expected Some" label
;;

let stimulus post_id arrived_at : Queue.stimulus =
  { post_id; urgency = Queue.Normal; arrived_at; payload = Queue.Bootstrap }
;;

let queue stimuli = List.fold_left Queue.enqueue Queue.empty stimuli

let post_ids queue =
  Queue.to_list queue |> List.map (fun (item : Queue.stimulus) -> item.post_id)
;;

let selection state =
  State.peek_when ~ready:(fun _ -> true) state |> require_some "pending selection"
;;

let test_peek_keeps_pending_authoritative () =
  let state =
    State.empty
    |> State.with_revision 7L
    |> State.with_pending (queue [ stimulus "first" 1.0; stimulus "second" 2.0 ])
  in
  let selected = selection state in
  Alcotest.(check int64) "observed revision" 7L selected.source_revision;
  Alcotest.(check (list string)) "selected exact head" [ "first" ] (post_ids (queue selected.stimuli));
  Alcotest.(check (list string))
    "peek does not dequeue"
    [ "first"; "second" ]
    (post_ids (State.pending state));
  Alcotest.(check int64) "peek does not revise" 7L (State.revision state)
;;

let test_exact_ack_removes_only_selected_identity () =
  let first = stimulus "approval-a" 1.0 in
  let second = stimulus "approval-b" 2.0 in
  let state = State.with_pending (queue [ first; second ]) State.empty in
  let selected = selection state in
  let acked = State.ack_pending ~selection:selected state |> require_ok "exact ack" in
  Alcotest.(check (list string))
    "distinct source remains"
    [ "approval-b" ]
    (post_ids (State.pending acked))
;;

let test_failure_without_ack_retains_source () =
  let state = State.with_pending (queue [ stimulus "retry-me" 1.0 ]) State.empty in
  ignore (selection state);
  Alcotest.(check (list string))
    "failure or crash performs no queue mutation"
    [ "retry-me" ]
    (post_ids (State.pending state))
;;

let test_unrelated_enqueue_does_not_invalidate_exact_ack () =
  let source = stimulus "source" 1.0 in
  let state = State.with_pending (queue [ source ]) State.empty in
  let selected = selection state in
  let changed =
    state
    |> State.with_revision 1L
    |> State.with_pending (queue [ source; stimulus "new-source" 2.0 ])
  in
  let acked =
    State.ack_pending ~selection:selected changed
    |> require_ok "unrelated enqueue must not invalidate exact source"
  in
  Alcotest.(check (list string))
    "only unrelated source remains"
    [ "new-source" ]
    (post_ids (State.pending acked))
;;

let test_changed_selected_snapshot_fails_closed () =
  let source = stimulus "source" 1.0 in
  let state = State.with_pending (queue [ source ]) State.empty in
  let selected = selection state in
  let changed_source = { source with arrived_at = 9.0 } in
  let changed = State.with_pending (queue [ changed_source ]) state in
  (match State.ack_pending ~selection:selected changed with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "changed selected snapshot was acknowledged");
  Alcotest.(check (list string))
    "changed source retained"
    [ "source" ]
    (post_ids (State.pending changed))
;;

let test_current_schema_round_trip_and_legacy_v10_recovery () =
  let state = State.with_pending (queue [ stimulus "fresh" 1.0 ]) State.empty in
  let json = State.to_yojson state in
  let decoded = State.of_yojson json |> require_ok "current schema round trip" in
  (match json with
   | `Assoc fields ->
     Alcotest.(check (list string))
       "pending-only durable fields"
       [ "accepted_transfer_projections"
       ; "last_settlement"
       ; "pending"
       ; "revision"
       ; "schema"
       ; "transition_outbox"
       ]
       (List.map fst fields |> List.sort String.compare)
   | _ -> Alcotest.fail "state codec did not emit an object");
  Alcotest.(check (list string))
    "fresh pending survives"
    [ "fresh" ]
    (post_ids (State.pending decoded));
  let legacy_v10 =
    match json with
    | `Assoc fields ->
      `Assoc
        ( ("schema", `String "keeper.event_queue.state.v10")
        :: (fields
            |> List.remove_assoc "schema"
            |> List.remove_assoc "accepted_transfer_projections") )
    | _ -> Alcotest.fail "state codec did not emit an object"
  in
  let recovered_v10 =
    State.of_yojson legacy_v10 |> require_ok "legacy v10 snapshot recovers"
  in
  Alcotest.(check (list string))
    "legacy v10 pending survives"
    [ "fresh" ]
    (post_ids (State.pending recovered_v10));
  (match State.to_yojson recovered_v10 with
   | `Assoc fields ->
     Alcotest.(check (option string))
       "legacy v10 recovery checkpoints as current schema"
       (Some State.schema)
       (match List.assoc_opt "schema" fields with
        | Some (`String schema) -> Some schema
        | Some _ | None -> None)
   | _ -> Alcotest.fail "recovered state codec did not emit an object");
  let transfer : State.accepted_transfer =
    { source = stimulus "transferred-v11" 2.0
    ; source_revision = 0L
    ; owner_nonce = 0
    ; operator_operation_id = "transfer-v11"
    ; from_keeper = "from-v11"
    ; to_keeper = "to-v11"
    }
  in
  let transfer_state, _ =
    State.project_accepted_transfer transfer State.empty
    |> require_ok "seed accepted transfer projection"
  in
  let legacy_v11 =
    match State.to_yojson transfer_state with
    | `Assoc fields ->
      let last_transition =
        List.assoc_opt "last_transition" fields
        |> require_some "current state carries last transition field"
      in
      `Assoc
        ( ("schema", `String "keeper.event_queue.state.v11")
        :: ("last_settlement", last_transition)
        :: (fields
            |> List.remove_assoc "schema"
            |> List.remove_assoc "last_transition") )
    | _ -> Alcotest.fail "transfer state codec did not emit an object"
  in
  let recovered_v11 =
    State.of_yojson legacy_v11 |> require_ok "legacy v11 snapshot recovers"
  in
  Alcotest.(check int)
    "legacy v11 preserves accepted transfer projection"
    1
    (List.length (State.accepted_transfer_projections recovered_v11));
  let stale =
    match json with
    | `Assoc fields -> `Assoc (("schema", `String "keeper.event_queue.state.v5") :: List.remove_assoc "schema" fields)
    | _ -> Alcotest.fail "state codec did not emit an object"
  in
  match State.of_yojson stale with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "old lease schema was accepted"
;;

let with_temp_dir prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote path)))
    (fun () -> f path)
;;

let test_durable_peek_ack_restart () =
  with_temp_dir "keeper-pending-v7" (fun base_path ->
    let keeper_name = "fresh-keeper" in
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      let pending = Queue.enqueue pending (stimulus "one" 1.0) in
      Queue.enqueue pending (stimulus "two" 2.0))
    |> require_ok "seed durable pending";
    let selected =
      Persistence.peek_when_result ~base_path ~keeper_name ~ready:(fun _ -> true)
      |> require_ok "durable peek"
      |> require_some "durable selection"
    in
    let before =
      Persistence.load_pending_result ~base_path ~keeper_name
      |> require_ok "load before ack"
    in
    Alcotest.(check (list string)) "peek persisted no mutation" [ "one"; "two" ] (post_ids before);
    Persistence.ack_pending_result ~base_path ~keeper_name ~selection:selected ()
    |> require_ok "durable exact ack";
    let restarted =
      Persistence.load_pending_result ~base_path ~keeper_name
      |> require_ok "restart load"
    in
    Alcotest.(check (list string)) "restart sees only unacked source" [ "two" ] (post_ids restarted))
;;

let () =
  Alcotest.run
    "keeper pending queue v7"
    [ ( "state"
      , [ Alcotest.test_case "peek keeps pending authoritative" `Quick test_peek_keeps_pending_authoritative
        ; Alcotest.test_case "exact ack preserves distinct source" `Quick test_exact_ack_removes_only_selected_identity
        ; Alcotest.test_case "failure retains source" `Quick test_failure_without_ack_retains_source
        ; Alcotest.test_case
            "unrelated enqueue survives exact ack"
            `Quick
            test_unrelated_enqueue_does_not_invalidate_exact_ack
        ; Alcotest.test_case
            "changed selected snapshot fails closed"
            `Quick
            test_changed_selected_snapshot_fails_closed
        ; Alcotest.test_case
            "current schema and legacy v10 recovery"
            `Quick
            test_current_schema_round_trip_and_legacy_v10_recovery
        ] )
    ; ( "persistence"
      , [ Alcotest.test_case "durable peek ack restart" `Quick test_durable_peek_ack_restart ] )
    ]
;;
