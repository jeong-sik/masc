module A = Masc.Keeper_board_attention_candidate
module E = Masc.Keeper_board_attention_exact_flow
module Event_queue = Masc.Keeper_event_queue
module Event_queue_persistence = Masc.Keeper_event_queue_persistence
module J = Masc.Keeper_board_attention_judgment
module P = Masc.Keeper_board_attention_partition
module Q = Masc.Keeper_board_attention_quarantine_command
module W = Masc.Keeper_board_attention_worker
module Wake = Masc.Keeper_board_attention_worker_wake

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_base name f =
  let base_path = Filename.temp_dir name "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> f base_path)
;;

let ok label = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s: %s" label detail
;;

let signal post_id : Masc.Board_dispatch.board_signal =
  { kind = Masc.Board_dispatch.Board_post_created
  ; post_id
  ; author = "external-author"
  ; title = "Board update"
  ; content = "Persisted Board evidence"
  ; hearth = Some "hearth-1"
  ; updated_at = Some 42.0
  }
;;

let post_id_exn value =
  match Masc.Board.Post_id.of_string value with
  | Ok value -> value
  | Error _ -> Alcotest.fail ("invalid Board post id fixture: " ^ value)
;;

let agent_id_exn value =
  match Masc.Board.Agent_id.of_string value with
  | Ok value -> value
  | Error _ -> Alcotest.fail ("invalid Board agent id fixture: " ^ value)
;;

let post_of_signal (signal : Masc.Board_dispatch.board_signal) : Masc.Board.post =
  { id = post_id_exn signal.post_id
  ; author = agent_id_exn signal.author
  ; title = signal.title
  ; body = signal.content
  ; content = signal.content
  ; post_kind = Masc.Board.Human_post
  ; meta_json = None
  ; visibility = Masc.Board.Public
  ; created_at = 1.0
  ; updated_at = Option.value signal.updated_at ~default:1.0
  ; expires_at = 3601.0
  ; votes_up = 0
  ; votes_down = 0
  ; reply_count = 0
  ; pinned = false
  ; hearth = signal.hearth
  ; thread_id = None
  ; origin = None
  }
;;

let candidate ?(id = "candidate-worker") ?(recorded_at = 1.0) () : A.candidate =
  let keeper_name = "sangsu" in
  let signal = signal id in
  let candidate_id =
    `Assoc
      [ "keeper_name", `String keeper_name
      ; "signal", A.signal_to_yojson signal
      ]
    |> Yojson.Safe.to_string
    |> Digestif.SHA256.digest_string
    |> Digestif.SHA256.to_hex
  in
  { candidate_id
  ; keeper_name
  ; signal
  ; judgment_request =
      `Assoc
        [ "candidate_id", `String candidate_id
        ; "signal", A.signal_to_yojson signal
        ; "post", Masc.Board.post_to_yojson (post_of_signal signal)
        ; "comments", `List []
        ; ( "keeper_context"
          , `Assoc
              [ "lane_keeper_name", `String keeper_name
              ; "agent_name", `String "sangsu-agent"
              ; "keeper_record_id", `Null
              ; "keeper_runtime_uid", `Null
              ; "persona", `Null
              ; "instructions", `String "continue"
              ; "active_goal_ids", `List []
              ; "current_task_id", `Null
              ; "mention_keeper_ids", `List [ `String keeper_name ]
              ] )
        ]
  ; recorded_at
  ; status = A.Pending { last_delivery_failure = None }
  }
;;

let provenance suffix : E.attempt_provenance =
  { slot_id = "slot-" ^ suffix
  ; call_id = "call-" ^ suffix
  ; plan_fingerprint = "plan-" ^ suffix
  ; request_body_sha256 = "request-" ^ suffix
  }
;;

let judgment (provenance : E.attempt_provenance) decision : A.judgment =
  { verdict = { J.decision; rationale = "typed structured verdict" }
  ; slot_id = provenance.slot_id
  ; call_id = provenance.call_id
  ; plan_fingerprint = provenance.plan_fingerprint
  ; request_body_sha256 = provenance.request_body_sha256
  ; judged_at = 2.0
  }
;;

let same_provenance
      (durable : P.exact_provenance)
      (projected : E.attempt_provenance)
  =
  String.equal durable.slot_id projected.slot_id
  && String.equal durable.call_id projected.call_id
  && String.equal durable.plan_fingerprint projected.plan_fingerprint
  && String.equal durable.request_body_sha256 projected.request_body_sha256
;;

let record ~base_path candidate =
  match A.record ~base_path candidate with
  | A.Recorded candidate -> candidate
  | A.Duplicate _ -> Alcotest.fail "first record was a duplicate"
  | A.Record_error detail -> Alcotest.failf "candidate record failed: %s" detail
;;

let load_one_candidate ~base_path =
  match ok "load candidate" (A.load_candidates ~base_path ~keeper_name:"sangsu") with
  | [ candidate ] -> candidate
  | candidates -> Alcotest.failf "expected one candidate, got %d" (List.length candidates)
;;

let load_one_partition ~base_path =
  match ok "load partition" (P.load ~base_path ~keeper_name:"sangsu") with
  | [ partition ] -> partition
  | partitions -> Alcotest.failf "expected one partition, got %d" (List.length partitions)
;;

let relevant_delivery_count ~base_path ~candidate_id =
  Event_queue_persistence.load ~base_path ~keeper_name:"sangsu"
  |> Event_queue.to_list
  |> List.fold_left
       (fun count (stimulus : Event_queue.stimulus) ->
          match stimulus.payload with
          | Event_queue.Board_attention attention
            when String.equal attention.candidate_id candidate_id -> count + 1
          | Event_queue.Board_attention _
          | Event_queue.Board_signal _
          | Event_queue.Bootstrap
          | Event_queue.Fusion_completed _
          | Event_queue.Bg_completed _
          | Event_queue.Schedule_due _
          | Event_queue.Connector_attention _
          | Event_queue.Hitl_resolved _
          | Event_queue.Failure_judgment _
          | Event_queue.Manual_compaction_requested
          | Event_queue.Goal_assigned _ -> count)
       0
;;

let process_at ~now ~base_path ~prepare ~execute =
  W.For_testing.process_next
    ~now
    ~worker_epoch:(P.Worker_epoch.generate ())
    ~base_path
    ~keeper_name:"sangsu"
    ~prepare
    ~execute
;;

let process ~base_path ~prepare ~execute =
  process_at ~now:(fun () -> 3.0) ~base_path ~prepare ~execute
;;

