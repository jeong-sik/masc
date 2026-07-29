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

let test_projected_disposition_ledger_replays_older_operation () =
  let cancelled_source = stimulus "cancelled-source" 1.0 in
  let transferred_source = stimulus "transferred-source" 2.0 in
  let initial =
    State.empty
    |> State.with_pending (queue [ cancelled_source; transferred_source ])
  in
  let cancellation : State.accepted_cancellation =
    { source = cancelled_source
    ; source_revision = State.revision initial
    ; owner_nonce = 7
    ; operator_operation_id = "cancel-operation"
    ; reason = "operator cancelled"
    }
  in
  let staged_cancel, cancel_receipt =
    match
      State.cancel_pending_accepted
        ~current_owner_nonce:7
        ~applied_at:3.0
        ~cancellation
        initial
      |> require_ok "stage cancellation"
    with
    | state, State.Transition_applied receipt -> state, receipt
    | _, State.Transition_already_applied _ ->
      Alcotest.fail "first cancellation was replayed"
  in
  let projected_cancel =
    State.mark_transition_projected
      ~transition_id:cancel_receipt.transition_id
      staged_cancel
    |> require_ok "project cancellation"
  in
  let transfer : State.accepted_transfer =
    { source = transferred_source
    ; source_revision = State.revision projected_cancel
    ; owner_nonce = 7
    ; operator_operation_id = "transfer-operation"
    ; from_keeper = "source-keeper"
    ; to_keeper = "target-keeper"
    }
  in
  let staged_transfer, transfer_receipt =
    match
      State.transfer_pending_accepted
        ~current_owner_nonce:7
        ~applied_at:4.0
        ~transfer
        projected_cancel
      |> require_ok "stage transfer"
    with
    | state, State.Transition_applied receipt -> state, receipt
    | _, State.Transition_already_applied _ ->
      Alcotest.fail "first transfer was replayed"
  in
  let projected_transfer =
    State.mark_transition_projected
      ~transition_id:transfer_receipt.transition_id
      staged_transfer
    |> require_ok "project transfer"
  in
  Alcotest.(check int)
    "both disposition witnesses survive"
    2
    (List.length (State.projected_dispositions projected_transfer));
  let reloaded =
    State.to_yojson projected_transfer
    |> State.of_yojson
    |> require_ok "reload projected disposition ledger"
  in
  (match
     State.cancel_pending_accepted
       ~current_owner_nonce:7
       ~applied_at:5.0
       ~cancellation
       reloaded
     |> require_ok "replay older cancellation"
   with
   | replayed, State.Transition_already_applied receipt ->
     Alcotest.(check string)
       "older operation keeps its transition identity"
       cancel_receipt.transition_id
       receipt.transition_id;
     Alcotest.(check int64)
       "older operation replay does not revise"
       (State.revision reloaded)
       (State.revision replayed)
   | _, State.Transition_applied _ ->
     Alcotest.fail "older cancellation was applied twice")
;;

let test_current_schema_round_trip_and_retired_schemas_rejected () =
  let state = State.with_pending (queue [ stimulus "fresh" 1.0 ]) State.empty in
  let json = State.to_yojson state in
  let decoded = State.of_yojson json |> require_ok "current schema round trip" in
  (match json with
   | `Assoc fields ->
     Alcotest.(check (list string))
       "pending-only durable fields"
       [ "accepted_transfer_projections"
       ; "last_transition"
       ; "pending"
       ; "projected_dispositions"
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
  List.iter
    (fun retired_schema ->
       let stale =
         match json with
         | `Assoc fields ->
           `Assoc
             ( ("schema", `String retired_schema)
             :: List.remove_assoc "schema" fields )
         | _ -> Alcotest.fail "state codec did not emit an object"
       in
       match State.of_yojson stale with
       | Error _ -> ()
       | Ok _ ->
         Alcotest.failf "retired event queue schema was accepted: %s" retired_schema)
    [ "keeper.event_queue.state.v11"
    ; "keeper.event_queue.state.v10"
    ; "keeper.event_queue.state.v9"
    ; "keeper.event_queue.state.v8"
    ; "keeper.event_queue.state.v7"
    ]
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
  with_temp_dir "keeper-pending-v12" (fun base_path ->
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
    (match
       Persistence.ack_pending_result
         ~base_path
         ~keeper_name
         ~selection:selected
         ()
       |> require_ok "durable exact ack"
     with
     | Persistence.Ack_applied -> ()
     | Persistence.Ack_applied_followup_failed detail ->
       Alcotest.failf "durable exact ACK cleanup failed: %s" detail);
    let restarted =
      Persistence.load_pending_result ~base_path ~keeper_name
      |> require_ok "restart load"
    in
    Alcotest.(check (list string)) "restart sees only unacked source" [ "two" ] (post_ids restarted))
