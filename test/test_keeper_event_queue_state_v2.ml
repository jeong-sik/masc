module Queue = Keeper_event_queue
module State = Keeper_event_queue_state
module Persistence = Keeper_event_queue_persistence
module Keeper_reaction_ledger = Masc.Keeper_reaction_ledger
module Registry_event_queue = Masc.Keeper_registry_event_queue

(* Prompts moved from code into config/prompts; load them so keeper world event
   rows render a non-empty title and preview. Matches the other
   prompt-rendering tests. *)
let () =
  let prompt_dir =
    Filename.concat
      (match Sys.getenv_opt "DUNE_SOURCEROOT" with
       | Some root -> root
       | None -> Sys.getcwd ())
      "config/prompts"
  in
  Prompt_registry.set_markdown_dir prompt_dir;
  Prompt_registry.load_prompts_from_directory prompt_dir

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

let select ?(now = Unix.gettimeofday ()) state =
  State.select_when ~now ~ready:(fun _ -> true) state
  |> require_some "pending selection"
;;

let test_peek_keeps_pending_authoritative () =
  let state =
    State.empty
    |> State.with_revision 7L
    |> State.with_pending (queue [ stimulus "first" 1.0; stimulus "second" 2.0 ])
  in
  let selected = select state in
  Alcotest.(check string)
    "selected exact head"
    "first"
    selected.source.post_id;
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
  let selected = select state in
  let acked = State.ack_pending ~selection:selected state |> require_ok "exact ack" in
  Alcotest.(check (list string))
    "distinct source remains"
    [ "approval-b" ]
    (post_ids (State.pending acked))
;;

(* #31597: Low never competes with a fresh Normal entry before it has aged
   past the threshold — this is the pre-existing strict-priority behaviour,
   kept as a regression baseline so the aging tests below can't pass by
   accident (e.g. a bug that always promotes Low regardless of age). *)
let test_low_below_aging_threshold_still_loses_to_fresh_normal () =
  let low = { (stimulus "low-item" 0.0) with urgency = Queue.Low } in
  let normal = stimulus "normal-item" 1000.0 in
  let state = State.with_pending (queue [ low; normal ]) State.empty in
  let selected =
    State.select_when ~now:1000.0 ~ready:(fun _ -> true) state
    |> require_some "pending selection"
  in
  Alcotest.(check string)
    "unaged Low (age 1000s < 3600s threshold) still loses to Normal"
    "normal-item"
    selected.source.post_id
;;

(* Once a Low entry has waited at least the aging threshold, it competes with
   Normal entries on arrival order instead of losing unconditionally. *)
let test_low_aged_past_threshold_competes_with_normal_by_arrival () =
  let low = { (stimulus "low-item" 0.0) with urgency = Queue.Low } in
  let normal = stimulus "normal-item" 1000.0 in
  let state = State.with_pending (queue [ low; normal ]) State.empty in
  let selected =
    State.select_when ~now:3700.0 ~ready:(fun _ -> true) state
    |> require_some "pending selection"
  in
  Alcotest.(check string)
    "aged Low (age 3700s >= 3600s threshold) wins on earlier arrival"
    "low-item"
    selected.source.post_id
;;

(* Aging promotes Low to Normal only — it never reaches Immediate, no matter
   how long it has waited. Immediate stays a producer-declared contract
   (keeper_composition_completion_wake.ml). *)
let test_low_aging_never_reaches_immediate () =
  let low = { (stimulus "low-item" 0.0) with urgency = Queue.Low } in
  let immediate =
    { (stimulus "immediate-item" 5000.0) with urgency = Queue.Immediate }
  in
  let state = State.with_pending (queue [ low; immediate ]) State.empty in
  let selected =
    State.select_when ~now:100_000.0 ~ready:(fun _ -> true) state
    |> require_some "pending selection"
  in
  Alcotest.(check string)
    "an arbitrarily old Low still loses to Immediate"
    "immediate-item"
    selected.source.post_id
;;