let test_worker_exact_callback_integration_and_owner_settlement () =
  with_temp_base "board-attention-worker-callback-chain" @@ fun base_path ->
  let persisted = record ~base_path (candidate ()) in
  let first = provenance "first" in
  let second = provenance "second" in
  let callbacks = ref [] in
  let observed_time = ref 3.0 in
  let execute ~before_dispatch ~before_advance _candidate =
    ok "bind first" (before_dispatch first);
    (match (load_one_partition ~base_path).state with
     | P.Running { progress = P.Bound durable; _ }
       when same_provenance durable first -> ()
     | _ -> Alcotest.fail "first callback did not durably bind projected provenance");
    callbacks := !callbacks @ [ "bind-first" ];
    ok "record advance" (before_advance ~failed:first ~next:second);
    (match (load_one_partition ~base_path).state with
     | P.Running { progress = P.Advancing durable; _ }
       when same_provenance durable.failed first
            && same_provenance durable.next second -> ()
     | _ -> Alcotest.fail "advance callback did not persist the projected pair");
    callbacks := !callbacks @ [ "advance" ];
    ok "bind second" (before_dispatch second);
    (match (load_one_partition ~base_path).state with
     | P.Running { progress = P.Bound durable; _ }
       when same_provenance durable second -> ()
     | _ -> Alcotest.fail "second callback did not durably bind projected provenance");
    callbacks := !callbacks @ [ "bind-second" ];
    observed_time := 9.0;
    Ok (judgment second J.Not_relevant)
  in
  (match
     ok
       "worker callback integration"
       (process_at
          ~base_path
          ~now:(fun () -> !observed_time)
          ~prepare:(fun candidate -> Ok candidate)
          ~execute)
   with
   | W.Judgment_completed { candidate_id; _ }
     when String.equal candidate_id persisted.candidate_id -> ()
   | W.Judgment_completed _
   | W.Idle
   | W.Candidate_already_consumed _
   | W.Partition_blocked _ ->
     Alcotest.fail "worker exact callback chain did not complete");
  Alcotest.(check (list string))
    "durable callback order"
    [ "bind-first"; "advance"; "bind-second" ]
    !callbacks;
  (match (load_one_candidate ~base_path).status with
   | A.Pending { last_delivery_failure = None } -> ()
   | A.Pending { last_delivery_failure = Some _ }
   | A.Judged _
   | A.Consumed _
   | A.Quarantine _ ->
     Alcotest.fail "background worker crossed the owner settlement boundary");
  (match load_one_partition ~base_path with
   | { state = P.Completed { item = { judgment = observed; _ }; completed_at }; _ } ->
     Alcotest.(check string) "selected opaque slot" second.slot_id observed.slot_id;
     Alcotest.(check (float 0.0)) "completion observes post-execution time" 9.0 completed_at
   | _ -> Alcotest.fail "callback chain did not persist Completed");
  (match ok "owner settlement" (W.settle_one_completed ~base_path ~keeper_name:"sangsu") with
   | W.Partition_settled { candidate_id; _ }
     when String.equal candidate_id persisted.candidate_id -> ()
   | W.Partition_settled _ -> Alcotest.fail "a different candidate was settled"
   | W.No_completed_partition -> Alcotest.fail "completed judgment was not settled");
  match (load_one_candidate ~base_path).status, (load_one_partition ~base_path).state with
  | A.Consumed { delivery = A.Not_relevant; _ }, P.Settled _ -> ()
  | _ -> Alcotest.fail "owner settlement did not consume and settle the judgment"
;;

let test_setup_error_stops_before_claim_without_hot_retry () =
  with_temp_base "board-attention-worker-setup-error" @@ fun base_path ->
  ignore (record ~base_path (candidate ()) : A.candidate);
  let calls = ref 0 in
  let yields = ref 0 in
  let prepare _candidate =
    incr calls;
    Error E.Network_unavailable
  in
  (match
     W.For_testing.drain_available
       ~yield:(fun () -> incr yields)
       ~now:(fun () -> 3.0)
       ~worker_epoch:(P.Worker_epoch.generate ())
       ~base_path
       ~keeper_name:"sangsu"
       ~prepare
       ~execute:(fun ~before_dispatch:_ ~before_advance:_ _ ->
         Alcotest.fail "setup error reached execution")
   with
   | Error detail ->
     Alcotest.(check string)
       "typed setup failure stops the lifecycle"
       "Board attention exact setup unavailable before claim: network context unavailable"
       detail
   | Ok () -> Alcotest.fail "setup-unavailable drain returned normally");
  Alcotest.(check int) "one setup attempt" 1 !calls;
  Alcotest.(check int) "setup failure did not yield into a retry" 0 !yields;
  (match (load_one_candidate ~base_path).status with
   | A.Pending { last_delivery_failure = None } -> ()
   | A.Pending { last_delivery_failure = Some _ }
   | A.Judged _
   | A.Consumed _
   | A.Quarantine _ ->
     Alcotest.fail "setup failure changed the Pending candidate");
  match (load_one_partition ~base_path).state with
  | P.Ready -> ()
  | _ -> Alcotest.fail "setup failure claimed or terminalized the partition"
;;

let test_execution_error_preserves_bound_progress_without_hot_retry () =
  with_temp_base "board-attention-worker-execution-error" @@ fun base_path ->
  let persisted = record ~base_path (candidate ()) in
  let exact = provenance "terminal" in
  let calls = ref 0 in
  let execute ~before_dispatch ~before_advance:_ _candidate =
    incr calls;
    ok "bind terminal attempt" (before_dispatch exact);
    Error (E.Exact_execution_failed [ exact ])
  in
  (match
     ok
       "execution error"
       (process ~base_path ~prepare:(fun candidate -> Ok candidate) ~execute)
   with
   | W.Partition_blocked
       { candidate_id; reason = P.Exact_execution_quarantined (P.Bound durable) }
     when String.equal candidate_id persisted.candidate_id
          && same_provenance durable exact -> ()
   | _ -> Alcotest.fail "execution error lost its durable bound progress");
  (match
     ok
       "execution error is not retried"
       (process ~base_path ~prepare:(fun candidate -> Ok candidate) ~execute)
   with
   | W.Idle -> ()
   | _ -> Alcotest.fail "terminal exact execution became claimable");
  Alcotest.(check int) "one exact execution" 1 !calls
;;

let test_completion_failure_preserves_bound_provenance () =
  with_temp_base "board-attention-worker-completion-failure" @@ fun base_path ->
  let persisted = record ~base_path (candidate ()) in
  let bound = provenance "completion-bound" in
  let mismatched = provenance "completion-mismatch" in
  let execute ~before_dispatch ~before_advance:_ _candidate =
    ok "bind successful exact execution" (before_dispatch bound);
    Ok (judgment mismatched J.Not_relevant)
  in
  (match
     ok
       "completion failure"
       (process ~base_path ~prepare:(fun candidate -> Ok candidate) ~execute)
   with
   | W.Partition_blocked
       { candidate_id; reason = P.Exact_execution_quarantined (P.Bound durable) }
     when String.equal candidate_id persisted.candidate_id
          && same_provenance durable bound -> ()
   | _ -> Alcotest.fail "completion failure lost its durable Bound provenance");
  (match (load_one_partition ~base_path).state with
   | P.Blocked { reason = P.Exact_execution_quarantined (P.Bound durable); _ }
     when same_provenance durable bound -> ()
   | _ -> Alcotest.fail "completion failure did not persist the Bound quarantine");
  match (load_one_candidate ~base_path).status with
  | A.Quarantine
      { quarantine =
          { failure_category = A.Exact_execution_quarantined
          ; attempt_provenance = Some _
          ; _
          }
      ; phase = A.Quarantined
      } ->
    ()
  | A.Pending _ | A.Judged _ | A.Consumed _ | A.Quarantine _ ->
    Alcotest.fail "failed completion did not quarantine the candidate"
;;

let test_flow_already_started_blocks_unbound_without_hot_retry () =
  with_temp_base "board-attention-worker-flow-replayed" @@ fun base_path ->
  let persisted = record ~base_path (candidate ()) in
  let calls = ref 0 in
  let execute ~before_dispatch:_ ~before_advance:_ _candidate =
    incr calls;
    Error (E.Flow_already_started [ provenance "already-started" ])
  in
  (match
     ok
       "flow already started"
       (process ~base_path ~prepare:(fun candidate -> Ok candidate) ~execute)
   with
   | W.Partition_blocked
       { candidate_id; reason = P.Exact_flow_replayed }
     when String.equal candidate_id persisted.candidate_id -> ()
   | _ -> Alcotest.fail "Unbound affine-flow replay was not durably blocked");
  (match
     ok
       "flow replay is not retried"
       (process ~base_path ~prepare:(fun candidate -> Ok candidate) ~execute)
   with
   | W.Idle -> ()
   | _ -> Alcotest.fail "blocked affine-flow replay became claimable");
  Alcotest.(check int) "one affine-flow replay observation" 1 !calls