;;

let test_ack_followup_failure_retries_cleanup_without_reapplying_ack () =
  with_temp_dir "keeper-ack-followup" (fun base_path ->
    let keeper_name = "ack-followup-keeper" in
    Fun.protect
      ~finally:(fun () ->
        Persistence.For_testing.force_transition_wal_compaction_failures 0)
    @@ fun () ->
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      Queue.enqueue pending (stimulus "one-shot" 1.0))
    |> require_ok "seed one-shot pending";
    let selected =
      Persistence.peek_when_result
        ~base_path
        ~keeper_name
        ~ready:(fun _ -> true)
      |> require_ok "peek one-shot"
      |> require_some "one-shot selection"
    in
    Persistence.For_testing.force_transition_wal_compaction_failures 1;
    (match
       Persistence.ack_pending_result
         ~base_path
         ~keeper_name
         ~selection:selected
         ()
       |> require_ok "commit ACK with forced cleanup failure"
     with
     | Persistence.Ack_applied ->
       Alcotest.fail "forced post-commit cleanup failure was not surfaced"
     | Persistence.Ack_applied_followup_failed _ -> ());
    Persistence.retry_pending_ack_followup_result
      ~base_path
      ~keeper_name
      ()
    |> require_ok "retry only ACK cleanup";
    let pending =
      Persistence.load_pending_result ~base_path ~keeper_name
      |> require_ok "load after cleanup retry"
    in
    Alcotest.(check (list string))
      "committed source remains removed"
      []
      (post_ids pending);
    (match
       Persistence.ack_pending_result
         ~base_path
         ~keeper_name
         ~selection:selected
         ()
     with
     | Error _ -> ()
     | Ok Persistence.Ack_applied
     | Ok (Persistence.Ack_applied_followup_failed _) ->
       Alcotest.fail "already-committed ACK was applied a second time"))
;;

let test_ack_publication_exception_is_post_commit () =
  with_temp_dir "keeper-ack-publication" (fun base_path ->
    let keeper_name = "ack-publication-keeper" in
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      Queue.enqueue pending (stimulus "one-shot-publication" 1.0))
    |> require_ok "seed publication pending";
    let selected =
      Persistence.peek_when_result
        ~base_path
        ~keeper_name
        ~ready:(fun _ -> true)
      |> require_ok "peek publication source"
      |> require_some "publication selection"
    in
    (match
       Persistence.ack_pending_result
         ~after_commit:(fun _ -> failwith "forced publication failure")
         ~base_path
         ~keeper_name
         ~selection:selected
         ()
       |> require_ok "commit ACK with publication failure"
     with
     | Persistence.Ack_applied ->
       Alcotest.fail "publication exception was not surfaced"
     | Persistence.Ack_applied_followup_failed detail ->
       Alcotest.(check bool)
         "typed detail identifies publication"
         true
         (String.starts_with
            ~prefix:"post-commit pending publication raised:"
            detail));
    Persistence.retry_pending_ack_followup_result
      ~base_path
      ~keeper_name
      ()
    |> require_ok "publish committed pending after callback failure";
    let pending =
      Persistence.load_pending_result ~base_path ~keeper_name
      |> require_ok "load after publication recovery"
    in
    Alcotest.(check (list string))
      "publication failure does not restore source"
      []
      (post_ids pending))