(* Two Low entries aged past the threshold keep their relative arrival order
   once promoted, the same fairness guarantee same-urgency entries already
   had (see [with_pending]'s "stable order" invariant). *)
let test_multiple_aged_low_entries_keep_arrival_order () =
  let low_a = { (stimulus "low-a" 0.0) with urgency = Queue.Low } in
  let low_b = { (stimulus "low-b" 100.0) with urgency = Queue.Low } in
  let state = State.with_pending (queue [ low_a; low_b ]) State.empty in
  let first =
    State.select_when ~now:4000.0 ~ready:(fun _ -> true) state
    |> require_some "first pending selection"
  in
  Alcotest.(check string) "earlier-arrived aged Low is picked first" "low-a" first.source.post_id;
  let acked =
    State.ack_pending ~selection:first state |> require_ok "ack first aged Low"
  in
  let second =
    State.select_when ~now:4000.0 ~ready:(fun _ -> true) acked
    |> require_some "second pending selection"
  in
  Alcotest.(check string) "later-arrived aged Low is picked next" "low-b" second.source.post_id
;;

let test_pending_collapses_duplicate_source_identity () =
  let source = stimulus "duplicate-source" 1.0 in
  let duplicate = { source with arrived_at = 2.0 } in
  let state = State.with_pending (queue [ source; duplicate ]) State.empty in
  Alcotest.(check (list string))
    "first durable source owns the duplicate identity"
    [ "duplicate-source" ]
    (post_ids (State.pending state))
;;

let test_failure_without_ack_retains_source () =
  let state = State.with_pending (queue [ stimulus "retry-me" 1.0 ]) State.empty in
  ignore (select state);
  Alcotest.(check (list string))
    "failure or crash performs no queue mutation"
    [ "retry-me" ]
    (post_ids (State.pending state))
;;

let test_unrelated_enqueue_does_not_invalidate_exact_ack () =
  let source = stimulus "source" 1.0 in
  let state = State.with_pending (queue [ source ]) State.empty in
  let selected = select state in
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

let test_reinserted_source_invalidates_old_selection () =
  let source = stimulus "source-aba" 1.0 in
  let initial = State.with_pending (queue [ source ]) State.empty in
  let old_selection = select initial in
  let reinserted =
    initial
    |> State.with_pending Queue.empty
    |> State.with_revision 1L
    |> State.with_pending (queue [ source ])
    |> State.with_revision 2L
  in
  let source_ref = State.source_snapshot_ref source in
  (match
     State.resolve_pending_selection
       ~source_ref
       ~source_incarnation:old_selection.admitted_revision
       reinserted
   with
   | Error _ -> ()
   | Ok _ ->
     Alcotest.fail "source ref bypassed the reinserted source incarnation");
  (match State.ack_pending ~selection:old_selection reinserted with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "old selection consumed a reinserted source");
  let current_selection = select reinserted in
  ignore
    (State.resolve_pending_selection
       ~source_ref
       ~source_incarnation:current_selection.admitted_revision
       reinserted
     |> require_ok "current source ref and incarnation");
  let acked =
    State.ack_pending ~selection:current_selection reinserted
    |> require_ok "current source incarnation ACK"
  in
  Alcotest.(check (list string))
    "current source incarnation is removable"
    []
    (post_ids (State.pending acked))
;;

let test_changed_selected_snapshot_fails_closed () =
  let source = stimulus "source" 1.0 in
  let state = State.with_pending (queue [ source ]) State.empty in
  let selected = select state in
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

let test_turn_attempt_terminal_receipt_preserves_exact_source () =
  let source = stimulus "failed-turn-source" 1.0 in
  let initial = State.with_pending (queue [ source ]) State.empty in
  let selection = select initial in
  let staged, receipt =
    match
      State.terminalize_pending_turn_attempt
        ~applied_at:2.0
        ~selection
        ~detail:""
        initial
      |> require_ok "terminalize failed turn source"
    with
    | state, State.Transition_applied receipt -> state, receipt
    | _, State.Transition_already_applied _ ->
      Alcotest.fail "first turn-attempt terminalization was replayed"
  in
  Alcotest.(check (list string))
    "terminal source leaves runnable pending"
    []
    (post_ids (State.pending staged));
  (match State.transition_outbox staged with
   | [ { receipt = actual; stimuli = [ retained ] } ] ->
     Alcotest.(check string)
       "receipt identity is stable"
       receipt.transition_id
       actual.transition_id;
     Alcotest.(check bool)
       "exact source survives in the durable receipt"
       true
       (retained = source)
   | _ -> Alcotest.fail "turn-attempt terminal receipt did not retain one source");
  let projected =
    State.mark_transition_projected
      ~transition_id:receipt.transition_id
      staged
    |> require_ok "project turn-attempt terminal receipt"
  in
  let later_source = stimulus "later-terminal-source" 2.5 in
  let with_later =
    projected
    |> State.with_revision (Int64.succ (State.revision projected))
    |> State.with_pending (queue [ later_source ])
  in
  let later_selection = select with_later in
  let later_staged, later_receipt =
    match
      State.terminalize_pending_turn_completed
        ~applied_at:2.75
        ~selection:later_selection
        with_later
      |> require_ok "terminalize later source"
    with
    | state, State.Transition_applied receipt -> state, receipt
    | _, State.Transition_already_applied _ ->
      Alcotest.fail "later terminal source was replayed"
  in
  let projected =
    State.mark_transition_projected
      ~transition_id:later_receipt.transition_id
      later_staged
    |> require_ok "displace turn-attempt receipt into compact history"
  in
  (match
     State.projected_dispositions projected
     |> List.find_opt (function
       | State.Projected_witness witness ->
         String.equal witness.post_id source.post_id
       | State.Current_receipt _ -> false)
   with
   | Some (State.Projected_witness _) -> ()
   | Some (State.Current_receipt _) | None ->
     Alcotest.fail "turn-attempt terminal did not become a compact witness");
  (match
     State.terminalize_pending_turn_attempt
       ~applied_at:3.0
       ~selection
       ~detail:"different diagnostic"
       projected
     |> require_ok "replay projected turn-attempt terminal receipt"
   with
   | replayed, State.Transition_already_applied actual ->
     Alcotest.(check string)
       "projected replay keeps operation identity"
       receipt.transition_id
       actual.transition_id;
     Alcotest.(check int64)
       "projected replay does not revise queue"
       (State.revision projected)
       (State.revision replayed)
   | _, State.Transition_applied _ ->
     Alcotest.fail "projected turn-attempt terminal receipt applied twice");
  let requeued =
    projected
    |> State.with_revision (Int64.succ (State.revision projected))
    |> State.with_pending (queue [ source ])
  in
  let next_selection = select requeued in
  (match
     State.terminalize_pending_turn_attempt
       ~applied_at:4.0
       ~selection:next_selection
       ~detail:"later attempt"
       requeued
     |> require_ok "terminalize re-enqueued identical source"
   with
   | next, State.Transition_applied next_receipt ->
     Alcotest.(check bool)
       "later selection receives a distinct operation"
       false
       (String.equal receipt.transition_id next_receipt.transition_id);
     Alcotest.(check (list string))
       "later identical source is removed"
       []
       (post_ids (State.pending next))
   | _, State.Transition_already_applied _ ->
     Alcotest.fail "later identical source was mistaken for the prior attempt");
  State.to_yojson projected
  |> State.of_yojson
  |> require_ok "turn-attempt terminal receipt round trip"
  |> ignore
;;

let test_turn_completed_receipt_is_terminal_and_conflict_fenced () =
  let source = stimulus "completed-turn-source" 1.0 in
  let initial = State.with_pending (queue [ source ]) State.empty in
  let selection = select initial in
  let staged, receipt =
    match
      State.terminalize_pending_turn_completed
        ~applied_at:2.0
        ~selection
        initial
      |> require_ok "terminalize completed turn source"
    with
    | state, State.Transition_applied receipt -> state, receipt
    | _, State.Transition_already_applied _ ->
      Alcotest.fail "first completed-turn terminalization was replayed"
  in
  Alcotest.(check (list string))
    "completed source leaves runnable pending"
    []
    (post_ids (State.pending staged));
  (match receipt.transition with
   | State.Ack_source_terminal { source_receipt = State.Turn_completed; _ } -> ()
   | State.Cancel_accepted _
   | State.Transfer_accepted _
   | State.Ack_source_terminal _ ->
     Alcotest.fail "completed turn did not commit Turn_completed evidence");
  let projected =
    State.mark_transition_projected ~transition_id:receipt.transition_id staged
    |> require_ok "project completed turn receipt"
  in
  (match
     State.terminalize_pending_turn_completed
       ~applied_at:3.0
       ~selection
       projected
     |> require_ok "replay completed turn receipt"
   with
   | _, State.Transition_already_applied replayed ->
     Alcotest.(check string)
       "completion replay keeps transition identity"
       receipt.transition_id
       replayed.transition_id
   | _, State.Transition_applied _ ->
     Alcotest.fail "completed turn was applied twice");
  (match
     State.terminalize_pending_turn_attempt
       ~applied_at:4.0
       ~selection
       ~detail:"late contradictory failure"
       projected
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "failure replaced an already-completed turn")
;;

let test_projected_disposition_ledger_replays_older_operation () =
  let large_payload_marker = "PROJECTED-PAYLOAD-MUST-NOT-SURVIVE-" in
  let cancelled_source : Queue.stimulus =
    { post_id = "cancelled-source"
    ; urgency = Queue.Normal
    ; arrived_at = 1.0
    ; payload =
        Queue.Schedule_due
          { occurrence_id = "cancelled-source"
          ; schedule_instance_id = "large-schedule-instance"
          ; schedule_id = "large-schedule"
          ; due_at = 1.0
          ; payload_digest = "large-schedule-digest"
          ; title = Some "large projected payload"
          ; message =
              String.concat "" (List.init 8_192 (fun _ -> large_payload_marker))
          ; result_delivery = None
          }
    }
  in
  let transferred_source = stimulus "transferred-source" 2.0 in
  let initial =
    State.empty
    |> State.with_pending (queue [ cancelled_source; transferred_source ])
  in
  let cancellation : State.accepted_cancellation =
    { source = cancelled_source
    ; source_incarnation =
        (State.select_when
           ~now:(Unix.gettimeofday ())
           ~ready:(Queue.stimulus_identity_equal cancelled_source)
           initial
         |> require_some "select cancellation source")
          .admitted_revision
    ; operator_operation_id = "cancel-operation"
    ; reason = "operator cancelled"
    }
  in
  let staged_cancel, cancel_receipt =
    match
      State.cancel_pending_accepted
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
    ; source_incarnation =
        (State.select_when
           ~now:(Unix.gettimeofday ())
           ~ready:(Queue.stimulus_identity_equal transferred_source)
           projected_cancel
         |> require_some "select transfer source")
          .admitted_revision
    ; operator_operation_id = "transfer-operation"
    ; from_keeper = "source-keeper"
    ; to_keeper = "target-keeper"
    ; target_trace_id = Keeper_id.For_testing.unsafe_trace_id_of_string "target-trace"
    }
  in
  let staged_transfer, transfer_receipt =
    match
      State.transfer_pending_accepted
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
  let projected_json =
    State.to_yojson projected_transfer |> Yojson.Safe.to_string
  in
  Alcotest.(check bool)
    "older projected payload bytes are absent from the compact witness"
    false
    (Astring.String.is_infix ~affix:large_payload_marker projected_json);
  Alcotest.(check bool)
    "compact history size is independent of the projected payload bytes"
    true
    (String.length projected_json < 32_768);
  let malformed_witness_json =
    match Yojson.Safe.from_string projected_json with
    | `Assoc state_fields ->
      let projected =
        match List.assoc "projected_dispositions" state_fields with
        | `List [ `Assoc storage_fields ] ->
          let malformed =
            match List.assoc "witness" storage_fields with
            | `Assoc witness_fields ->
              `Assoc
                (("transition_ref", `String "not-a-sha256")
                 :: List.remove_assoc "transition_ref" witness_fields)
            | _ -> Alcotest.fail "compact witness must be an object"
          in
          `List
            [ `Assoc
                (("witness", malformed)
                 :: List.remove_assoc "witness" storage_fields)
            ]
        | _ -> Alcotest.fail "expected one compact projected witness"
      in
      `Assoc
        (("projected_dispositions", projected)
         :: List.remove_assoc "projected_dispositions" state_fields)
    | _ -> Alcotest.fail "event queue state must be an object"
  in
  (match State.of_yojson malformed_witness_json with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "malformed compact witness was accepted");
  let reloaded =
    Yojson.Safe.from_string projected_json
    |> State.of_yojson
    |> require_ok "reload projected disposition ledger"
  in
  (match
     State.prior_disposition_by_operation_id
       cancellation.operator_operation_id
       reloaded
   with
   | Some (State.Current_receipt receipt) ->
     Alcotest.(check string)
       "older operation is directly recoverable by durable operation identity"
       cancel_receipt.transition_id
       receipt.transition_id
   | Some (State.Projected_witness witness) ->
     Alcotest.(check string)
       "older compact witness is directly recoverable by durable operation identity"
       cancel_receipt.transition_id
       witness.transition_id
   | None ->
     Alcotest.fail "older operation disappeared from durable disposition lookup");
  (match
     State.cancel_pending_accepted
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
     Alcotest.fail "older cancellation was applied twice");
  let conflicting = { cancellation with reason = "changed replay reason" } in
  (match
     State.cancel_pending_accepted
       ~applied_at:6.0
       ~cancellation:conflicting
       reloaded
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "compact witness accepted a changed transition payload")
;;

let test_current_schema_round_trip () =
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
  let duplicated_pending =
    match json with
    | `Assoc fields ->
      `Assoc
        (List.map
           (function
             | "pending", `List [ entry ] ->
               "pending", `List [ entry; entry ]
             | field -> field)
           fields)
    | _ -> Alcotest.fail "state codec did not emit an object"
  in
  (match State.of_yojson duplicated_pending with
   | Error _ -> ()
   | Ok _ ->
     Alcotest.fail "duplicate pending source identity was accepted")
;;

let with_temp_dir prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote path)))
    (fun () -> f path)
;;

let with_state_change_observer observer f =
  Persistence.install_state_change_observer observer;
  Fun.protect
    ~finally:(fun () -> Persistence.install_state_change_observer ignore)
    f
;;

let test_snapshot_commit_observer_exactly_once_and_failure_isolated () =
  with_temp_dir "keeper-event-queue-observer-snapshot" (fun base_path ->
    let keeper_name = "snapshot-observer-keeper" in
    let source = stimulus "observer-source" 1.0 in
    let notifications = ref 0 in
    with_state_change_observer
      (fun () -> incr notifications)
      (fun () ->
         (match
            Persistence.enqueue_stimulus_if_absent_result
              ~base_path
              ~keeper_name
              source
          with
          | Ok Persistence.Enqueued -> ()
          | Ok Persistence.Already_present ->
            Alcotest.fail "first source enqueue was reported as already present"
          | Error detail -> Alcotest.fail detail);
         Alcotest.(check int) "snapshot commit notifies once" 1 !notifications;
         (match
            Persistence.enqueue_stimulus_if_absent_result
              ~base_path
              ~keeper_name
              source
          with
          | Ok Persistence.Already_present -> ()
          | Ok Persistence.Enqueued ->
            Alcotest.fail "duplicate source enqueue committed again"
          | Error detail -> Alcotest.fail detail);
         Alcotest.(check int) "no-op enqueue does not notify" 1 !notifications);
    let second = stimulus "observer-failure-source" 2.0 in
    with_state_change_observer
      (fun () -> failwith "synthetic observer failure")
      (fun () ->
         (match
            Persistence.enqueue_stimulus_if_absent_result
              ~base_path
              ~keeper_name
              second
          with
          | Ok Persistence.Enqueued -> ()
          | Ok Persistence.Already_present ->
            Alcotest.fail "observer failure source already existed"
          | Error detail ->
            Alcotest.failf "observer failure relabelled committed enqueue: %s" detail);
         let pending =
           Persistence.load_pending_result ~base_path ~keeper_name
           |> require_ok "load committed source after observer failure"
         in
         Alcotest.(check (list string))
           "observer failure preserves committed snapshot"
           [ "observer-source"; "observer-failure-source" ]
           (post_ids pending)))
;;

let test_transition_wal_commit_observer_exactly_once () =
  with_temp_dir "keeper-event-queue-observer-wal" (fun base_path ->
    let keeper_name = "wal-observer-keeper" in
    let source = stimulus "wal-observer-source" 1.0 in
    Persistence.install_state_change_observer ignore;
    Persistence.enqueue_stimulus_if_absent_result
      ~base_path
      ~keeper_name
      source
    |> require_ok "seed WAL observer source"
    |> ignore;
    let selection =
      Persistence.select_when_result
        ~base_path
        ~keeper_name
        ~now:(Unix.gettimeofday ())
        ~ready:(fun _ -> true)
      |> require_ok "select WAL observer source"
      |> require_some "WAL observer selection"
    in
    let notifications = ref 0 in
    with_state_change_observer
      (fun () -> incr notifications)
      (fun () ->
         let first =
           Persistence.terminalize_pending_turn_completed_result
             ~base_path
             ~keeper_name
             ~applied_at:2.0
             ~selection
             ()
           |> require_ok "commit observed transition WAL"
         in
         (match first with
          | Persistence.Transition_applied _ -> ()
          | Persistence.Transition_already_applied _
          | Persistence.Transition_committed_followup_failed _ ->
            Alcotest.fail "first terminal transition did not apply cleanly");
         Alcotest.(check int) "WAL commit notifies once" 1 !notifications;
         let replay =
           Persistence.terminalize_pending_turn_completed_result
             ~base_path
             ~keeper_name
             ~applied_at:3.0
             ~selection
             ()
           |> require_ok "replay observed transition WAL"
         in
         (match replay with
          | Persistence.Transition_already_applied _ -> ()
          | Persistence.Transition_applied _
          | Persistence.Transition_committed_followup_failed _ ->
            Alcotest.fail "transition WAL replay committed again");
         Alcotest.(check int) "WAL replay does not notify" 1 !notifications))
;;

let test_durable_peek_ack_restart () =
  with_temp_dir "keeper-pending-v12" (fun base_path ->
    let keeper_name = "fresh-keeper" in
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      let pending = Queue.enqueue pending (stimulus "one" 1.0) in
      Queue.enqueue pending (stimulus "two" 2.0))
    |> require_ok "seed durable pending";
    let selected =
      Persistence.select_when_result
        ~base_path
        ~keeper_name
        ~now:(Unix.gettimeofday ())
        ~ready:(fun _ -> true)
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

(* Observed 2026-08-22: two Immediate completion_authority_rejected
   stimuli sat at queue_index 41 and 48 behind forty Normal entries because
   enqueue only appended. Urgency is a property of the pending list. *)
let test_immediate_arrival_precedes_pending_normal_entries () =
  with_temp_dir "keeper-pending-urgency-arrival" (fun base_path ->
    let keeper_name = "urgency-keeper" in
    let immediate =
      { (stimulus "urgent" 3.0) with urgency = Queue.Immediate }
    in
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      let pending = Queue.enqueue pending (stimulus "first" 1.0) in
      let pending = Queue.enqueue pending (stimulus "second" 2.0) in
      Queue.enqueue pending immediate)
    |> require_ok "seed pending with a late Immediate arrival";
    let restarted =
      Persistence.load_pending_result ~base_path ~keeper_name
      |> require_ok "restart load"
    in
    Alcotest.(check (list string))
      "Immediate arrival is selected first; Normal entries keep arrival order"
      [ "urgent"; "first"; "second" ]
      (post_ids restarted);
    let selected =
      Persistence.select_when_result
        ~base_path
        ~keeper_name
        ~now:(Unix.gettimeofday ())
        ~ready:(fun _ -> true)
      |> require_ok "select head"
      |> require_some "head selection"
    in
    Alcotest.(check string)
      "head is the Immediate entry"
      "urgent"
      selected.source.Queue.post_id)
;;

let test_durable_reprioritize_is_source_incarnation_fenced () =
  with_temp_dir "keeper-event-reprioritize" (fun base_path ->
    let keeper_name = "priority-keeper" in
    let first = stimulus "shared-post" 1.0 in
    let second =
      { (stimulus "shared-post" 2.0) with urgency = Queue.Low }
    in
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      let pending = Queue.enqueue pending first in
      Queue.enqueue pending second)
    |> require_ok "seed durable priority queue";
    let state =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "load priority state"
    in
    let selection =
      State.select_when
        ~now:(Unix.gettimeofday ())
        ~ready:(Queue.stimulus_identity_equal second)
        state
      |> require_some "select exact priority source"
    in
    let source_ref = State.source_snapshot_ref selection.source in
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      Queue.enqueue pending (stimulus "unrelated" 3.0))
    |> require_ok "enqueue unrelated source";
    let state_after_unrelated =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "load state after unrelated enqueue"
    in
    let resolved =
      State.resolve_pending_selection
        ~source_ref
        ~source_incarnation:selection.admitted_revision
        state_after_unrelated
      |> require_ok "resolve selection after unrelated enqueue"
    in
    Alcotest.(check bool)
      "opaque source ref resolves the exact same-post source"
      true
      (resolved = selection);
    let revision_before_priority = State.revision state_after_unrelated in
    let applied_revision =
      Persistence.reprioritize_pending_result
        ~base_path
        ~keeper_name
        ~selection
        ~urgency:Queue.Immediate
        ()
      |> require_ok "reprioritize exact source"
    in
    Alcotest.(check int64)
      "priority change advances revision once"
      (Int64.succ revision_before_priority)
      applied_revision;
    let restarted_state =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "restart priority load"
    in
    Alcotest.(check (list string))
      "same post id remains independently addressable"
      [ "shared-post"; "shared-post"; "unrelated" ]
      (post_ids (State.pending restarted_state));
    Alcotest.(check (list (float 0.0)))
      "priority change preserves the distinct same-post source"
      [ 2.0; 1.0; 3.0 ]
      (State.pending restarted_state
       |> Queue.to_list
       |> List.map (fun (item : Queue.stimulus) -> item.arrived_at));
    match
      Persistence.reprioritize_pending_result
        ~base_path
        ~keeper_name
        ~selection
        ~urgency:Queue.Low
        ()
    with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "stale priority source incarnation was accepted")
;;

let test_durable_turn_attempt_terminal_restart () =
  with_temp_dir "keeper-turn-attempt-terminal" (fun base_path ->
    let keeper_name = "failed-turn-keeper" in
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      let pending = Queue.enqueue pending (stimulus "failed" 1.0) in
      Queue.enqueue pending (stimulus "unrelated" 2.0))
    |> require_ok "seed failed turn pending";
    let selection =
      Persistence.select_when_result
        ~base_path
        ~keeper_name
        ~now:(Unix.gettimeofday ())
        ~ready:(fun _ -> true)
      |> require_ok "peek failed turn source"
      |> require_some "failed turn selection"
    in
    Persistence.terminalize_pending_turn_attempt_result
      ~base_path
      ~keeper_name
      ~applied_at:3.0
      ~selection
      ~detail:""
      ()
    |> require_ok "commit failed turn terminal receipt"
    |> ignore;
    let restarted =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "restart failed turn state"
    in
    Alcotest.(check (list string))
      "only unrelated source remains runnable"
      [ "unrelated" ]
      (post_ids (State.pending restarted));
    (match State.transition_outbox restarted with
     | [ { stimuli = [ retained ]; _ } ] ->
       Alcotest.(check bool)
         "restart retains exact failed source in WAL"
         true
         (retained = selection.source)
     | _ ->
       Alcotest.fail
         "restart did not retain exactly one source-bearing failed turn receipt");
    Persistence.project_transition_outbox_result
      ~append_before_retire:(fun _ -> Ok ())
      ~base_path
      ~keeper_name
    |> require_ok "project failed turn terminal receipt";
    (match
       Persistence.terminalize_pending_turn_attempt_result
         ~base_path
         ~keeper_name
         ~applied_at:4.0
         ~selection
         ~detail:"replayed after projection"
         ()
       |> require_ok "replay projected failed turn after restart"
     with
     | Persistence.Transition_already_applied _ -> ()
     | Persistence.Transition_applied _
     | Persistence.Transition_committed_followup_failed _ ->
       Alcotest.fail "projected failed turn replay committed twice");
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      Queue.enqueue pending selection.source)
    |> require_ok "re-enqueue identical source";
    (match
       Persistence.ack_pending_result
         ~base_path
         ~keeper_name
         ~selection
         ()
     with
     | Error _ -> ()
     | Ok () ->
       Alcotest.fail "old successful-turn selection ACKed a later incarnation");
    (match
       Persistence.terminalize_pending_turn_attempt_result
         ~base_path
         ~keeper_name
         ~applied_at:4.5
         ~selection
         ~detail:"stale in-flight attempt"
         ()
     with
     | Ok (Persistence.Transition_already_applied _) -> ()
     | Ok
         ( Persistence.Transition_applied _
         | Persistence.Transition_committed_followup_failed _ )
     | Error _ ->
       Alcotest.fail "projected replay did not return its original receipt");
    let later_selection =
      Persistence.select_when_result
        ~base_path
        ~keeper_name
        ~now:(Unix.gettimeofday ())
        ~ready:(Queue.stimulus_identity_equal selection.source)
      |> require_ok "select re-enqueued identical source"
      |> require_some "later identical selection"
    in
    (match
       Persistence.terminalize_pending_turn_attempt_result
         ~base_path
         ~keeper_name
         ~applied_at:5.0
         ~selection:later_selection
         ~detail:"later attempt"
         ()
       |> require_ok "terminalize later identical source"
     with
     | Persistence.Transition_applied _ -> ()
     | Persistence.Transition_already_applied _
     | Persistence.Transition_committed_followup_failed _ ->
       Alcotest.fail "later identical source did not commit a new terminal receipt");
    let final_pending =
      Persistence.load_pending_result ~base_path ~keeper_name
      |> require_ok "reload after later identical source"
    in
    Alcotest.(check (list string))
      "later identical source is removed"
      [ "unrelated" ]
      (post_ids final_pending))
;;

let test_durable_inflight_selection_rejects_reinserted_source () =
  with_temp_dir "keeper-pending-incarnation" (fun base_path ->
    let keeper_name = "inflight-keeper" in
    let source = stimulus "same-source" 1.0 in
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      Queue.enqueue pending source)
    |> require_ok "seed in-flight source";
    let stale_selection =
      Persistence.select_when_result
        ~base_path
        ~keeper_name
        ~now:(Unix.gettimeofday ())
        ~ready:(fun _ -> true)
      |> require_ok "select first source incarnation"
      |> require_some "first source selection"
    in
    Persistence.ack_pending_result
      ~base_path
      ~keeper_name
      ~selection:stale_selection
      ()
    |> require_ok "remove first source incarnation";
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      Queue.enqueue pending source)
    |> require_ok "reinsert exact source";
    (match
       Persistence.ack_pending_result
         ~base_path
         ~keeper_name
         ~selection:stale_selection
         ()
     with
     | Error _ -> ()
     | Ok () -> Alcotest.fail "stale selection ACKed reinserted source");
    (match
       Persistence.terminalize_pending_turn_attempt_result
         ~base_path
         ~keeper_name
         ~applied_at:3.0
         ~selection:stale_selection
         ~detail:"old in-flight turn"
         ()
     with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "stale turn terminalized reinserted source");
    let pending =
      Persistence.load_pending_result ~base_path ~keeper_name
      |> require_ok "reload reinserted source"
    in
    Alcotest.(check (list string))
      "reinserted source remains pending"
      [ "same-source" ]
      (post_ids pending))
;;

let test_durable_completed_turn_projects_reaction_ack () =
  with_temp_dir "keeper-completed-turn-terminal" (fun base_path ->
    let keeper_name = "completed-turn-keeper" in
    let source = stimulus "completed" 1.0 in
    Keeper_reaction_ledger.record_event_queue_stimulus
      ~base_path
      ~keeper_name
      source;
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      Queue.enqueue pending source)
    |> require_ok "seed completed turn pending";
    let selection =
      Persistence.select_when_result
        ~base_path
        ~keeper_name
        ~now:(Unix.gettimeofday ())
        ~ready:(fun _ -> true)
      |> require_ok "select completed turn source"
      |> require_some "completed turn selection"
    in
    let receipt =
      match
        Persistence.terminalize_pending_turn_completed_result
          ~base_path
          ~keeper_name
          ~applied_at:3.0
          ~selection
          ()
        |> require_ok "commit completed turn receipt"
      with
      | Persistence.Transition_applied receipt
      | Persistence.Transition_already_applied receipt ->
        receipt
      | Persistence.Transition_committed_followup_failed { detail; _ } ->
        Alcotest.fail detail
    in
    Keeper_reaction_ledger.project_event_queue_transition_outbox_result
      ~base_path
      ~keeper_name
      ~expected_transition_id:receipt.transition_id
    |> require_ok "project completed turn reaction";
    let restarted =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "restart completed turn state"
    in
    Alcotest.(check int)
      "completed source stays removed after restart"
      0
      (Queue.length (State.pending restarted));
    Alcotest.(check int)
      "completed reaction retires outbox"
      0
      (List.length (State.transition_outbox restarted));
    let stimulus_id = Keeper_reaction_ledger.stimulus_id_of_event_queue source in
    match
      Keeper_reaction_ledger.event_queue_reaction_evidence_result
        ~base_path
        ~keeper_name
        ~stimulus_id
    with
    | Ok (Keeper_reaction_ledger.Evidence_complete evidence) ->
      Alcotest.(check bool)
        "completed turn has durable ACK evidence"
        true
        evidence.event_queue_ack_seen
    | Ok (Keeper_reaction_ledger.Evidence_quarantined _) ->
      Alcotest.fail "completed turn evidence was quarantined"
    | Error error ->
      Alcotest.fail
        (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string error))
;;

let test_owner_terminalizes_consecutive_turns_without_projection_gap () =
  with_temp_dir "keeper-owner-consecutive-terminal" (fun base_path ->
    let keeper_name = "consecutive-turn-keeper" in
    let first = stimulus "first" 1.0 in
    let second = stimulus "second" 2.0 in
    List.iter
      (Keeper_reaction_ledger.record_event_queue_stimulus
         ~base_path
         ~keeper_name)
      [ first; second ];
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      Queue.enqueue (Queue.enqueue pending first) second)
    |> require_ok "seed consecutive turn sources";
    let terminalize applied_at =
      let selection =
        Persistence.select_when_result
          ~base_path
          ~keeper_name
          ~now:(Unix.gettimeofday ())
          ~ready:(fun _ -> true)
        |> require_ok "select consecutive turn source"
        |> require_some "consecutive turn selection"
      in
      match
        Registry_event_queue.terminalize_pending_turn_completed_result
          ~base_path
          keeper_name
          ~applied_at
          ~selection
      with
      | Ok (Registry_event_queue.Acked _)
      | Ok (Registry_event_queue.Already_acked _) -> ()
      | Ok
          (Registry_event_queue.Ack_committed_followup_failed
             { detail; _ }) ->
        Alcotest.fail detail
      | Error detail -> Alcotest.fail detail
    in
    terminalize 3.0;
    terminalize 4.0;
    let settled =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "reload consecutive turn state"
    in
    Alcotest.(check int)
      "both successful turns leave no pending source"
      0
      (Queue.length (State.pending settled));
    Alcotest.(check int)
      "owner projects each terminal receipt before the next turn"
      0
      (List.length (State.transition_outbox settled)))
;;

let () =
  Alcotest.run
    "keeper pending queue current schema"
    [ ( "state"
      , [ Alcotest.test_case "peek keeps pending authoritative" `Quick test_peek_keeps_pending_authoritative
        ; Alcotest.test_case "exact ack preserves distinct source" `Quick test_exact_ack_removes_only_selected_identity
        ; Alcotest.test_case
            "unaged Low still loses to fresh Normal"
            `Quick
            test_low_below_aging_threshold_still_loses_to_fresh_normal
        ; Alcotest.test_case
            "aged Low competes with Normal by arrival"
            `Quick
            test_low_aged_past_threshold_competes_with_normal_by_arrival
        ; Alcotest.test_case
            "Low aging never reaches Immediate"
            `Quick
            test_low_aging_never_reaches_immediate
        ; Alcotest.test_case
            "multiple aged Low entries keep arrival order"
            `Quick
            test_multiple_aged_low_entries_keep_arrival_order
        ; Alcotest.test_case
            "pending collapses duplicate source identity"
            `Quick
            test_pending_collapses_duplicate_source_identity
        ; Alcotest.test_case "failure retains source" `Quick test_failure_without_ack_retains_source
        ; Alcotest.test_case
            "unrelated enqueue survives exact ack"
            `Quick
            test_unrelated_enqueue_does_not_invalidate_exact_ack
        ; Alcotest.test_case
            "reinserted source rejects old selection"
            `Quick
            test_reinserted_source_invalidates_old_selection
        ; Alcotest.test_case
            "changed selected snapshot fails closed"
            `Quick
            test_changed_selected_snapshot_fails_closed
        ; Alcotest.test_case
            "turn-attempt terminal receipt preserves exact source"
            `Quick
            test_turn_attempt_terminal_receipt_preserves_exact_source
        ; Alcotest.test_case
            "turn completion is terminal and conflict fenced"
            `Quick
            test_turn_completed_receipt_is_terminal_and_conflict_fenced
        ; Alcotest.test_case
            "older projected disposition replays"
            `Quick
            test_projected_disposition_ledger_replays_older_operation
        ; Alcotest.test_case
            "current schema only"
            `Quick
            test_current_schema_round_trip
        ] )
    ; ( "persistence"
      , [ Alcotest.test_case "durable peek ack restart" `Quick test_durable_peek_ack_restart
        ; Alcotest.test_case
            "Immediate arrival precedes pending Normal entries"
            `Quick
            test_immediate_arrival_precedes_pending_normal_entries
        ; Alcotest.test_case
            "durable reprioritize is source incarnation fenced"
            `Quick
            test_durable_reprioritize_is_source_incarnation_fenced
        ; Alcotest.test_case
            "durable failed turn receipt restart"
            `Quick
            test_durable_turn_attempt_terminal_restart
        ; Alcotest.test_case
            "durable completed turn projects reaction ACK"
            `Quick
            test_durable_completed_turn_projects_reaction_ack
        ; Alcotest.test_case
            "owner terminalizes consecutive turns without projection gap"
            `Quick
            test_owner_terminalizes_consecutive_turns_without_projection_gap
        ; Alcotest.test_case
            "durable in-flight selection rejects reinserted source"
            `Quick
            test_durable_inflight_selection_rejects_reinserted_source
        ; Alcotest.test_case
            "snapshot commit observer is exact and isolated"
            `Quick
            test_snapshot_commit_observer_exactly_once_and_failure_isolated
        ; Alcotest.test_case
            "transition WAL observer notifies exactly once"
            `Quick
            test_transition_wal_commit_observer_exactly_once
        ] )
      ]
;;