;;

let test_domain_error_quarantines_bound_progress_without_hot_retry () =
  with_temp_base "board-attention-worker-domain-invalid" @@ fun base_path ->
  let persisted = record ~base_path (candidate ()) in
  let exact = provenance "domain-invalid" in
  let calls = ref 0 in
  let execute ~before_dispatch ~before_advance:_ _candidate =
    incr calls;
    ok "bind domain-invalid attempt" (before_dispatch exact);
    Error (E.Domain_output_invalid "singleton candidate identity mismatch")
  in
  (match
     ok
       "bound domain error"
       (process ~base_path ~prepare:(fun candidate -> Ok candidate) ~execute)
   with
   | W.Partition_blocked
       { candidate_id
       ; reason = P.Exact_execution_quarantined (P.Bound durable)
       }
     when String.equal candidate_id persisted.candidate_id
          && same_provenance durable exact -> ()
   | _ -> Alcotest.fail "domain error lost its durable exact binding");
  (match
     ok
       "bound domain error is not retried"
       (process ~base_path ~prepare:(fun candidate -> Ok candidate) ~execute)
   with
   | W.Idle -> ()
   | _ -> Alcotest.fail "quarantined domain error became claimable");
  Alcotest.(check int) "one domain-invalid exact execution" 1 !calls
;;

let test_bound_cancellation_is_prompt_and_process_recoverable () =
  Eio_main.run @@ fun _env ->
  with_temp_base "board-attention-worker-bound-cancel" @@ fun base_path ->
  ignore (record ~base_path (candidate ()) : A.candidate);
  let exact = provenance "cancelled-bound" in
  let entered, publish_entered = Eio.Promise.create () in
  let never, _resolve_never = Eio.Promise.create () in
  let returned = Atomic.make false in
  Eio.Fiber.first
    (fun () ->
       ignore
         (process
            ~base_path
            ~prepare:(fun candidate -> Ok candidate)
            ~execute:(fun ~before_dispatch ~before_advance:_ _candidate ->
              ok "bind cancelled attempt" (before_dispatch exact);
              Eio.Promise.resolve publish_entered ();
              Eio.Promise.await never)
          : (W.step, string) result);
       Atomic.set returned true)
    (fun () -> Eio.Promise.await entered);
  Alcotest.(check bool) "cancellation did not return normally" false (Atomic.get returned);
  (match load_one_partition ~base_path with
   | { state = P.Running { progress = P.Bound durable; _ }; _ }
     when same_provenance durable exact -> ()
   | _ -> Alcotest.fail "cancellation performed partition I/O before returning");
  Alcotest.(check int)
    "process-start recovery quarantines one Bound execution"
    1
    (ok
       "recover cancelled Bound"
       (P.recover_for_process_start
          ~now:4.0
          ~base_path
          ~keeper_name:"sangsu"));
  match load_one_partition ~base_path with
  | { state = P.Blocked { reason = P.Exact_execution_quarantined (P.Bound durable); _ }
    ; _
    } when same_provenance durable exact -> ()
  | _ -> Alcotest.fail "process-start recovery lost the cancelled Bound provenance"
;;

let test_advancing_cancellation_is_prompt_and_process_recoverable () =
  Eio_main.run @@ fun _env ->
  with_temp_base "board-attention-worker-advancing-cancel" @@ fun base_path ->
  ignore (record ~base_path (candidate ()) : A.candidate);
  let failed = provenance "cancelled-failed" in
  let next = provenance "cancelled-next" in
  let entered, publish_entered = Eio.Promise.create () in
  let never, _resolve_never = Eio.Promise.create () in
  let returned = Atomic.make false in
  Eio.Fiber.first
    (fun () ->
       ignore
         (process
            ~base_path
            ~prepare:(fun candidate -> Ok candidate)
            ~execute:(fun ~before_dispatch ~before_advance _candidate ->
              ok "bind failed attempt" (before_dispatch failed);
              ok "record pending advancement" (before_advance ~failed ~next);
              Eio.Promise.resolve publish_entered ();
              Eio.Promise.await never)
          : (W.step, string) result);
       Atomic.set returned true)
    (fun () -> Eio.Promise.await entered);
  Alcotest.(check bool) "advancing cancellation did not return" false (Atomic.get returned);
  (match load_one_partition ~base_path with
   | { state = P.Running { progress = P.Advancing durable; _ }; _ }
     when same_provenance durable.failed failed
          && same_provenance durable.next next -> ()
   | _ -> Alcotest.fail "advancing cancellation performed partition I/O");
  Alcotest.(check int)
    "process-start recovery quarantines one Advancing execution"
    1
    (ok
       "recover cancelled Advancing"
       (P.recover_for_process_start
          ~now:4.0
          ~base_path
          ~keeper_name:"sangsu"));
  match load_one_partition ~base_path with
  | { state = P.Blocked
        { reason = P.Exact_execution_quarantined (P.Advancing durable); _ }
    ; _
    } when same_provenance durable.failed failed
           && same_provenance durable.next next -> ()
  | _ -> Alcotest.fail "process-start recovery lost the cancelled Advancing pair"
;;

let test_unbound_cancellation_waits_for_process_start_recovery () =
  Eio_main.run @@ fun _env ->
  with_temp_base "board-attention-worker-unbound-cancel" @@ fun base_path ->
  ignore (record ~base_path (candidate ()) : A.candidate);
  let entered, publish_entered = Eio.Promise.create () in
  let never, _resolve_never = Eio.Promise.create () in
  let returned = Atomic.make false in
  Eio.Fiber.first
    (fun () ->
       ignore
         (process
            ~base_path
            ~prepare:(fun candidate -> Ok candidate)
            ~execute:(fun ~before_dispatch:_ ~before_advance:_ _candidate ->
              Eio.Promise.resolve publish_entered ();
              Eio.Promise.await never)
          : (W.step, string) result);
       Atomic.set returned true)
    (fun () -> Eio.Promise.await entered);
  Alcotest.(check bool) "unbound cancellation did not return" false (Atomic.get returned);
  (match (load_one_partition ~base_path).state with
   | P.Running { progress = P.Unbound; _ } -> ()
   | _ -> Alcotest.fail "Unbound cancellation was released before process-start recovery");
  Alcotest.(check int)
    "process-start recovery resolves one Unbound claim"
    1
    (ok
       "recover Unbound claim"
       (P.recover_for_process_start
          ~now:4.0
          ~base_path
          ~keeper_name:"sangsu"));
  match (load_one_partition ~base_path).state with
  | P.Ready -> ()
  | _ -> Alcotest.fail "process-start recovery did not return Unbound to Ready"
;;