;;

let test_retired_inflight_sidecar_is_not_read () =
  with_temp_dir "keeper-retired-inflight-sidecar" (fun base_path ->
    let keeper_name = "sidecar-ignored" in
    let keeper_dir =
      Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name
    in
    Fs_compat.mkdir_p keeper_dir;
    let sidecar_path = Filename.concat keeper_dir "event-queue-inflight.json" in
    let retired_bytes = "retired wire must remain opaque: not-json\000lease_id" in
    Out_channel.with_open_bin sidecar_path (fun channel ->
      output_string channel retired_bytes);
    let state =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "retired sidecar must not affect current state load"
    in
    Alcotest.(check (list string))
      "retired sidecar creates no pending authority"
      []
      (post_ids (State.pending state));
    let bytes_after =
      In_channel.with_open_bin sidecar_path In_channel.input_all
    in
    Alcotest.(check string)
      "retired sidecar is not consumed or rewritten"
      retired_bytes
      bytes_after)
;;

let test_retired_snapshot_and_wal_paths_are_not_read () =
  with_temp_dir "keeper-retired-event-layer-paths" (fun base_path ->
    let keeper_name = "retired-paths-ignored" in
    let keeper_dir =
      Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name
    in
    Fs_compat.mkdir_p keeper_dir;
    let retired_snapshot_path = Filename.concat keeper_dir "event-queue.json" in
    let retired_wal_path =
      Filename.concat keeper_dir "event-queue-transitions.jsonl"
    in
    let retired_snapshot_bytes =
      "retired snapshot must remain opaque: not-json\000lease_id"
    in
    let retired_wal_bytes =
      "retired WAL must remain opaque: not-json\000settlement_id"
    in
    Out_channel.with_open_bin retired_snapshot_path (fun channel ->
      output_string channel retired_snapshot_bytes);
    Out_channel.with_open_bin retired_wal_path (fun channel ->
      output_string channel retired_wal_bytes);
    let state =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "retired snapshot and WAL paths must not affect current load"
    in
    Alcotest.(check (list string))
      "retired paths create no current pending authority"
      []
      (post_ids (State.pending state));
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      Queue.enqueue pending (stimulus "current-only" 3.0))
    |> require_ok "persist current-only state beside retired paths";
    Alcotest.(check bool)
      "current snapshot uses a disjoint path"
      true
      (Sys.file_exists (Filename.concat keeper_dir "event-queue-v12.json"));
    Alcotest.(check string)
      "retired snapshot is not consumed or rewritten"
      retired_snapshot_bytes
      (In_channel.with_open_bin retired_snapshot_path In_channel.input_all);
    Alcotest.(check string)
      "retired WAL is not consumed or rewritten"
      retired_wal_bytes
      (In_channel.with_open_bin retired_wal_path In_channel.input_all))
;;

let () =
  Alcotest.run
    "keeper pending queue current schema"
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
            "older projected disposition replays"
            `Quick
            test_projected_disposition_ledger_replays_older_operation
        ; Alcotest.test_case
            "current schema only"
            `Quick
            test_current_schema_round_trip_and_retired_schemas_rejected
        ] )
    ; ( "persistence"
      , [ Alcotest.test_case "durable peek ack restart" `Quick test_durable_peek_ack_restart
        ; Alcotest.test_case
            "ACK cleanup retry does not reapply committed ACK"
            `Quick
            test_ack_followup_failure_retries_cleanup_without_reapplying_ack
        ; Alcotest.test_case
            "ACK publication exception remains post-commit"
            `Quick
            test_ack_publication_exception_is_post_commit
        ; Alcotest.test_case
            "retired inflight sidecar is not read"
            `Quick
            test_retired_inflight_sidecar_is_not_read
        ; Alcotest.test_case
            "retired snapshot and WAL paths are not read"
            `Quick
            test_retired_snapshot_and_wal_paths_are_not_read
        ] )
    ]
;;