let test_terminal_root_does_not_strand_ready_sibling () =
  with_temp_base "board-attention-worker-terminal-sibling" @@ fun base_path ->
  let first = record ~base_path (candidate ~id:"terminal-first" ~recorded_at:1.0 ()) in
  let sibling = record ~base_path (candidate ~id:"ready-sibling" ~recorded_at:2.0 ()) in
  let sibling_exact = provenance "sibling" in
  let calls = ref [] in
  ok
    "drain terminal then sibling"
    (W.For_testing.drain_available
       ~yield:(fun () -> ())
       ~now:(fun () -> 3.0)
       ~worker_epoch:(P.Worker_epoch.generate ())
       ~base_path
       ~keeper_name:"sangsu"
       ~prepare:(fun candidate -> Ok candidate)
       ~execute:(fun ~before_dispatch ~before_advance:_ observed ->
         calls := !calls @ [ observed.A.candidate_id ];
         if String.equal observed.candidate_id first.candidate_id
         then Error (E.Exact_execution_failed [])
         else (
           ok "bind sibling" (before_dispatch sibling_exact);
           Ok (judgment sibling_exact J.Not_relevant))));
  Alcotest.(check (list string))
    "terminal root and sibling were each visited once"
    [ first.candidate_id; sibling.candidate_id ]
    !calls;
  let partitions = ok "load sibling partitions" (P.load ~base_path ~keeper_name:"sangsu") in
  let state_for candidate_id =
    List.find_opt
      (fun (partition : P.t) -> String.equal partition.candidate_id candidate_id)
      partitions
    |> Option.map (fun (partition : P.t) -> partition.state)
  in
  (match state_for first.candidate_id with
   | Some (P.Blocked { reason = P.Exact_execution_terminal; _ }) -> ()
   | Some _ | None -> Alcotest.fail "first terminal root did not remain Blocked");
  match state_for sibling.candidate_id with
  | Some (P.Completed _) -> ()
  | Some _ | None -> Alcotest.fail "Ready sibling did not complete after terminal root"
;;

let test_completed_startup_replays_owner_wake () =
  with_temp_base "board-attention-worker-completed-replay" @@ fun base_path ->
  ignore (record ~base_path (candidate ()) : A.candidate);
  let exact = provenance "replay" in
  ignore
    (ok
       "complete before replay"
       (process
          ~base_path
          ~prepare:(fun candidate -> Ok candidate)
          ~execute:(fun ~before_dispatch ~before_advance:_ _candidate ->
            ok "bind replay attempt" (before_dispatch exact);
            Ok (judgment exact J.Relevant)))
      : W.step);
  let wake_count = ref 0 in
  let wake_owner ~base_path:_ ~keeper_name:_ =
    incr wake_count;
    Masc.Keeper_registry.Signaled
  in
  (match
     ok
       "replay completed wake"
       (W.For_testing.replay_completed_owner_wake
          ~base_path
          ~keeper_name:"sangsu"
          ~wake_owner)
   with
   | Some Masc.Keeper_registry.Signaled -> ()
   | Some _ | None -> Alcotest.fail "Completed startup replay did not wake its owner");
  Alcotest.(check int) "one replay wake" 1 !wake_count
;;

let test_existing_judgment_skips_exact_flow () =
  with_temp_base "board-attention-worker-existing-judgment" @@ fun base_path ->
  let persisted = record ~base_path (candidate ()) in
  let exact = provenance "existing-judged" in
  ignore
    (ok
       "record prior judgment"
       (A.record_judgment ~base_path persisted (judgment exact J.Relevant))
      : A.candidate);
  (match
     ok
       "complete existing judgment"
       (process
          ~base_path
          ~prepare:(fun _ -> Alcotest.fail "prior judgment invoked exact preparation")
          ~execute:(fun ~before_dispatch:_ ~before_advance:_ _ ->
            Alcotest.fail "prior judgment invoked exact execution"))
   with
   | W.Judgment_completed { candidate_id; _ }
     when String.equal candidate_id persisted.candidate_id -> ()
   | _ -> Alcotest.fail "prior judgment was not completed without exact execution");
  match (load_one_partition ~base_path).state with
  | P.Completed { item = { judgment = observed; _ }; _ }
    when String.equal observed.call_id exact.call_id -> ()
  | _ -> Alcotest.fail "existing judgment was not durably projected to Completed"
;;

let test_existing_consumed_skips_exact_flow_and_settles () =
  with_temp_base "board-attention-worker-existing-consumed" @@ fun base_path ->
  let persisted = record ~base_path (candidate ()) in
  ignore
    (ok
       "create Ready root"
       (P.ensure_roots
          ~base_path
          ~keeper_name:"sangsu"
          [ persisted ])
      : int);
  let exact = provenance "existing-consumed" in
  ignore
    (ok
       "record consumed judgment"
       (A.record_judgment ~base_path persisted (judgment exact J.Not_relevant))
      : A.candidate);
  ignore
    (ok
       "consume before worker"
       (A.apply_judgment_and_deliver
          ~base_path
          ~keeper_name:"sangsu"
          ~candidate_id:persisted.candidate_id
          ~judgment:(judgment exact J.Not_relevant))
      : A.candidate);
  (match
     ok
       "settle existing consumed"
       (process
          ~base_path
          ~prepare:(fun _ -> Alcotest.fail "consumed candidate invoked exact preparation")
          ~execute:(fun ~before_dispatch:_ ~before_advance:_ _ ->
            Alcotest.fail "consumed candidate invoked exact execution"))
   with
   | W.Candidate_already_consumed { candidate_id }
     when String.equal candidate_id persisted.candidate_id -> ()
   | _ -> Alcotest.fail "existing Consumed candidate did not settle without exact execution");
  match (load_one_partition ~base_path).state with
  | P.Settled _ -> ()
  | _ -> Alcotest.fail "existing Consumed partition was not Settled"
;;

let test_consumed_completed_crash_settles_without_duplicate_delivery () =
  with_temp_base "board-attention-worker-consumed-completed-crash" @@ fun base_path ->
  let persisted = record ~base_path (candidate ()) in
  ignore
    (ok
       "create root before consumption"
       (P.ensure_roots
          ~base_path
          ~keeper_name:"sangsu"
          [ persisted ])
      : int);
  let exact = provenance "consumed-completed-crash" in
  let completed_judgment = judgment exact J.Relevant in
  let consumed =
    ok
      "consume Relevant candidate before crash"
      (A.apply_judgment_and_deliver
         ~base_path
         ~keeper_name:"sangsu"
         ~candidate_id:persisted.candidate_id
         ~judgment:completed_judgment)
  in
  (match consumed.status with
   | A.Consumed { delivery = A.Enqueued_to_keeper_lane; _ } -> ()
   | A.Pending _ | A.Judged _ | A.Consumed _ | A.Quarantine _ ->
     Alcotest.fail "Relevant candidate was not durably Consumed");
  Alcotest.(check int)
    "one Relevant delivery before crash"
    1
    (relevant_delivery_count ~base_path ~candidate_id:persisted.candidate_id);
  let worker_epoch = P.Worker_epoch.generate () in
  let claimed =
    match
      ok
        "claim existing Consumed root"
        (P.claim_next
           ~now:3.0
           ~worker_epoch
           ~base_path
           ~keeper_name:"sangsu")
    with
    | Some partition -> partition
    | None -> Alcotest.fail "existing Consumed root was not claimable"
  in
  let item : P.completed_item =
    { candidate_id = persisted.candidate_id; judgment = completed_judgment }
  in
  let completed_transition : P.exact_transition =
    ok
      "persist Completed immediately before crash"
      (P.complete_existing_judgment
         ~now:4.0
         ~worker_epoch
         ~base_path
         ~partition:claimed
         ~item)
  in
  (match completed_transition.write_outcome with
   | P.Fsync_completed -> ()
   | P.Visible_sync_unconfirmed detail ->
     Alcotest.failf "crash fixture completion was not fsync-confirmed: %s" detail);
  (match (load_one_partition ~base_path).state with
   | P.Completed _ -> ()
   | _ -> Alcotest.fail "crash fixture did not retain Completed partition");
  (match ok "settle crash-replayed completion" (W.settle_one_completed ~base_path ~keeper_name:"sangsu") with
   | W.Partition_settled { candidate_id; continuation_wake = None }
     when String.equal candidate_id persisted.candidate_id -> ()
   | W.Partition_settled _ ->
     Alcotest.fail "crash-replayed completion settled with unexpected continuation"
   | W.No_completed_partition ->
     Alcotest.fail "crash-replayed Completed partition was not found");
  Alcotest.(check int)
    "Consumed replay did not duplicate Relevant delivery"
    1
    (relevant_delivery_count ~base_path ~candidate_id:persisted.candidate_id);
  match (load_one_candidate ~base_path).status, (load_one_partition ~base_path).state with
  | A.Consumed { delivery = A.Enqueued_to_keeper_lane; _ }, P.Settled _ -> ()
  | _ -> Alcotest.fail "Consumed crash replay did not end in Settled"
;;

let test_process_recovery_claim_is_released_after_cancellation () =
  with_temp_base "board-attention-worker-recovery-lifecycle" @@ fun base_path ->
  let cancelled =
    try
      W.For_testing.with_process_recovery_claim
        ~base_path
        ~keeper_name:"sangsu"
        (fun claimed ->
           Alcotest.(check bool) "first lifecycle acquired recovery" true claimed;
           raise (Eio.Cancel.Cancelled (Failure "injected lifecycle cancellation")));
      false
    with
    | Eio.Cancel.Cancelled _ -> true
  in
  Alcotest.(check bool) "lifecycle cancellation was reraised" true cancelled;
  let restarted_claim =
    W.For_testing.with_process_recovery_claim
      ~base_path
      ~keeper_name:"sangsu"
      (fun claimed -> claimed)
  in
  Alcotest.(check bool)
    "same-process restart reacquired recovery"
    true
    restarted_claim
;;

let test_unexpected_exception_is_terminal_without_hot_retry () =
  with_temp_base "board-attention-worker-unexpected" @@ fun base_path ->
  let persisted = record ~base_path (candidate ()) in
  let calls = ref 0 in
  let execute ~before_dispatch:_ ~before_advance:_ _candidate =
    incr calls;
    raise (Failure "injected exact worker exception")
  in
  (match
     ok
       "unexpected worker failure"
       (process ~base_path ~prepare:(fun candidate -> Ok candidate) ~execute)
   with
   | W.Partition_blocked
       { candidate_id; reason = P.Unexpected_worker_failure _ }
     when String.equal candidate_id persisted.candidate_id -> ()
   | _ -> Alcotest.fail "unexpected exception was not durably terminalized");
  (match
     ok
       "unexpected failure is not retried"
       (process ~base_path ~prepare:(fun candidate -> Ok candidate) ~execute)
   with
   | W.Idle -> ()
   | _ -> Alcotest.fail "unexpected terminal failure became claimable");
  Alcotest.(check int) "one exceptional execution" 1 !calls
;;

let test_requested_blocked_recovery_and_sequential_cas_converge () =
  with_temp_base "board-attention-worker-manual-requeue" @@ fun base_path ->
  let persisted = record ~base_path (candidate ()) in
  let execute ~before_dispatch:_ ~before_advance:_ _candidate =
    raise (Failure "injected exact worker exception")
  in
  (match
     ok
       "create durable quarantine"
       (process ~base_path ~prepare:(fun candidate -> Ok candidate) ~execute)
   with
   | W.Partition_blocked _ -> ()
   | _ -> Alcotest.fail "fixture did not block the singleton partition");
  let quarantined = load_one_candidate ~base_path in
  let partition = load_one_partition ~base_path in
  let quarantine =
    match quarantined.status with
    | A.Quarantine { quarantine; phase = A.Quarantined } -> quarantine
    | _ -> Alcotest.fail "blocked root did not project a candidate quarantine"
  in
  let requested =
    ok
      "persist requeue-requested crash point"
      (A.request_quarantine_requeue
         ~base_path
         ~candidate:quarantined
         ~partition_id:partition.partition_id
         ~expected_quarantine_id:quarantine.quarantine_id
         ~requested_at:20.0)
  in
  (match requested.status with
   | A.Quarantine { phase = A.Requeue_requested _; _ } -> ()
   | _ -> Alcotest.fail "candidate did not retain requeue-requested");
  let request : Q.request =
    { candidate_id = persisted.candidate_id
    ; expected_quarantine_id = quarantine.quarantine_id
    ; decision = Q.Acknowledge_and_requeue
    }
  in
  let command =
    match
      Q.make
        ~keeper_name:"sangsu"
        ~raw_partition_id:partition.partition_id
        request
    with
    | Ok command -> command
    | Error error ->
      Alcotest.failf "manual command rejected: %s" (Q.input_error_to_string error)
  in
  let run label =
    match Q.execute ~now:21.0 ~base_path command with
    | Ok report -> report
    | Error error ->
      Alcotest.failf "%s: %s" label (Q.execution_error_label error)
  in
  let report = run "resume requeue-requested" in
  let recovered_quarantine_id =
    match report.candidate.status, report.partition.state with
    | A.Quarantine { quarantine; phase = A.Requeued _ }, P.Ready ->
      quarantine.quarantine_id
    | _ -> Alcotest.fail "manual recovery did not reach Requeued/Ready"
  in
  let replay = run "idempotent replay" in
  match replay.candidate.status, replay.partition.state with
  | A.Quarantine
      { quarantine = replayed; phase = A.Requeued _ },
    P.Ready ->
    Alcotest.(check string)
      "two sequential CAS commands converge on one quarantine generation"
      recovered_quarantine_id
      replayed.quarantine_id
  | _ -> Alcotest.fail "manual recovery replay lost its generation marker"
;;

let test_manual_quarantine_requeue_is_unclaimable_until_authorized_and_settles () =
  with_temp_base "board-attention-worker-manual-requeue-interleaving" @@ fun base_path ->
  let persisted = record ~base_path (candidate ~id:"candidate-interleaving" ()) in
  let failed_exact = provenance "manual-requeue-failure" in
  let execute ~before_dispatch ~before_advance:_ _candidate =
    ok "bind failed manual requeue attempt" (before_dispatch failed_exact);
    raise (Failure "injected exact worker exception")
  in
  ignore
    (ok
       "create interleaving quarantine"
       (process ~base_path ~prepare:(fun candidate -> Ok candidate) ~execute)
     : W.step);
  let quarantined = load_one_candidate ~base_path in
  let blocked = load_one_partition ~base_path in
  let quarantine =
    match quarantined.status with
    | A.Quarantine { quarantine; phase = A.Quarantined } -> quarantine
    | _ -> Alcotest.fail "interleaving fixture did not project quarantine"
  in
  let requested =
    ok
      "persist requeue request"
      (A.request_quarantine_requeue
         ~base_path
         ~candidate:quarantined
         ~partition_id:blocked.partition_id
         ~expected_quarantine_id:quarantine.quarantine_id
         ~requested_at:30.0)
  in
  let execute_calls = ref 0 in
  let execute_before_authorization ~before_dispatch:_ ~before_advance:_ _candidate =
    incr execute_calls;
    Alcotest.fail "requeue-requested candidate became claimable"
  in
  (match
     ok
       "process while requeue authorization is incomplete"
       (process
          ~base_path
          ~prepare:(fun candidate -> Ok candidate)
          ~execute:execute_before_authorization)
   with
   | W.Idle -> ()
   | W.Judgment_completed _
   | W.Candidate_already_consumed _
   | W.Partition_blocked _ ->
     Alcotest.fail "blocked partition was exposed before authorization");
  Alcotest.(check int) "no exact dispatch before authorization" 0 !execute_calls;
  (match (load_one_partition ~base_path).state with
   | P.Blocked _ -> ()
   | _ -> Alcotest.fail "partition became Ready before candidate authorization");
  let requeued =
    ok
      "persist candidate requeue authorization"
      (A.finish_quarantine_requeue
         ~base_path
         ~candidate:requested
         ~partition_id:blocked.partition_id
         ~expected_quarantine_id:quarantine.quarantine_id
         ~requeued_at:31.0)
  in
  (match requeued.status, (load_one_partition ~base_path).state with
   | A.Quarantine { phase = A.Requeued _; _ }, P.Blocked _ -> ()
   | _ -> Alcotest.fail "authorization was not durable before the Ready commit");
  let inventory = Q.inventory ~base_path ~keeper_names:[ "sangsu" ] in
  let inventory_item =
    match inventory.items with
    | [ item ] -> item
    | _ -> Alcotest.fail "typed quarantine inventory did not expose one CAS target"
  in
  Alcotest.(check string)
    "inventory keeper CAS"
    "sangsu"
    inventory_item.keeper_name;
  Alcotest.(check string)
    "inventory partition CAS"
    blocked.partition_id
    inventory_item.partition_id;
  Alcotest.(check string)
    "inventory candidate CAS"
    persisted.candidate_id
    inventory_item.candidate_id;
  Alcotest.(check string)
    "inventory quarantine CAS"
    quarantine.quarantine_id
    inventory_item.quarantine_id;
  (match inventory_item.phase, inventory_item.requeued_at with
   | Q.Inventory_requeued, Some 31.0 -> ()
   | _ -> Alcotest.fail "inventory did not expose the durable requeue phase");
  (match inventory_item.attempt_provenance with
   | Some durable when same_provenance durable failed_exact -> ()
   | _ -> Alcotest.fail "inventory lost opaque attempt provenance references");
  let inventory_json_item =
    match
      Q.inventory_to_json inventory
      |> Yojson.Safe.Util.member "items"
      |> Yojson.Safe.Util.to_list
    with
    | [ item ] -> item
    | _ -> Alcotest.fail "snapshot inventory JSON did not expose one CAS target"
  in
  let check_json_string field expected =
    Alcotest.(check string)
      ("snapshot inventory " ^ field)
      expected
      (inventory_json_item
       |> Yojson.Safe.Util.member field
       |> Yojson.Safe.Util.to_string)
  in
  check_json_string "keeper_name" "sangsu";
  check_json_string "partition_id" blocked.partition_id;
  check_json_string "candidate_id" persisted.candidate_id;
  check_json_string "quarantine_id" quarantine.quarantine_id;
  check_json_string "phase" "requeued";
  let request : Q.request =
    { candidate_id = persisted.candidate_id
    ; expected_quarantine_id = quarantine.quarantine_id
    ; decision = Q.Acknowledge_and_requeue
    }
  in
  let command =
    match
      Q.make
        ~keeper_name:"sangsu"
        ~raw_partition_id:blocked.partition_id
        request
    with
    | Ok command -> command
    | Error error ->
      Alcotest.failf "requeued command rejected: %s" (Q.input_error_to_string error)
  in
  let recovered =
    match Q.execute ~now:32.0 ~base_path command with
    | Ok report -> report
    | Error error ->
      Alcotest.failf
        "Requeued+Blocked recovery failed: %s"
        (Q.execution_error_label error)
  in
  (match recovered.candidate.status, recovered.partition.state with
   | A.Quarantine { phase = A.Requeued _; _ }, P.Ready -> ()
   | _ -> Alcotest.fail "Requeued+Blocked recovery did not commit Ready");
  let exact = provenance "manual-requeue-success" in
  let execute ~before_dispatch ~before_advance:_ _candidate =
    ok "bind manual requeue attempt" (before_dispatch exact);
    Ok (judgment exact J.Not_relevant)
  in
  (match
     ok
       "execute authorized manual requeue"
       (process ~base_path ~prepare:(fun candidate -> Ok candidate) ~execute)
   with
   | W.Judgment_completed { candidate_id; _ }
     when String.equal candidate_id persisted.candidate_id -> ()
   | W.Judgment_completed _
   | W.Idle
   | W.Candidate_already_consumed _
   | W.Partition_blocked _ ->
     Alcotest.fail "authorized manual requeue did not complete its exact judgment");
  (match (load_one_candidate ~base_path).status, (load_one_partition ~base_path).state with
   | A.Quarantine { phase = A.Requeued _; _ }, P.Completed _ -> ()
   | _ -> Alcotest.fail "exact completion crossed the owner settlement boundary");
  (match
     ok
       "owner settlement"
       (W.settle_one_completed ~base_path ~keeper_name:"sangsu")
   with
   | W.Partition_settled { candidate_id; _ }
     when String.equal candidate_id persisted.candidate_id -> ()
   | W.Partition_settled _ -> Alcotest.fail "a different candidate was settled"
   | W.No_completed_partition -> Alcotest.fail "completed judgment was not settled");
  (match (load_one_candidate ~base_path).status, (load_one_partition ~base_path).state with
   | A.Consumed { delivery = A.Not_relevant; _ }, P.Settled _ -> ()
   | _ -> Alcotest.fail "manual requeue did not normalize, consume, and settle");
  (match (Q.inventory ~base_path ~keeper_names:[ "sangsu" ]).items with
   | [] -> ()
   | _ -> Alcotest.fail "settled candidate remained in quarantine inventory")
;;

let test_ready_requested_recovery_fails_closed () =
  with_temp_base "board-attention-worker-ready-requested" @@ fun base_path ->
  let persisted = record ~base_path (candidate ~id:"candidate-ready-requested" ()) in
  let execute ~before_dispatch:_ ~before_advance:_ _candidate =
    raise (Failure "injected exact worker exception")
  in
  ignore
    (ok
       "create Ready+Requested quarantine"
       (process ~base_path ~prepare:(fun candidate -> Ok candidate) ~execute)
     : W.step);
  let quarantined = load_one_candidate ~base_path in
  let blocked = load_one_partition ~base_path in
  let quarantine =
    match quarantined.status with
    | A.Quarantine { quarantine; phase = A.Quarantined } -> quarantine
    | _ -> Alcotest.fail "Ready+Requested fixture did not project quarantine"
  in
  ignore
    (ok
       "persist Ready+Requested candidate phase"
       (A.request_quarantine_requeue
          ~base_path
          ~candidate:quarantined
          ~partition_id:blocked.partition_id
          ~expected_quarantine_id:quarantine.quarantine_id
          ~requested_at:40.0)
     : A.candidate);
  let ready =
    match
      ok
        "inject premature Ready partition"
        (P.requeue_blocked ~base_path ~partition:blocked)
    with
    | P.Requeued transition -> transition
    | P.Generation_conflict detail ->
      Alcotest.failf "premature Ready fixture conflicted: %s" detail
  in
  (match ready.write_outcome with
   | P.Fsync_completed -> ()
   | P.Visible_sync_unconfirmed detail ->
     Alcotest.failf "premature Ready fixture was not fsynced: %s" detail);
  let request : Q.request =
    { candidate_id = persisted.candidate_id
    ; expected_quarantine_id = quarantine.quarantine_id
    ; decision = Q.Acknowledge_and_requeue
    }
  in
  let command =
    match
      Q.make
        ~keeper_name:"sangsu"
        ~raw_partition_id:blocked.partition_id
        request
    with
    | Ok command -> command
    | Error error ->
      Alcotest.failf "Ready+Requested command rejected: %s" (Q.input_error_to_string error)
  in
  (match Q.execute ~now:41.0 ~base_path command with
   | Error (Q.Partition_state_conflict _) -> ()
   | Error error ->
     Alcotest.failf
       "Ready+Requested returned wrong error: %s"
       (Q.execution_error_label error)
   | Ok _ -> Alcotest.fail "Ready+Requested recovery did not fail closed");
  match (load_one_candidate ~base_path).status, (load_one_partition ~base_path).state with
  | A.Quarantine { phase = A.Requeue_requested _; _ }, P.Ready -> ()
  | _ -> Alcotest.fail "Ready+Requested rejection mutated durable state"
;;

let test_stale_quarantine_generation_is_rejected () =
  with_temp_base "board-attention-worker-stale-quarantine" @@ fun base_path ->
  let persisted = record ~base_path (candidate ~id:"candidate-stale-generation" ()) in
  let execute ~before_dispatch:_ ~before_advance:_ _candidate =
    raise (Failure "injected exact worker exception")
  in
  ignore
    (ok
       "create stale-generation quarantine"
       (process ~base_path ~prepare:(fun candidate -> Ok candidate) ~execute)
     : W.step);
  let quarantined = load_one_candidate ~base_path in
  let blocked = load_one_partition ~base_path in
  let quarantine =
    match quarantined.status with
    | A.Quarantine { quarantine; phase = A.Quarantined } -> quarantine
    | _ -> Alcotest.fail "stale-generation fixture did not project quarantine"
  in
  let request : Q.request =
    { candidate_id = persisted.candidate_id
    ; expected_quarantine_id = quarantine.quarantine_id ^ "-stale"
    ; decision = Q.Acknowledge_and_requeue
    }
  in
  let command =
    match
      Q.make
        ~keeper_name:"sangsu"
        ~raw_partition_id:blocked.partition_id
        request
    with
    | Ok command -> command
    | Error error ->
      Alcotest.failf "stale-generation command rejected: %s" (Q.input_error_to_string error)
  in
  (match Q.execute ~now:50.0 ~base_path command with
   | Error (Q.Candidate_state_conflict _) -> ()
   | Error error ->
     Alcotest.failf
       "stale generation returned wrong error: %s"
       (Q.execution_error_label error)
   | Ok _ -> Alcotest.fail "stale quarantine generation was accepted");
  match (load_one_candidate ~base_path).status, (load_one_partition ~base_path).state with
  | A.Quarantine
      { quarantine = current; phase = A.Quarantined },
    P.Blocked _
    when String.equal current.quarantine_id quarantine.quarantine_id ->
    ()
  | _ -> Alcotest.fail "stale generation rejection mutated durable state"
;;

let test_same_quarantine_command_cas_loser_converges () =
  with_temp_base "board-attention-worker-same-command-cas" @@ fun base_path ->
  ignore (record ~base_path (candidate ()) : A.candidate);
  let execute ~before_dispatch:_ ~before_advance:_ _candidate =
    raise (Failure "injected exact worker exception")
  in
  (match
     ok
       "create durable quarantine"
       (process ~base_path ~prepare:(fun candidate -> Ok candidate) ~execute)
   with
   | W.Partition_blocked _ -> ()
   | _ -> Alcotest.fail "fixture did not block the singleton partition");
  let quarantined = load_one_candidate ~base_path in
  let partition = load_one_partition ~base_path in
  let quarantine =
    match quarantined.status with
    | A.Quarantine { quarantine; phase = A.Quarantined } -> quarantine
    | _ -> Alcotest.fail "fixture candidate was not Quarantined"
  in
  let request : Q.request =
    { candidate_id = quarantined.candidate_id
    ; expected_quarantine_id = quarantine.quarantine_id
    ; decision = Q.Acknowledge_and_requeue
    }
  in
  let command =
    match
      Q.make
        ~keeper_name:"sangsu"
        ~raw_partition_id:partition.partition_id
        request
    with
    | Ok command -> command
    | Error error ->
      Alcotest.failf "manual command rejected: %s" (Q.input_error_to_string error)
  in
  let report =
    ok
      "same command CAS loser converges"
      (Q.For_testing.execute_with_before_partition_commit
         ~before_partition_commit:(fun observed ->
           let competing =
             match
               ok
                 "competing command commits Ready"
                 (P.requeue_blocked ~base_path ~partition:observed)
             with
             | P.Requeued transition -> transition
             | P.Generation_conflict detail ->
               Alcotest.failf "competing command conflicted: %s" detail
           in
           match competing.write_outcome with
           | P.Fsync_completed -> ()
           | P.Visible_sync_unconfirmed detail ->
             Alcotest.failf "competing Ready was not durable: %s" detail)
         ~now:20.0
         ~base_path
         command)
  in
  match report.partition.state with
  | P.Ready -> ()
  | _ -> Alcotest.fail "same command CAS loser did not converge to Ready"
;;

let test_stale_blocked_snapshot_cannot_requeue_new_generation () =
  with_temp_base "board-attention-worker-stale-blocked-generation" @@ fun base_path ->
  ignore (record ~base_path (candidate ()) : A.candidate);
  let execute ~before_dispatch:_ ~before_advance:_ _candidate =
    raise (Failure "injected first exact worker exception")
  in
  (match
     ok
       "create first durable quarantine"
       (process ~base_path ~prepare:(fun candidate -> Ok candidate) ~execute)
   with
   | W.Partition_blocked _ -> ()
   | _ -> Alcotest.fail "fixture did not block the singleton partition");
  let quarantined = load_one_candidate ~base_path in
  let partition = load_one_partition ~base_path in
  let quarantine =
    match quarantined.status with
    | A.Quarantine { quarantine; phase = A.Quarantined } -> quarantine
    | _ -> Alcotest.fail "fixture candidate was not Quarantined"
  in
  let request : Q.request =
    { candidate_id = quarantined.candidate_id
    ; expected_quarantine_id = quarantine.quarantine_id
    ; decision = Q.Acknowledge_and_requeue
    }
  in
  let command =
    match
      Q.make
        ~keeper_name:"sangsu"
        ~raw_partition_id:partition.partition_id
        request
    with
    | Ok command -> command
    | Error error ->
      Alcotest.failf "manual command rejected: %s" (Q.input_error_to_string error)
  in
  let ready_snapshot = ref None in
  (match
     Q.For_testing.execute_with_before_partition_commit
       ~before_partition_commit:(fun observed ->
         let first_ready =
           match
             ok
               "competing command requeues first generation"
               (P.requeue_blocked ~base_path ~partition:observed)
           with
           | P.Requeued transition -> transition
           | P.Generation_conflict detail ->
             Alcotest.failf "first Ready generation conflicted: %s" detail
         in
         (match first_ready.write_outcome with
          | P.Fsync_completed -> ()
          | P.Visible_sync_unconfirmed detail ->
            Alcotest.failf "first Ready transition was not durable: %s" detail);
         ready_snapshot := Some first_ready.partition;
         let owner = P.Worker_epoch.generate () in
         let running =
           match
             ok
               "worker claims requeued partition"
               (P.claim_next
                  ~now:20.0
                  ~worker_epoch:owner
                  ~base_path
                  ~keeper_name:"sangsu")
           with
           | Some partition -> partition
           | None -> Alcotest.fail "requeued partition was not claimable"
         in
         let newer =
           ok
             "worker commits newer Blocked generation"
             (P.block
                ~now:21.0
                ~worker_epoch:owner
                ~base_path
                ~partition:running
                (P.Unexpected_worker_failure "newer exact worker failure"))
         in
         match newer.write_outcome with
         | P.Fsync_completed -> ()
         | P.Visible_sync_unconfirmed detail ->
           Alcotest.failf "newer Blocked generation was not durable: %s" detail)
       ~now:19.0
       ~base_path
       command
   with
   | Error error ->
     Alcotest.(check string)
       "stale command returns partition conflict"
       "partition_state_conflict"
       (Q.execution_error_label error)
   | Ok _ ->
     Alcotest.fail "stale command requeued a newer failure generation");
  (match !ready_snapshot with
   | None -> Alcotest.fail "competing command did not retain its Ready snapshot"
   | Some ready ->
     (match P.confirm_ready ~base_path ~partition:ready with
      | Error _ -> ()
      | Ok _ ->
        Alcotest.fail "Ready confirmation reopened a newer Blocked generation"));
  match (load_one_partition ~base_path).state with
  | P.Blocked { blocked_at; _ } ->
    Alcotest.(check (float 0.0)) "newer Blocked generation retained" 21.0 blocked_at
  | _ -> Alcotest.fail "stale command changed the newer Blocked generation"
;;

let test_cross_domain_wake_is_coalesced_and_rearmed () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  with_temp_base "board-attention-worker-wake" @@ fun base_path ->
  (match ok "unregistered request" (Wake.request ~base_path ~keeper_name:"sangsu") with
   | Wake.Not_registered -> ()
   | Wake.Signaled | Wake.Coalesced -> Alcotest.fail "unregistered wake was accepted");
  let registration =
    ok "register worker wake" (Wake.register ~sw ~base_path ~keeper_name:"sangsu")
  in
  (match
     W.run
       ~sw
       ~clock:(Eio.Stdenv.clock env)
       ~net:None
       ~base_path
       ~keeper_name:"sangsu"
   with
   | Error { stage = W.Registration; _ } -> ()
   | Error fatal ->
     Alcotest.failf
       "duplicate registration returned the wrong fatal stage: %s"
       (W.fatal_error_to_string fatal)
   | Ok () -> Alcotest.fail "duplicate registration returned normally");
  let first =
    Domain.spawn (fun () -> Wake.request ~base_path ~keeper_name:"sangsu")
    |> Domain.join
    |> ok "cross-domain wake"
  in
  (match first with
   | Wake.Signaled -> ()
   | Wake.Coalesced | Wake.Not_registered -> Alcotest.fail "first wake was not signaled");
  (match ok "coalesced wake" (Wake.request ~base_path ~keeper_name:"sangsu") with
   | Wake.Coalesced -> ()
   | Wake.Signaled | Wake.Not_registered -> Alcotest.fail "pending wake did not coalesce");
  (match Wake.await registration with
   | Wake.Wake -> ()
   | Wake.Registration_closed -> Alcotest.fail "live registration closed");
  (match ok "rearmed wake" (Wake.request ~base_path ~keeper_name:"sangsu") with
   | Wake.Signaled -> ()
   | Wake.Coalesced | Wake.Not_registered ->
     Alcotest.fail "consumed wake did not rearm");
  Wake.unregister registration;
  match ok "explicit unregister" (Wake.request ~base_path ~keeper_name:"sangsu") with
  | Wake.Not_registered -> ()
  | Wake.Signaled | Wake.Coalesced ->
    Alcotest.fail "worker lifetime left a stale wake registration"
;;

let () =
  Alcotest.run
    "keeper_board_attention_worker"
    [ ( "worker exact callback integration"
      , [ Alcotest.test_case
            "callback conversion, advancement, completion, settlement"
            `Quick
            test_worker_exact_callback_integration_and_owner_settlement
        ; Alcotest.test_case
            "setup error stops before claim"
            `Quick
            test_setup_error_stops_before_claim_without_hot_retry
        ; Alcotest.test_case
            "execution error preserves bound progress"
            `Quick
            test_execution_error_preserves_bound_progress_without_hot_retry
        ; Alcotest.test_case
            "completion failure preserves bound provenance"
            `Quick
            test_completion_failure_preserves_bound_provenance
        ; Alcotest.test_case
            "flow replay blocks Unbound without retry"
            `Quick
            test_flow_already_started_blocks_unbound_without_hot_retry
        ; Alcotest.test_case
            "domain error quarantines Bound without retry"
            `Quick
            test_domain_error_quarantines_bound_progress_without_hot_retry
        ; Alcotest.test_case
            "Bound cancellation is prompt and process-recoverable"
            `Quick
            test_bound_cancellation_is_prompt_and_process_recoverable
        ; Alcotest.test_case
            "Advancing cancellation is prompt and process-recoverable"
            `Quick
            test_advancing_cancellation_is_prompt_and_process_recoverable
        ; Alcotest.test_case
            "Unbound cancellation waits for process-start recovery"
            `Quick
            test_unbound_cancellation_waits_for_process_start_recovery
        ; Alcotest.test_case
            "terminal root does not strand Ready sibling"
            `Quick
            test_terminal_root_does_not_strand_ready_sibling
        ; Alcotest.test_case
            "Completed startup replays owner wake"
            `Quick
            test_completed_startup_replays_owner_wake
        ; Alcotest.test_case
            "existing Judged skips exact flow"
            `Quick
            test_existing_judgment_skips_exact_flow
        ; Alcotest.test_case
            "existing Consumed skips exact flow and settles"
            `Quick
            test_existing_consumed_skips_exact_flow_and_settles
        ; Alcotest.test_case
            "Consumed Completed crash settles without duplicate delivery"
            `Quick
            test_consumed_completed_crash_settles_without_duplicate_delivery
        ; Alcotest.test_case
            "process recovery claim releases after cancellation"
            `Quick
            test_process_recovery_claim_is_released_after_cancellation
        ; Alcotest.test_case
            "unexpected exception is terminal"
            `Quick
            test_unexpected_exception_is_terminal_without_hot_retry
        ; Alcotest.test_case
            "Requested+Blocked recovery and two sequential CAS converge"
            `Quick
            test_requested_blocked_recovery_and_sequential_cas_converge
        ; Alcotest.test_case
            "Requeued+Blocked recovery settles normally"
            `Quick
            test_manual_quarantine_requeue_is_unclaimable_until_authorized_and_settles
        ; Alcotest.test_case
            "Ready+Requested recovery fails closed"
            `Quick
            test_ready_requested_recovery_fails_closed
        ; Alcotest.test_case
            "stale quarantine generation is rejected"
            `Quick
            test_stale_quarantine_generation_is_rejected
        ; Alcotest.test_case
            "same quarantine command CAS loser converges"
            `Quick
            test_same_quarantine_command_cas_loser_converges
        ; Alcotest.test_case
            "stale Blocked snapshot cannot requeue a newer generation"
            `Quick
            test_stale_blocked_snapshot_cannot_requeue_new_generation
        ; Alcotest.test_case
            "cross-domain wake coalesces and rearms"
            `Quick
            test_cross_domain_wake_is_coalesced_and_rearmed
        ] )
    ]
;;
