module AQ = Masc.Keeper_approval_queue
module Gate = Masc.Keeper_gate
module Registry_queue = Masc.Keeper_registry_event_queue
module Queue_state = Keeper_event_queue_state

(* Test-local shim for the excised [Keeper_approval_queue.resolve] wrapper:
   reproduces its unit projection over [resolve_with_policy] so these
   assertions keep exercising the production resolution path. *)
let aq_resolve ~base_path ~id ~decision =
  match AQ.resolve_with_policy ~base_path ~id ~decision () with
  | Ok _ -> Ok ()
  | Error _ as error -> error
;;

let yojson = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_approval_queue_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir dir =
  let rec remove path =
    if Sys.is_directory path
    then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  try remove dir with
  | Sys_error _ -> ()
;;

let rec ensure_dir path =
  if Sys.file_exists path
  then ()
  else (
    ensure_dir (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let durable_resolution_opt ~base_path ~keeper_name ~approval_id =
  Registry_queue.snapshot ~base_path keeper_name
  |> Keeper_event_queue.to_list
  |> List.find_map (fun (stimulus : Keeper_event_queue.stimulus) ->
    match stimulus.payload with
    | Keeper_event_queue.Hitl_resolved resolution
      when String.equal resolution.approval_id approval_id ->
      Some resolution
    | _ -> None)
;;

let require_some message = function
  | Some value -> value
  | None -> Alcotest.fail message
;;

let pending_entry_exn id =
  AQ.get_pending_entry ~id |> require_some ("pending approval not found: " ^ id)
;;

let drop_resolution ~base_path ~keeper_name resolution =
  let post_id = Keeper_event_queue.hitl_resolution_post_id resolution in
  match Registry_queue.drop_by_post_id ~base_path keeper_name ~post_id with
  | Ok _ -> ()
  | Error reason -> Alcotest.fail reason
;;

let lease_for_resolution (resolution : Keeper_event_queue.hitl_resolution) =
  let stimulus : Keeper_event_queue.stimulus =
    { post_id = Keeper_event_queue.hitl_resolution_post_id resolution
    ; urgency = Keeper_event_queue.Immediate
    ; arrived_at = 1.0
    ; payload = Keeper_event_queue.Hitl_resolved resolution
    }
  in
  let pending = Keeper_event_queue.enqueue Keeper_event_queue.empty stimulus in
  let state = Queue_state.with_pending pending Queue_state.empty in
  match Queue_state.claim_when ~claimed_at:2.0 ~ready:(fun _ -> true) state with
  | Ok (_, Some lease) -> lease
  | Ok (_, None) -> Alcotest.fail "approved resolution was not claimed"
  | Error reason -> Alcotest.fail reason
;;

let submit_with_context
      ?turn_id
      ?request_context
      ?task_id
      ?goal_id
      ?(goal_ids = [])
      ?continuation_channel
      ~base_path
      ~keeper_name
      ~input
      ()
  =
  match
    AQ.submit_pending
      ~keeper_name
      ~tool_name:"external-effect"
      ~input
      ~base_path
      ?turn_id
      ?request_context
      ?task_id
      ?goal_id
      ~goal_ids
      ?continuation_channel
      ()
  with
  | Ok id -> id
  | Error error -> Alcotest.fail (AQ.storage_error_to_string error)
;;

let submit ~base_path ~keeper_name ~input =
  submit_with_context ~base_path ~keeper_name ~input ()
;;

let reject_and_cleanup ~base_path id =
  match aq_resolve ~base_path ~id ~decision:(AQ.Decision.Reject "test cleanup") with
  | Ok () -> ()
  | Error error -> Alcotest.fail (AQ.resolve_error_to_string error)
;;

let install_exn ~base_path =
  match AQ.install_persistence ~base_path with
  | Ok report -> report
  | Error error -> Alcotest.fail (AQ.install_error_to_string error)
;;

let test_pending_store_lock_serializes_eio_fibers () =
  Eio_main.run @@ fun _environment ->
  let first_entered, signal_first_entered = Eio.Promise.create () in
  let second_attempted, signal_second_attempted = Eio.Promise.create () in
  let release_first, signal_release_first = Eio.Promise.create () in
  let order = ref [] in
  Eio.Fiber.all
    [ (fun () ->
        AQ.For_testing.with_pending_store_lock (fun () ->
          order := "first_entered" :: !order;
          Eio.Promise.resolve signal_first_entered ();
          Eio.Promise.await release_first;
          order := "first_released" :: !order))
    ; (fun () ->
        Eio.Promise.await first_entered;
        Eio.Promise.resolve signal_second_attempted ();
        AQ.For_testing.with_pending_store_lock (fun () ->
          order := "second_entered" :: !order))
    ; (fun () ->
        Eio.Promise.await second_attempted;
        Eio.Promise.resolve signal_release_first ())
    ];
  Alcotest.(check (list string))
    "second fiber enters only after the yielding durable transition releases"
    [ "first_entered"; "first_released"; "second_entered" ]
    (List.rev !order)
;;

let test_dedup_never_merges_distinct_origins () =
  let base_path = temp_dir () in
  let keeper_name = "queue-distinct-origin" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let input = `Assoc [ "target", `String "same-action" ] in
       let dashboard_a =
         Keeper_continuation_channel.dashboard ~thread_id:"thread-a"
         |> Result.get_ok
       in
       let dashboard_b =
         Keeper_continuation_channel.dashboard ~thread_id:"thread-b"
         |> Result.get_ok
       in
       let first =
         submit_with_context
           ~turn_id:1
           ~goal_ids:[ "goal-a" ]
           ~continuation_channel:dashboard_a
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       let same =
         submit_with_context
           ~turn_id:1
           ~goal_ids:[ "goal-a" ]
           ~continuation_channel:dashboard_a
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       Alcotest.(check string) "same origin deduplicates" first same;
       let another_turn =
         submit_with_context
           ~turn_id:2
           ~goal_ids:[ "goal-a" ]
           ~continuation_channel:dashboard_a
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       let another_channel =
         submit_with_context
           ~turn_id:1
           ~goal_ids:[ "goal-a" ]
           ~continuation_channel:dashboard_b
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       let another_goal_context =
         submit_with_context
           ~turn_id:1
           ~goal_ids:[ "goal-b" ]
           ~continuation_channel:dashboard_a
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       List.iter
         (fun id ->
            Alcotest.(check bool) "distinct origin has its own request" true
              (not (String.equal first id)))
         [ another_turn; another_channel; another_goal_context ];
       List.iter (reject_and_cleanup ~base_path)
         [ first; another_turn; another_channel; another_goal_context ])
;;

let check_update label expected = function
  | Ok actual -> Alcotest.(check bool) label expected actual
  | Error error -> Alcotest.fail (AQ.summary_transition_error_to_string error)
;;

type exact_identity =
  { approval_id_arg : string
  ; input_hash_arg : string
  ; sequence_arg : int
  ; slot_id_arg : string
  ; call_id_arg : string
  ; plan_fingerprint_arg : string
  ; request_body_sha256_arg : string
  }

let exact_identity
      ?(slot_id = "slot-exact")
      ?(call_id = "call-exact")
      ?(plan_fingerprint = "plan-exact")
      ?(request_body_sha256 = String.make 64 'a')
      id
  =
  let entry = pending_entry_exn id in
  { approval_id_arg = entry.id
  ; input_hash_arg = entry.input_hash
  ; sequence_arg = entry.sequence
  ; slot_id_arg = slot_id
  ; call_id_arg = call_id
  ; plan_fingerprint_arg = plan_fingerprint
  ; request_body_sha256_arg = request_body_sha256
  }
;;

let run_exact_transition transition identity =
  transition
    ~id:identity.approval_id_arg
    ~input_hash:identity.input_hash_arg
    ~sequence:identity.sequence_arg
    ~slot_id:identity.slot_id_arg
    ~call_id:identity.call_id_arg
    ~plan_fingerprint:identity.plan_fingerprint_arg
    ~request_body_sha256:identity.request_body_sha256_arg
;;

let complete_exact identity summary =
  AQ.complete_summary_exact_attempt
    ~id:identity.approval_id_arg
    ~input_hash:identity.input_hash_arg
    ~sequence:identity.sequence_arg
    ~slot_id:identity.slot_id_arg
    ~call_id:identity.call_id_arg
    ~plan_fingerprint:identity.plan_fingerprint_arg
    ~request_body_sha256:identity.request_body_sha256_arg
    ~summary
;;

let quarantine_exact identity cause =
  AQ.quarantine_summary_exact_attempt
    ~id:identity.approval_id_arg
    ~input_hash:identity.input_hash_arg
    ~sequence:identity.sequence_arg
    ~slot_id:identity.slot_id_arg
    ~call_id:identity.call_id_arg
    ~plan_fingerprint:identity.plan_fingerprint_arg
    ~request_body_sha256:identity.request_body_sha256_arg
    ~cause
;;

let fail_exact_before_dispatch identity ~reason ~retryable =
  AQ.fail_summary_exact_attempt_before_dispatch
    ~id:identity.approval_id_arg
    ~input_hash:identity.input_hash_arg
    ~sequence:identity.sequence_arg
    ~slot_id:identity.slot_id_arg
    ~call_id:identity.call_id_arg
    ~plan_fingerprint:identity.plan_fingerprint_arg
    ~request_body_sha256:identity.request_body_sha256_arg
    ~reason
    ~retryable
;;

let check_exact_update label expected = function
  | Ok { AQ.changed; write_outcome = AQ.Durable } ->
    Alcotest.(check bool) label expected changed
  | Ok { write_outcome = AQ.Visible_durability_unknown detail; _ } ->
    Alcotest.failf "%s returned visible durability uncertainty: %s" label detail
  | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
;;

let run_exact_transition_with_writer transition ~writer identity =
  transition
    ~save_file_atomic_strict_staged:writer
    ~id:identity.approval_id_arg
    ~input_hash:identity.input_hash_arg
    ~sequence:identity.sequence_arg
    ~slot_id:identity.slot_id_arg
    ~call_id:identity.call_id_arg
    ~plan_fingerprint:identity.plan_fingerprint_arg
    ~request_body_sha256:identity.request_body_sha256_arg
;;

let visible_after_rename_writer path body =
  match Fs_compat.save_file_atomic path body with
  | Error reason -> Alcotest.failf "visible writer could not replace %s: %s" path reason
  | Ok () ->
    Error
      { Fs_compat.path
      ; stage = Fs_compat.After_rename
      ; exception_ = Failure "injected parent sync failure"
      ; backtrace = Printexc.get_raw_backtrace ()
      }
;;

let before_rename_writer path _body =
  Error
    { Fs_compat.path
    ; stage = Fs_compat.Before_rename
    ; exception_ = Failure "injected pre-rename failure"
    ; backtrace = Printexc.get_raw_backtrace ()
    }
;;

let check_visible_update label expected = function
  | Ok
      { AQ.changed
      ; write_outcome = AQ.Visible_durability_unknown detail
      } ->
    Alcotest.(check bool) (label ^ " changed") expected changed;
    Alcotest.(check bool) (label ^ " detail") true (String.trim detail <> "")
  | Ok { write_outcome = AQ.Durable; _ } ->
    Alcotest.failf "%s unexpectedly reported durable" label
  | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
;;

let expect_summary_rejection label expected = function
  | Error
      (AQ.Summary_transition_rejected
        (AQ.Summary_exact_attempt_bound _))
    when expected = `Bound ->
    ()
  | Error
      (AQ.Summary_transition_rejected
        (AQ.Summary_legacy_execution_uncertain _))
    when expected = `Legacy ->
    ()
  | Error error ->
    Alcotest.failf
      "%s returned the wrong rejection: %s"
      label
      (AQ.summary_transition_error_to_string error)
  | Ok _ -> Alcotest.failf "%s accepted an execution-uncertain entry" label
;;

let exact_summary ?(context_summary = "Exact attempt summary") model_run_id :
    AQ.hitl_context_summary
  =
  { summary_version = 2
  ; generated_at = Unix.gettimeofday ()
  ; model_run_id
  ; context_summary
  ; key_questions = []
  ; judgment = AQ.Approve
  ; rationale = "The exact durable attempt supports this judgment."
  }
;;

let read_pending_snapshot ~base_path =
  Yojson.Safe.from_file (AQ.For_testing.pending_store_path ~base_path)
;;

let write_pending_snapshot ~base_path json =
  let path = AQ.For_testing.pending_store_path ~base_path in
  ensure_dir (Filename.dirname path);
  Out_channel.with_open_text path (fun channel ->
    output_string channel (Yojson.Safe.pretty_to_string json))
;;

let delivery_json ~entry ~remember_rule =
  `Assoc
    [ "entry", entry
    ; "decision", `Assoc [ "kind", `String "approve" ]
    ; "source", `String "human_operator"
    ; "remember_rule", `Bool remember_rule
    ; "created_by", `Null
    ; "grant_consumed", `Bool false
    ]
;;

let test_install_serializes_snapshot_read_with_same_base_mutation () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       write_pending_snapshot
         ~base_path
         (`Assoc
            [ "version", `Int 3
            ; "next_sequence", `Int 1
            ; "pending", `List []
            ; "deliveries", `List []
            ]);
       Eio_main.run @@ fun _environment ->
       let snapshot_loaded, signal_snapshot_loaded = Eio.Promise.create () in
       let mutation_attempted, signal_mutation_attempted = Eio.Promise.create () in
       let release_install, signal_release_install = Eio.Promise.create () in
       let install_done, signal_install_done = Eio.Promise.create () in
       let mutation_done, signal_mutation_done = Eio.Promise.create () in
       let mutation_completed_before_release = ref false in
       Eio.Fiber.all
         [ (fun () ->
             let result =
               AQ.For_testing.install_persistence_with_after_load_hook
                 ~base_path
                 ~after_load:(fun () ->
                   Eio.Promise.resolve signal_snapshot_loaded ();
                   Eio.Promise.await release_install)
             in
             Eio.Promise.resolve signal_install_done result)
         ; (fun () ->
             Eio.Promise.await snapshot_loaded;
             Eio.Promise.resolve signal_mutation_attempted ();
             let id =
               submit
                 ~base_path
                 ~keeper_name:"queue-install-race"
                 ~input:(`Assoc [ "target", `String "after-load" ])
             in
             Eio.Promise.resolve signal_mutation_done id)
         ; (fun () ->
             Eio.Promise.await mutation_attempted;
             mutation_completed_before_release :=
               Option.is_some (Eio.Promise.peek mutation_done);
             Eio.Promise.resolve signal_release_install ())
         ];
       Alcotest.(check bool)
         "same-base mutation waits for snapshot installation"
         false
         !mutation_completed_before_release;
       let report = Eio.Promise.await install_done in
       let mutation_id = Eio.Promise.await mutation_done in
       (match report with
        | Error error -> Alcotest.fail (AQ.install_error_to_string error)
        | Ok report -> Alcotest.(check int) "empty snapshot installed" 0 report.loaded_pending);
       Alcotest.(check int) "mutation remains in memory" 1 (List.length (AQ.list_pending_entries ()));
       Alcotest.(check bool)
         "mutation id remains addressable"
         true
         (Option.is_some (AQ.get_pending_entry ~id:mutation_id));
       let open Yojson.Safe.Util in
       let persisted_ids =
         read_pending_snapshot ~base_path
         |> member "pending"
         |> to_list
         |> List.map (fun entry -> entry |> member "id" |> to_string)
       in
       Alcotest.(check bool)
         "mutation remains in the durable snapshot"
         true
         (List.mem mutation_id persisted_ids))
;;

let test_submit_is_nonblocking_and_exactly_deduplicated () =
  let base_path = temp_dir () in
  let keeper_name = "queue-exact-submit" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let input =
         `Assoc
           [ "target", `String "document"
           ; "payload", `Assoc [ "text", `String "hello"; "nonce", `Int 1 ]
           ]
       in
       let request_context =
         `Assoc
           [ ( "initial"
             , `Assoc
                 [ "history_messages", `List [ `String "older exact turn" ]
                 ; "base_system_prompt", `String "exact base policy"
                 ; "turn_system_prompt", `String "exact turn policy"
                 ; "user_message", `String "write the exact document"
                 ] )
           ; "completed_tool_calls", `List []
           ]
       in
       let first =
         submit_with_context
           ~turn_id:12
           ~request_context
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       let reordered =
         `Assoc
           [ "payload", `Assoc [ "nonce", `Int 1; "text", `String "hello" ]
           ; "target", `String "document"
           ]
       in
       let same =
         submit_with_context
           ~turn_id:12
           ~request_context
           ~base_path
           ~keeper_name
           ~input:reordered
           ()
       in
       Alcotest.(check string) "same exact request" first same;
       let open Yojson.Safe.Util in
       let persisted_entry =
         read_pending_snapshot ~base_path
         |> member "pending"
         |> to_list
         |> List.find (fun entry -> String.equal (entry |> member "id" |> to_string) first)
       in
       Alcotest.(check int)
         "exact context wire version"
         1
         (persisted_entry |> member "request_context_version" |> to_int);
       let changed =
         submit
           ~base_path
           ~keeper_name
           ~input:
             (`Assoc
                [ "target", `String "document"
                ; "payload", `Assoc [ "text", `String "hello"; "nonce", `Int 2 ]
                ])
       in
       Alcotest.(check bool) "changed field is a different request" true
         (not (String.equal first changed));
       Alcotest.(check int) "first request sequence" 1 (pending_entry_exn first).sequence;
       Alcotest.(check int)
         "dedup does not consume sequence"
         2
         (pending_entry_exn changed).sequence;
       (match AQ.get_pending_entry ~id:first with
        | None -> Alcotest.fail "pending request missing"
        | Some entry ->
          Alcotest.(check bool) "summary is not started by queue" true
            (entry.summary_status = AQ.Summary_not_requested);
          Alcotest.check (Alcotest.option yojson)
            "exact outer-turn context"
            (Some request_context)
            entry.request_context);
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       (match AQ.get_pending_entry ~id:first with
        | Some entry ->
          Alcotest.check (Alcotest.option yojson)
            "outer-turn context survives restart"
            (Some request_context)
            entry.request_context
        | None -> Alcotest.fail "pending request was not restored");
       reject_and_cleanup ~base_path first;
       reject_and_cleanup ~base_path changed)
;;

let test_unversioned_request_context_is_not_replayed_as_exact () =
  let base_path = temp_dir () in
  let keeper_name = "queue-legacy-context" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id =
         submit_with_context
           ~request_context:(`Assoc [ "history_digest", `String "retired-projection" ])
           ~base_path
           ~keeper_name
           ~input:(`String "legacy")
           ()
       in
       let snapshot = read_pending_snapshot ~base_path in
       let unversioned =
         match snapshot with
         | `Assoc fields ->
           let pending =
             match List.assoc_opt "pending" fields with
             | Some (`List entries) ->
               `List
                 (List.map
                    (function
                      | `Assoc entry_fields ->
                        `Assoc (List.remove_assoc "request_context_version" entry_fields)
                      | entry -> entry)
                    entries)
             | Some pending -> pending
             | None -> `List []
           in
           `Assoc (("pending", pending) :: List.remove_assoc "pending" fields)
         | other -> other
       in
       AQ.For_testing.reset_runtime_state ();
       write_pending_snapshot ~base_path unversioned;
       ignore (install_exn ~base_path);
       (match AQ.get_pending_entry ~id with
        | Some { request_context = None; _ } -> ()
        | Some { request_context = Some _; _ } ->
          Alcotest.fail "unversioned projected context was treated as exact evidence"
        | None -> Alcotest.fail "legacy pending request was not restored");
       reject_and_cleanup ~base_path id)
;;

let test_monotonic_sequence_survives_restart () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let first = submit ~base_path ~keeper_name:"sequence-owner" ~input:(`Int 1) in
       let second = submit ~base_path ~keeper_name:"sequence-owner" ~input:(`Int 2) in
       Alcotest.(check int) "first durable sequence" 1 (pending_entry_exn first).sequence;
       Alcotest.(check int) "second durable sequence" 2 (pending_entry_exn second).sequence;
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let third = submit ~base_path ~keeper_name:"sequence-owner" ~input:(`Int 3) in
       Alcotest.(check int) "restart continues sequence" 3 (pending_entry_exn third).sequence;
       let open Yojson.Safe.Util in
       Alcotest.(check int)
         "next sequence is durable"
         4
         (read_pending_snapshot ~base_path |> member "next_sequence" |> to_int))
;;

let test_same_owner_drain_uses_sequence_not_wall_clock () =
  let base_path = temp_dir () in
  let other_base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path;
      cleanup_dir other_base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       ignore (install_exn ~base_path:other_base_path);
       let first = submit ~base_path ~keeper_name:"fifo-owner" ~input:(`Int 1) in
       let second = submit ~base_path ~keeper_name:"fifo-owner" ~input:(`Int 2) in
       let other =
         submit ~base_path:other_base_path ~keeper_name:"fifo-owner" ~input:(`Int 3)
       in
       let first = { (pending_entry_exn first) with requested_at = 500.0 } in
       let second = { (pending_entry_exn second) with requested_at = 1.0 } in
       let expected_global =
         if String.compare base_path other_base_path < 0
         then [ first.id; second.id; other ]
         else [ other; first.id; second.id ]
       in
       Alcotest.(check (list string))
         "global projection groups deterministic workspace-local FIFO"
         expected_global
         (AQ.list_pending_entries ()
          |> List.map (fun (entry : AQ.pending_approval) -> entry.id));
       match
         Gate.For_testing.ready_auto_judges_for_owner
           ~base_path
           ~keeper_name:"fifo-owner"
           [ second; first ]
       with
       | [ oldest; newest ] ->
         Alcotest.(check string) "oldest sequence first" first.id oldest.id;
         Alcotest.(check string) "next sequence second" second.id newest.id
       | entries ->
         Alcotest.failf "two same-owner entries expected, got %d" (List.length entries))
;;

let test_different_owners_claim_in_parallel () =
  (* Real concurrent proof: fibers race the per-owner claim, so the
     one-winner-per-owner invariant is exercised under actual Atomic
     contention instead of sequential calls.  Unique owner names keep the
     process-global active map isolated without a production reset. *)
  let base_path = temp_dir () in
  let suffix = string_of_int (int_of_float (Unix.gettimeofday () *. 1_000_000.0)) in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let owner_a = "owner-a-" ^ suffix in
       let owner_b = "owner-b-" ^ suffix in
       let entry_a1 =
         pending_entry_exn (submit ~base_path ~keeper_name:owner_a ~input:(`Int 1))
       in
       let entry_a2 =
         pending_entry_exn (submit ~base_path ~keeper_name:owner_a ~input:(`Int 2))
       in
       let entry_b1 =
         pending_entry_exn (submit ~base_path ~keeper_name:owner_b ~input:(`Int 1))
       in
       let winners_a = Atomic.make 0 in
       let winners_b = Atomic.make 0 in
       let hammer entry winners =
         for _ = 1 to 40 do
           if Gate.For_testing.claim_auto_judge entry
           then ignore (Atomic.fetch_and_add winners 1)
         done
       in
       Eio_main.run (fun _env ->
         Eio.Switch.run (fun sw ->
           Eio.Fiber.fork ~sw (fun () -> hammer entry_a1 winners_a);
           Eio.Fiber.fork ~sw (fun () -> hammer entry_a1 winners_a);
           Eio.Fiber.fork ~sw (fun () -> hammer entry_b1 winners_b);
           Eio.Fiber.fork ~sw (fun () -> hammer entry_b1 winners_b)));
       Alcotest.(check int) "one winner for owner A under contention" 1 (Atomic.get winners_a);
       Alcotest.(check int) "one winner for owner B in parallel" 1 (Atomic.get winners_b);
       Gate.For_testing.release_auto_judge entry_a1;
       Alcotest.(check bool) "same owner re-claims after release" true
         (Gate.For_testing.claim_auto_judge entry_a2))
;;

let test_resolution_is_durable_and_origin_scoped () =
  let base_path = temp_dir () in
  let keeper_name = "queue-origin" in
  let unrelated_keeper = "queue-unrelated" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let input = `Assoc [ "target", `String "document"; "body", `String "hello" ] in
       let id = submit ~base_path ~keeper_name ~input in
       let result =
         AQ.resolve_with_policy
           ~base_path
           ~id
           ~decision:AQ.Decision.Approve
           ~remember_rule:true
           ~created_by:"operator"
           ()
       in
       let resolution_result =
         match result with
         | Ok result -> result
         | Error error -> Alcotest.fail (AQ.resolve_error_to_string error)
       in
       Alcotest.(check bool) "exact rule persisted" true
         (Option.is_some resolution_result.remembered_rule);
       Alcotest.(check bool) "pending removed" false
         (Option.is_some (AQ.get_pending_entry ~id));
       let resolution =
         match durable_resolution_opt ~base_path ~keeper_name ~approval_id:id with
         | None -> Alcotest.fail "origin Keeper did not receive durable resolution"
         | Some resolution -> resolution
       in
       (match resolution.decision with
        | Keeper_event_queue.Hitl_approved -> ()
        | Keeper_event_queue.Hitl_rejected _ | Keeper_event_queue.Hitl_edited _ ->
          Alcotest.fail "expected approved resolution");
       (match AQ.approved_resolution_request ~base_path ~id with
        | Ok (Some request) ->
          Alcotest.(check string) "journal keeper" keeper_name request.keeper_name;
          Alcotest.(check string) "journal operation" "external-effect" request.tool_name;
          Alcotest.(check bool) "journal complete input" true
            (Yojson.Safe.equal input request.input)
        | Ok None -> Alcotest.fail "approved journal was consumed before Gate use"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       Alcotest.(check bool) "unrelated Keeper receives no resolution" true
         (Option.is_none
            (durable_resolution_opt
               ~base_path
               ~keeper_name:unrelated_keeper
               ~approval_id:id));
       Alcotest.(check bool) "exact remembered request matches" true
         (match
            AQ.find_matching_rule
              ~base_path
              ~keeper_name
              ~tool_name:"external-effect"
              ~input
              ()
          with
          | Ok (AQ.Rule_match_active _) -> true
          | Ok (AQ.Rule_match_expired _ | AQ.Rule_match_absent) -> false
          | Error error -> Alcotest.fail (AQ.rule_store_error_to_string error));
       (match
          AQ.consume_approved_resolution
            ~base_path
            ~id
            ~keeper_name
            ~tool_name:"external-effect"
            ~input:(`Assoc [ "target", `String "other" ])
        with
        | Ok AQ.Consumption_not_matching -> ()
        | Ok (AQ.Consumption_committed | AQ.Consumption_already_committed) ->
          Alcotest.fail "changed input consumed the exact grant"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       (match
          AQ.consume_approved_resolution
            ~base_path
            ~id
            ~keeper_name
            ~tool_name:"external-effect"
            ~input
        with
        | Ok AQ.Consumption_committed -> ()
        | Ok (AQ.Consumption_already_committed | AQ.Consumption_not_matching) ->
          Alcotest.fail "exact request did not consume its grant"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       drop_resolution ~base_path ~keeper_name resolution)
;;

let test_remembered_rule_carries_requested_expiry () =
  let base_path = temp_dir () in
  let keeper_name = "queue-expiry-origin" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let input = `Assoc [ "target", `String "document" ] in
       let id = submit ~base_path ~keeper_name ~input in
       let expires_at = Unix.gettimeofday () +. 600.0 in
       let result =
         AQ.resolve_with_policy
           ~base_path
           ~id
           ~decision:AQ.Decision.Approve
           ~remember_rule:true
           ~rule_expires_at:expires_at
           ~created_by:"operator"
           ()
       in
       (match result with
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error)
        | Ok { remembered_rule = None } ->
          Alcotest.fail "approved remember_rule resolution must persist a rule"
        | Ok { remembered_rule = Some rule } ->
          Alcotest.(check (option (float 0.0)))
            "rule carries requested expiry"
            (Some expires_at)
            rule.expires_at);
       (* A same-request replay stays idempotent only when the expiry matches. *)
       (match
          AQ.resolve_with_policy
            ~base_path
            ~id
            ~decision:AQ.Decision.Approve
            ~remember_rule:true
            ~rule_expires_at:expires_at
            ~created_by:"operator"
            ()
        with
        | Ok _ -> ()
        | Error error ->
          Alcotest.fail
            ("identical expiry re-resolution must be idempotent: "
             ^ AQ.resolve_error_to_string error));
       match AQ.list_rules ~base_path () with
       | Error error -> Alcotest.fail (AQ.rule_store_error_to_string error)
       | Ok [ rule ] ->
         Alcotest.(check (option (float 0.0)))
           "persisted rule carries requested expiry"
           (Some expires_at)
           rule.expires_at
       | Ok rules ->
         Alcotest.failf "one remembered rule expected, got %d" (List.length rules))
;;

let test_cycle_grant_uses_exact_effect_and_is_consumed_once () =
  let base_path = temp_dir () in
  let keeper_name = "queue-one-shot-origin" in
  let input =
    `Assoc
      [ "target", `String "same-shape"
      ; "payload", `Assoc [ "value", `Int 1 ]
      ]
  in
  let continuation_channel =
    Keeper_continuation_channel.dashboard ~thread_id:"origin-thread"
    |> Result.get_ok
  in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let approval_id =
         submit_with_context
           ~turn_id:17
           ~task_id:"task-origin"
           ~goal_ids:[ "goal-origin" ]
           ~continuation_channel
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       (match aq_resolve ~base_path ~id:approval_id ~decision:AQ.Decision.Approve with
        | Ok () -> ()
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error));
       let resolution =
         match
           durable_resolution_opt ~base_path ~keeper_name ~approval_id
         with
         | Some resolution -> resolution
         | None -> Alcotest.fail "approved resolution was not delivered"
       in
       AQ.For_testing.reset_runtime_state ();
       let report = install_exn ~base_path in
       Alcotest.(check int) "unconsumed grant restored" 1 report.replayed_deliveries;
       (match AQ.approved_resolution_state ~base_path ~id:approval_id with
        | Ok AQ.Resolution_unconsumed -> ()
        | Ok AQ.Resolution_consumed -> Alcotest.fail "restart lost the unconsumed grant"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       let grant =
         match Gate.cycle_grant_of_resolution resolution with
         | Some grant -> grant
         | None -> Alcotest.fail "approved resolution did not create a cycle grant"
       in
       let lease = lease_for_resolution resolution in
       (match
          Masc.Keeper_heartbeat_loop.settlement_of_cycle_outcome
            ~base_path
            ~settled_at:3.0
            ~stop_requested:false
            ~compaction_consecutive_failures:0
      ~transcript_quarantine_consecutive_retries:0
            ~lease
            None
        with
        | Masc.Keeper_registry_event_queue.Requeue
            Masc.Keeper_registry_event_queue.Approval_grant_unconsumed ->
          ()
        | _ -> Alcotest.fail "unconsumed grant wake was acknowledged");
       let request ~input ~task_id ~goal_ids : Gate.request =
         { keeper_name
         ; operation = "external-effect"
         ; input
         ; base_path
         ; causal_context =
             Some { Gate.turn_id = Some 99; snapshot = `Assoc [] }
         ; task_id
         ; goal_ids
         ; continuation_channel = None
         }
       in
       let source_of = function
         | Gate.Allow { source } -> source
         | Gate.Deferred _ -> Alcotest.fail "keeper Always Allow unexpectedly deferred"
         | Gate.Unavailable reason ->
           Alcotest.fail (Gate.unavailable_reason_to_string reason)
       in
       (match
          Gate.decide
            ~cycle_grant:grant
            ~keeper_always_allow:true
            (request
               ~input:(`Assoc [ "target", `String "different" ])
               ~task_id:(Some "task-other")
               ~goal_ids:[ "goal-other" ])
          |> source_of
        with
        | Gate.Keeper_always_allow -> ()
        | Gate.One_shot_resolution _
        | Gate.Exact_always_rule _
        | Gate.Workspace_always_allow ->
          Alcotest.fail "different exact input consumed the grant");
       (match
          Gate.decide
            ~cycle_grant:grant
            ~keeper_always_allow:true
            (request
               ~input
               ~task_id:(Some "task-other")
               ~goal_ids:[ "goal-other" ])
          |> source_of
        with
        | Gate.One_shot_resolution actual_id ->
          Alcotest.(check string) "exact approval id" approval_id actual_id
        | Gate.Exact_always_rule _
        | Gate.Keeper_always_allow
        | Gate.Workspace_always_allow ->
          Alcotest.fail "exact effect did not consume its one-shot grant");
       (match
          Gate.decide
            ~cycle_grant:grant
            ~keeper_always_allow:true
            (request ~input ~task_id:None ~goal_ids:[])
          |> source_of
        with
        | Gate.Keeper_always_allow -> ()
        | Gate.One_shot_resolution _
        | Gate.Exact_always_rule _
        | Gate.Workspace_always_allow ->
          Alcotest.fail "one-shot grant was consumed more than once");
       (match
          Masc.Keeper_heartbeat_loop.settlement_of_cycle_outcome
            ~base_path
            ~settled_at:4.0
            ~stop_requested:false
            ~compaction_consecutive_failures:0
      ~transcript_quarantine_consecutive_retries:0
            ~lease
            None
        with
        | Masc.Keeper_registry_event_queue.Ack -> ()
        | _ -> Alcotest.fail "consumed grant wake was not acknowledged");
       AQ.For_testing.reset_runtime_state ();
       let _ = install_exn ~base_path in
       (match AQ.approved_resolution_state ~base_path ~id:approval_id with
        | Ok AQ.Resolution_consumed -> ()
        | Ok AQ.Resolution_unconsumed ->
          Alcotest.fail "consumed grant reappeared after restart"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       drop_resolution ~base_path ~keeper_name resolution)
;;

let test_v4_exact_binding_codec_validates_entry_identity () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id =
         submit
           ~base_path
           ~keeper_name:"queue-v4-exact-codec"
           ~input:(`Assoc [ "request", `String "codec" ])
       in
       check_update "mark exact codec pending" true (AQ.mark_summary_pending ~id);
       let identity = exact_identity id in
       let invalid_hashes =
         [ "malformed", String.make 63 'a' ^ "g"
         ; "uppercase", String.make 64 'A'
         ; "non-64", String.make 63 'a'
         ]
       in
       List.iter
         (fun (label, request_body_sha256_arg) ->
            let invalid = { identity with request_body_sha256_arg } in
            match run_exact_transition AQ.bind_summary_exact_attempt invalid with
            | Error
                (AQ.Exact_attempt_rejected
                  (AQ.Exact_attempt_invalid_identity "request_body_sha256")) ->
              ()
            | Error error ->
              Alcotest.failf
                "%s runtime hash returned the wrong error: %s"
                label
                (AQ.exact_attempt_error_to_string error)
            | Ok _ ->
              Alcotest.failf "%s runtime hash was accepted" label)
         invalid_hashes;
       check_exact_update
         "bind valid v4 identity"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt identity);
       let snapshot = read_pending_snapshot ~base_path in
       let open Yojson.Safe.Util in
       Alcotest.(check int) "v4 snapshot" 4 (snapshot |> member "version" |> to_int);
       let exact_json =
         snapshot
         |> member "pending"
         |> to_list
         |> List.hd
         |> member "exact_attempt"
       in
       (match AQ.exact_attempt_state_of_yojson_with_error exact_json with
        | Ok (AQ.Exact_bound binding) ->
          Alcotest.(check string)
            "codec approval identity"
            identity.approval_id_arg
            binding.approval_id;
          Alcotest.(check string)
            "codec input identity"
            identity.input_hash_arg
            binding.input_hash;
          Alcotest.(check int)
            "codec sequence identity"
            identity.sequence_arg
            binding.sequence
        | Ok _ -> Alcotest.fail "v4 bound exact attempt decoded as another state"
        | Error reason -> Alcotest.fail reason);
       let replace_field field value = function
         | `Assoc fields ->
           `Assoc ((field, value) :: List.remove_assoc field fields)
         | _ -> Alcotest.fail "exact attempt object expected"
       in
       (match
          AQ.exact_attempt_state_of_yojson_with_error
            (replace_field "call_id" (`String " ") exact_json)
        with
        | Error _ -> ()
        | Ok _ -> Alcotest.fail "blank exact call identity decoded");
       List.iter
         (fun (label, hash) ->
            match
              AQ.exact_attempt_state_of_yojson_with_error
                (replace_field
                   "request_body_sha256"
                   (`String hash)
                   exact_json)
            with
            | Error _ -> ()
            | Ok _ -> Alcotest.failf "%s codec hash was accepted" label)
         invalid_hashes;
       let mutate_snapshot field value =
         match snapshot with
         | `Assoc snapshot_fields ->
           let pending =
             match List.assoc_opt "pending" snapshot_fields with
             | Some (`List entries) ->
               `List
                 (List.map
                    (function
                      | `Assoc entry_fields ->
                        let exact_attempt =
                          List.assoc "exact_attempt" entry_fields
                          |> replace_field field value
                        in
                        `Assoc
                          (("exact_attempt", exact_attempt)
                           :: List.remove_assoc "exact_attempt" entry_fields)
                      | _ -> Alcotest.fail "pending entry object expected")
                    entries)
             | _ -> Alcotest.fail "pending list expected"
           in
           `Assoc
             (("pending", pending)
              :: List.remove_assoc "pending" snapshot_fields)
         | _ -> Alcotest.fail "snapshot object expected"
       in
       List.iter
         (fun (field, value) ->
            AQ.For_testing.reset_runtime_state ();
            write_pending_snapshot ~base_path (mutate_snapshot field value);
            match AQ.install_persistence ~base_path with
            | Error _ -> ()
            | Ok _ ->
              Alcotest.failf
                "v4 binding with mismatched %s installed"
                field)
         [ "approval_id", `String "different-approval"
         ; "input_hash", `String "different-input-hash"
         ; "sequence", `Int (identity.sequence_arg + 1)
         ])
;;

let test_exact_attempt_binding_release_and_conflicts () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id =
         submit
           ~base_path
           ~keeper_name:"queue-exact-binding"
           ~input:(`Assoc [ "request", `String "bind" ])
       in
       check_update "mark exact binding pending" true (AQ.mark_summary_pending ~id);
       let first = exact_identity id in
       check_exact_update
         "first exact bind"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt first);
       check_exact_update
         "same exact bind is idempotent"
         false
         (run_exact_transition AQ.bind_summary_exact_attempt first);
       let conflicting = { first with call_id_arg = "call-conflicting" } in
       (match run_exact_transition AQ.bind_summary_exact_attempt conflicting with
        | Error
            (AQ.Exact_attempt_rejected
              (AQ.Exact_attempt_identity_conflict _)) ->
          ()
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ -> Alcotest.fail "conflicting active exact identity was accepted");
       check_exact_update
         "release before dispatch"
         true
         (run_exact_transition
            AQ.release_summary_exact_attempt_before_dispatch
            first);
       check_exact_update
         "same release is idempotent"
         false
         (run_exact_transition
            AQ.release_summary_exact_attempt_before_dispatch
            first);
       (match run_exact_transition AQ.bind_summary_exact_attempt first with
        | Error
            (AQ.Exact_attempt_rejected
              (AQ.Exact_attempt_status_conflict _)) ->
          ()
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ -> Alcotest.fail "released identity rebound as a new attempt");
       let replacement =
         { first with
           slot_id_arg = "slot-replacement"
         ; call_id_arg = "call-replacement"
         ; plan_fingerprint_arg = "plan-replacement"
         ; request_body_sha256_arg = String.make 64 'b'
         }
       in
       check_exact_update
         "new identity replaces released attempt"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt replacement);
       let summary = exact_summary "bound-summary-rejection" in
       expect_summary_rejection
         "bound attach"
         `Bound
         (AQ.attach_summary ~id summary);
       expect_summary_rejection
         "bound fail"
         `Bound
         (AQ.mark_summary_failed
            ~id
            ~reason:"must remain exact"
            ~retryable:true);
       expect_summary_rejection
         "bound restart"
         `Bound
         (AQ.restart_failed_summary ~id);
       let quarantine_cause = AQ.Exact_post_dispatch_failure in
       check_exact_update
         "quarantine replacement"
         true
         (quarantine_exact replacement quarantine_cause);
       (match pending_entry_exn id with
        | { exact_attempt =
              AQ.Exact_bound
                { status =
                    AQ.Exact_quarantined
                      AQ.Exact_post_dispatch_failure
                ; _
                }
          ; _
          } ->
          ()
        | _ -> Alcotest.fail "quarantine cause was not durably typed");
       check_exact_update
         "same quarantine cause is idempotent"
         false
         (quarantine_exact replacement quarantine_cause);
       (match quarantine_exact replacement AQ.Exact_cancellation with
        | Error
            (AQ.Exact_attempt_rejected
              (AQ.Exact_attempt_status_conflict _)) ->
          ()
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ -> Alcotest.fail "different quarantine cause was accepted");
       (match
          run_exact_transition
            AQ.release_summary_exact_attempt_before_dispatch
            replacement
        with
        | Error
            (AQ.Exact_attempt_rejected
              (AQ.Exact_attempt_status_conflict _)) ->
          ()
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ -> Alcotest.fail "quarantined exact attempt was released"))
;;

let test_exact_attempt_final_predispatch_failure_requires_operator_restart () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id =
         submit
           ~base_path
           ~keeper_name:"queue-exact-predispatch-failure"
           ~input:(`Assoc [ "request", `String "fail-before-dispatch" ])
       in
       check_update
         "mark exact predispatch failure pending"
         true
         (AQ.mark_summary_pending ~id);
       let identity = exact_identity id in
       check_exact_update
         "bind exact predispatch failure"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt identity);
       List.iter
         (fun (field, wrong_identity) ->
            (match
               fail_exact_before_dispatch
                 wrong_identity
                 ~reason:"before dispatch"
                 ~retryable:true
             with
             | Error
                 (AQ.Exact_attempt_rejected
                   (AQ.Exact_attempt_identity_conflict _)) ->
               ()
             | Error error ->
               Alcotest.failf
                 "%s mismatch returned %s"
                 field
                 (AQ.exact_attempt_error_to_string error)
             | Ok _ ->
               Alcotest.failf "%s mismatch changed failure state" field);
            match pending_entry_exn id with
            | { summary_status = AQ.Summary_pending
              ; exact_attempt =
                  AQ.Exact_bound { status = AQ.Exact_dispatch_uncertain; _ }
              ; _
              } ->
              ()
            | _ ->
              Alcotest.failf "%s mismatch mutated the durable entry" field)
         [ "slot_id", { identity with slot_id_arg = "wrong-slot-id" }
         ; "call_id", { identity with call_id_arg = "wrong-call-id" }
         ; ( "plan_fingerprint"
           , { identity with plan_fingerprint_arg = "wrong-plan-fingerprint" } )
         ; ( "request_body_sha256"
           , { identity with request_body_sha256_arg = String.make 64 'c' } )
         ];
       check_exact_update
         "final before-dispatch failure"
         true
         (fail_exact_before_dispatch
            identity
            ~reason:"all exact slots failed before dispatch"
            ~retryable:true);
       (match pending_entry_exn id with
        | { summary_status =
              AQ.Summary_failed
                { reason = "all exact slots failed before dispatch"
                ; retryable = true
                }
          ; exact_attempt =
              AQ.Exact_bound
                { status = AQ.Exact_released_before_dispatch; _ }
          ; _
          } ->
          ()
        | _ ->
          Alcotest.fail
            "before-dispatch release and summary failure were not atomic");
       check_exact_update
         "same before-dispatch failure is idempotent"
         false
         (fail_exact_before_dispatch
            identity
            ~reason:"all exact slots failed before dispatch"
            ~retryable:true);
       let expect_failure_replay_conflict label result =
         match result with
         | Error
             (AQ.Exact_attempt_rejected
               (AQ.Exact_attempt_status_conflict _)) ->
           ()
         | Error error ->
           Alcotest.failf
             "%s returned %s"
             label
             (AQ.exact_attempt_error_to_string error)
         | Ok _ -> Alcotest.failf "%s replaced the first durable failure" label
       in
       expect_failure_replay_conflict
         "changed failure reason"
         (fail_exact_before_dispatch
            identity
            ~reason:"different failure reason"
            ~retryable:true);
       expect_failure_replay_conflict
         "changed retryable observation"
         (fail_exact_before_dispatch
            identity
            ~reason:"all exact slots failed before dispatch"
            ~retryable:false);
       (match pending_entry_exn id with
        | { summary_status =
              AQ.Summary_failed
                { reason = "all exact slots failed before dispatch"
                ; retryable = true
                }
          ; exact_attempt =
              AQ.Exact_bound
                { status = AQ.Exact_released_before_dispatch; _ }
          ; _
          } ->
          ()
        | _ -> Alcotest.fail "conflicting replay replaced the first failure");
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       (match pending_entry_exn id with
        | { summary_status =
              AQ.Summary_failed
                { reason = "all exact slots failed before dispatch"
                ; retryable = true
                }
          ; exact_attempt =
              AQ.Exact_bound
                { status = AQ.Exact_released_before_dispatch; _ }
          ; _
          } ->
          ()
        | _ ->
          Alcotest.fail
            "released exact failure did not survive codec round-trip");
       check_update
         "single operator restart"
         true
         (AQ.restart_failed_summary ~id);
       (match pending_entry_exn id with
        | { summary_status = AQ.Summary_pending
          ; exact_attempt = AQ.Exact_unbound
          ; _
          } ->
          ()
        | _ ->
          Alcotest.fail
            "single operator restart did not clear the released binding");
       let second_identity =
         exact_identity
           ~slot_id:"slot-restarted"
           ~call_id:"call-restarted"
           ~plan_fingerprint:"plan-restarted"
           ~request_body_sha256:(String.make 64 'b')
           id
       in
       check_exact_update
         "bind restarted exact attempt"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt second_identity);
       check_exact_update
         "fail restarted attempt before dispatch"
         true
         (fail_exact_before_dispatch
            second_identity
            ~reason:"restarted slot unavailable"
            ~retryable:false);
       (match AQ.restart_failed_summaries ~base_path with
        | Ok restarted_ids ->
          Alcotest.(check (list string))
            "bulk operator restart includes exact failure"
            [ id ]
            restarted_ids
        | Error error ->
          Alcotest.fail (AQ.summary_transition_error_to_string error));
       match pending_entry_exn id with
       | { summary_status = AQ.Summary_pending
         ; exact_attempt = AQ.Exact_unbound
         ; _
         } ->
         ()
       | _ ->
         Alcotest.fail
           "bulk operator restart did not clear the released binding")
;;

let test_dispatch_uncertain_restart_is_durably_quarantined () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id =
         submit
           ~base_path
           ~keeper_name:"queue-exact-restart"
           ~input:(`Assoc [ "request", `String "restart" ])
       in
       check_update "mark exact restart pending" true (AQ.mark_summary_pending ~id);
       let identity = exact_identity id in
       check_exact_update
         "bind dispatch-uncertain attempt"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt identity);
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       (match pending_entry_exn id with
        | { exact_attempt =
              AQ.Exact_bound
                { status =
                    AQ.Exact_quarantined
                      AQ.Exact_restart_uncertainty
                ; slot_id
                ; call_id
                ; _
                }
          ; _
          } ->
          Alcotest.(check string)
            "restart keeps slot identity"
            identity.slot_id_arg
            slot_id;
          Alcotest.(check string)
            "restart keeps call identity"
            identity.call_id_arg
            call_id
        | _ -> Alcotest.fail "dispatch-uncertain restart was not quarantined");
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "restart quarantine is persisted"
         "quarantined"
         (read_pending_snapshot ~base_path
          |> member "pending"
          |> to_list
          |> List.hd
          |> member "exact_attempt"
          |> member "status"
          |> to_string);
       Alcotest.(check string)
         "restart quarantine cause is persisted"
         "restart_uncertainty"
         (read_pending_snapshot ~base_path
          |> member "pending"
          |> to_list
          |> List.hd
          |> member "exact_attempt"
          |> member "quarantine_cause"
          |> to_string);
       (match
          run_exact_transition
            AQ.release_summary_exact_attempt_before_dispatch
            identity
        with
        | Error
            (AQ.Exact_attempt_rejected
              (AQ.Exact_attempt_status_conflict _)) ->
          ()
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ -> Alcotest.fail "restart-quarantined attempt was released"))
;;

let test_exact_attempt_completion_is_atomic () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id =
         submit
           ~base_path
           ~keeper_name:"queue-exact-completion"
           ~input:(`Assoc [ "request", `String "complete" ])
       in
       check_update "mark exact completion pending" true (AQ.mark_summary_pending ~id);
       let identity = exact_identity id in
       check_exact_update
         "bind completion attempt"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt identity);
       let mismatched_summary = exact_summary "different-call-id" in
       (match complete_exact identity mismatched_summary with
        | Error
            (AQ.Exact_attempt_rejected
              (AQ.Exact_attempt_provenance_mismatch
                { approval_id; expected_call_id; actual_model_run_id })) ->
          Alcotest.(check string) "provenance approval" id approval_id;
          Alcotest.(check string)
            "provenance expected call"
            identity.call_id_arg
            expected_call_id;
          Alcotest.(check string)
            "provenance actual model run"
            mismatched_summary.model_run_id
            actual_model_run_id
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ -> Alcotest.fail "mismatched completion provenance was accepted");
       (match pending_entry_exn id with
        | { summary_status = AQ.Summary_pending
          ; exact_attempt =
              AQ.Exact_bound { status = AQ.Exact_dispatch_uncertain; _ }
          ; _
          } ->
          ()
        | _ -> Alcotest.fail "provenance rejection mutated the exact attempt");
       let summary = exact_summary identity.call_id_arg in
       check_exact_update
         "complete exact attempt"
         true
         (complete_exact identity summary);
       (match pending_entry_exn id with
        | { summary_status = AQ.Summary_available durable_summary
          ; exact_attempt =
              AQ.Exact_bound { status = AQ.Exact_completed; _ }
          ; _
          } ->
          Alcotest.(check string)
            "summary and completion share one entry"
            summary.model_run_id
            durable_summary.model_run_id
        | _ -> Alcotest.fail "exact completion did not atomically store both fields");
       let open Yojson.Safe.Util in
       let persisted_entry =
         read_pending_snapshot ~base_path
         |> member "pending"
         |> to_list
         |> List.hd
       in
       Alcotest.(check string)
         "durable exact status"
         "completed"
         (persisted_entry
          |> member "exact_attempt"
          |> member "status"
          |> to_string);
       Alcotest.(check string)
         "durable summary from the same snapshot"
         summary.model_run_id
         (persisted_entry
          |> member "summary_status"
          |> member "summary"
          |> member "model_run_id"
          |> to_string);
       check_exact_update
         "same completion is idempotent"
         false
         (complete_exact identity summary);
       let conflicting =
         { summary with context_summary = "Conflicting exact summary" }
       in
       (match complete_exact identity conflicting with
        | Error
            (AQ.Exact_attempt_rejected
              (AQ.Exact_attempt_content_conflict actual)) ->
          Alcotest.(check string) "content conflict identity" id actual
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ -> Alcotest.fail "conflicting exact completion was accepted"))
;;

let test_exact_attempt_bind_storage_failure_is_not_success () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id =
         submit
           ~base_path
           ~keeper_name:"queue-exact-bind-storage-failure"
           ~input:(`Assoc [ "request", `String "bind" ])
       in
       check_update "mark storage failure pending" true (AQ.mark_summary_pending ~id);
       let identity = exact_identity id in
       let store_path = AQ.For_testing.pending_store_path ~base_path in
       Sys.remove store_path;
       Unix.mkdir store_path 0o755;
       (match run_exact_transition AQ.bind_summary_exact_attempt identity with
        | Error (AQ.Exact_attempt_storage_error _) -> ()
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ -> Alcotest.fail "failed exact binding persistence reported success");
       match pending_entry_exn id with
       | { exact_attempt = AQ.Exact_unbound; _ } -> ()
       | _ -> Alcotest.fail "failed exact binding persistence mutated memory")
;;

let test_exact_attempt_staged_durability_and_idempotent_rewrite () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let prepare label =
         let id =
           submit
             ~base_path
             ~keeper_name:("queue-exact-staged-" ^ label)
             ~input:(`Assoc [ "request", `String label ])
         in
         check_update
           ("mark " ^ label ^ " pending")
           true
           (AQ.mark_summary_pending ~id);
         id, exact_identity id
       in
       let assert_status label id expected =
         match pending_entry_exn id with
         | { exact_attempt = AQ.Exact_bound { status; _ }; _ } ->
           Alcotest.(check string)
             label
             expected
             (AQ.exact_attempt_status_to_string status)
         | _ -> Alcotest.failf "%s did not retain an exact binding" label
       in
       let bind_id, bind_identity = prepare "bind" in
       check_visible_update
         "visible bind"
         true
         (run_exact_transition_with_writer
            AQ.For_testing.bind_summary_exact_attempt_with_writer
            ~writer:visible_after_rename_writer
            bind_identity);
       assert_status "visible bind memory" bind_id "dispatch_uncertain";
       check_exact_update
         "idempotent bind confirms durability"
         false
         (run_exact_transition AQ.bind_summary_exact_attempt bind_identity);
       let before_id, before_identity = prepare "before-rename" in
       (match
          run_exact_transition_with_writer
            AQ.For_testing.bind_summary_exact_attempt_with_writer
            ~writer:before_rename_writer
            before_identity
        with
        | Error (AQ.Exact_attempt_storage_error _) -> ()
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ -> Alcotest.fail "pre-rename binding failure reported success");
       (match pending_entry_exn before_id with
        | { exact_attempt = AQ.Exact_unbound; _ } -> ()
        | _ -> Alcotest.fail "pre-rename failure mutated exact binding memory");
       let release_id, release_identity = prepare "release" in
       check_exact_update
         "bind release fixture"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt release_identity);
       check_visible_update
         "visible release"
         true
         (run_exact_transition_with_writer
            AQ.For_testing.release_summary_exact_attempt_before_dispatch_with_writer
            ~writer:visible_after_rename_writer
            release_identity);
       assert_status
         "visible release memory"
         release_id
         "released_before_dispatch";
       check_exact_update
         "idempotent release confirms durability"
         false
         (run_exact_transition
            AQ.release_summary_exact_attempt_before_dispatch
            release_identity);
       (match
          quarantine_exact release_identity AQ.Exact_post_dispatch_failure
        with
        | Error
            (AQ.Exact_attempt_rejected
              (AQ.Exact_attempt_status_conflict _)) ->
          ()
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ ->
          Alcotest.fail
            "released binding accepted an untyped terminalization cause");
       check_exact_update
         "typed release uncertainty terminalization"
         true
         (quarantine_exact
            release_identity
            AQ.Exact_terminal_persistence_failure);
       assert_status "release terminal memory" release_id "quarantined";
       let fail_id, fail_identity = prepare "fail" in
       check_exact_update
         "bind failure fixture"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt fail_identity);
       check_visible_update
         "visible predispatch failure"
         true
         (AQ.For_testing.fail_summary_exact_attempt_before_dispatch_with_writer
            ~save_file_atomic_strict_staged:visible_after_rename_writer
            ~id:fail_identity.approval_id_arg
            ~input_hash:fail_identity.input_hash_arg
            ~sequence:fail_identity.sequence_arg
            ~slot_id:fail_identity.slot_id_arg
            ~call_id:fail_identity.call_id_arg
            ~plan_fingerprint:fail_identity.plan_fingerprint_arg
            ~request_body_sha256:fail_identity.request_body_sha256_arg
            ~reason:"no usable exact slot"
            ~retryable:false);
       (match pending_entry_exn fail_id with
        | { exact_attempt =
              AQ.Exact_bound { status = AQ.Exact_released_before_dispatch; _ }
          ; summary_status = AQ.Summary_failed _
          ; _
          } ->
          ()
        | _ -> Alcotest.fail "visible failure did not converge memory");
       check_exact_update
         "idempotent failure confirms durability"
         false
         (fail_exact_before_dispatch
            fail_identity
            ~reason:"no usable exact slot"
            ~retryable:false);
       let quarantine_id, quarantine_identity = prepare "quarantine" in
       check_exact_update
         "bind quarantine fixture"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt quarantine_identity);
       check_visible_update
         "visible quarantine"
         true
         (AQ.For_testing.quarantine_summary_exact_attempt_with_writer
            ~save_file_atomic_strict_staged:visible_after_rename_writer
            ~id:quarantine_identity.approval_id_arg
            ~input_hash:quarantine_identity.input_hash_arg
            ~sequence:quarantine_identity.sequence_arg
            ~slot_id:quarantine_identity.slot_id_arg
            ~call_id:quarantine_identity.call_id_arg
            ~plan_fingerprint:quarantine_identity.plan_fingerprint_arg
            ~request_body_sha256:quarantine_identity.request_body_sha256_arg
            ~cause:AQ.Exact_post_dispatch_failure);
       assert_status
         "visible quarantine memory"
         quarantine_id
         "quarantined";
       check_exact_update
         "idempotent quarantine confirms durability"
         false
         (quarantine_exact
            quarantine_identity
            AQ.Exact_post_dispatch_failure);
       let complete_id, complete_identity = prepare "complete" in
       check_exact_update
         "bind completion fixture"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt complete_identity);
       let summary = exact_summary complete_identity.call_id_arg in
       check_visible_update
         "visible completion"
         true
         (AQ.For_testing.complete_summary_exact_attempt_with_writer
            ~save_file_atomic_strict_staged:visible_after_rename_writer
            ~id:complete_identity.approval_id_arg
            ~input_hash:complete_identity.input_hash_arg
            ~sequence:complete_identity.sequence_arg
            ~slot_id:complete_identity.slot_id_arg
            ~call_id:complete_identity.call_id_arg
            ~plan_fingerprint:complete_identity.plan_fingerprint_arg
            ~request_body_sha256:complete_identity.request_body_sha256_arg
            ~summary);
       assert_status "visible completion memory" complete_id "completed";
       check_exact_update
         "idempotent completion confirms durability"
         false
         (complete_exact complete_identity summary))
;;

let test_summary_updates_never_resolve_pending_request () =
  let base_path = temp_dir () in
  let keeper_name = "queue-summary-advisory" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let id = submit ~base_path ~keeper_name ~input:(`Assoc [ "request", `String "x" ]) in
       check_update "mark pending" true (AQ.mark_summary_pending ~id);
       check_update
         "duplicate judge worker rejected"
         false
         (AQ.mark_summary_pending ~id);
       let summary : AQ.hitl_context_summary =
         { summary_version = 2
         ; generated_at = Unix.gettimeofday ()
         ; model_run_id = "judge-run"
         ; context_summary = "The model recommends approval."
         ; key_questions = []
         ; judgment = AQ.Approve
         ; rationale = "Visible context supports the exact request."
         }
       in
       check_update "attach advisory judgment" true (AQ.attach_summary ~id summary);
       check_update "terminal summary cannot be replaced" false
         (AQ.attach_summary ~id { summary with judgment = AQ.Deny });
       check_update "terminal summary cannot become failure" false
         (AQ.mark_summary_failed ~id ~reason:"late failure" ~retryable:true);
       Alcotest.(check bool) "model judgment remains pending" true
         (Option.is_some (AQ.get_pending_entry ~id));
       Alcotest.(check bool) "resolved entry cannot be updated" true
         (match aq_resolve ~base_path ~id ~decision:(AQ.Decision.Reject "operator denied") with
          | Error error -> Alcotest.fail (AQ.resolve_error_to_string error)
          | Ok () ->
            (match AQ.attach_summary ~id summary with
             | Ok updated -> not updated
             | Error error ->
               Alcotest.fail (AQ.summary_transition_error_to_string error))))
;;

let test_all_summary_failures_accept_explicit_restart () =
  let base_path = temp_dir () in
  let keeper_name = "queue-summary-retry" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let retryable_id =
         submit ~base_path ~keeper_name ~input:(`Assoc [ "request", `String "retry" ])
       in
       let terminal_id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "request", `String "terminal" ])
       in
       List.iter
         (fun id -> check_update "mark pending" true (AQ.mark_summary_pending ~id))
         [ retryable_id; terminal_id ];
       check_update
         "retryable failure"
         true
         (AQ.mark_summary_failed
            ~id:retryable_id
            ~reason:"interrupted"
            ~retryable:true);
       check_update
         "nonretryable failure"
         true
         (AQ.mark_summary_failed
            ~id:terminal_id
            ~reason:"terminal"
            ~retryable:false);
       check_update
         "retryable diagnostic CAS restarts"
         true
         (AQ.restart_failed_summary ~id:retryable_id);
       check_update
         "nonretryable diagnostic does not block operator restart"
         true
         (AQ.restart_failed_summary ~id:terminal_id);
       (match AQ.get_pending_entry ~id:retryable_id with
       | Some { summary_status = AQ.Summary_pending; _ } -> ()
       | Some _ | None -> Alcotest.fail "retryable summary did not return to pending");
       (match AQ.get_pending_entry ~id:terminal_id with
        | Some { summary_status = AQ.Summary_pending; _ } -> ()
        | Some _ | None -> Alcotest.fail "operator restart was gated by diagnostic state");
       reject_and_cleanup ~base_path retryable_id;
       reject_and_cleanup ~base_path terminal_id)
;;

let test_operator_recovery_reopens_all_failed_summaries () =
  let base_path = temp_dir () in
  let keeper_name = "queue-summary-operator-recovery" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let request_context =
         `Assoc
           [ "history_messages", `List [ `String "exact prior evidence" ]
           ; "system_prompt", `String "exact judgment policy"
           ]
       in
       let retryable_id =
         submit_with_context
           ~request_context
           ~base_path
           ~keeper_name
           ~input:(`String "retryable")
           ()
       in
       let terminal_id =
         submit ~base_path ~keeper_name ~input:(`String "terminal")
       in
       List.iter
         (fun id -> check_update "mark pending" true (AQ.mark_summary_pending ~id))
         [ retryable_id; terminal_id ];
       check_update
         "retryable failure"
         true
         (AQ.mark_summary_failed ~id:retryable_id ~reason:"transport" ~retryable:true);
       check_update
         "terminal failure"
         true
         (AQ.mark_summary_failed ~id:terminal_id ~reason:"prompt" ~retryable:false);
       let reopened =
         match AQ.restart_failed_summaries ~base_path with
         | Ok ids -> List.sort String.compare ids
         | Error error ->
           Alcotest.fail (AQ.summary_transition_error_to_string error)
       in
       Alcotest.(check (list string))
         "explicit operator action reopens both classes"
         (List.sort String.compare [ retryable_id; terminal_id ])
         reopened;
       List.iter
         (fun id ->
            match AQ.get_pending_entry ~id with
            | Some { summary_status = AQ.Summary_not_requested; _ } -> ()
            | Some _ | None -> Alcotest.fail "failed summary was not reopened")
         reopened;
       (match AQ.get_pending_entry ~id:retryable_id with
        | Some entry ->
          Alcotest.check
            (Alcotest.option yojson)
            "operator recovery preserves exact request context"
            (Some request_context)
            entry.request_context
        | None -> Alcotest.fail "reopened summary disappeared");
       reject_and_cleanup ~base_path retryable_id;
       reject_and_cleanup ~base_path terminal_id)
;;

let test_dashboard_retry_rejects_cross_workspace_approval () =
  let base_a = temp_dir () in
  let base_b = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_a;
      cleanup_dir base_b)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path:base_a);
       let approval_id =
         submit
           ~base_path:base_a
           ~keeper_name:"queue-retry-base-a"
           ~input:(`Assoc [ "request", `String "base-a" ])
       in
       check_update "mark pending" true (AQ.mark_summary_pending ~id:approval_id);
       check_update
         "mark failed"
         true
         (AQ.mark_summary_failed
            ~id:approval_id
            ~reason:"base-a-original"
            ~retryable:true);
       let args = `Assoc [ "id", `String approval_id ] in
       (match
          Server_dashboard_http.dashboard_gate_retry_http_json
            ~base_path:base_b
            ~requested_by:"operator-b"
            ~args
        with
        | Error message ->
          Alcotest.(check string)
            "cross-workspace id is not addressable"
            ("pending approval not found: " ^ approval_id)
            message
        | Ok _ -> Alcotest.fail "workspace B retried workspace A approval");
       (match AQ.get_pending_entry ~id:approval_id with
        | Some
            { summary_status =
                AQ.Summary_failed { reason = "base-a-original"; retryable = true }
            ; _
            } ->
          ()
        | Some _ | None ->
          Alcotest.fail "cross-workspace retry changed workspace A state");
       reject_and_cleanup ~base_path:base_a approval_id)
;;

let test_dashboard_resolve_rejects_cross_workspace_approval () =
  let base_a = temp_dir () in
  let base_b = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_a;
      cleanup_dir base_b)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path:base_a);
       let approval_id =
         submit
           ~base_path:base_a
           ~keeper_name:"queue-resolve-base-a"
           ~input:(`Assoc [ "request", `String "base-a" ])
       in
       let resolve ~decision ~remember_rule =
         Server_dashboard_http.dashboard_gate_resolve_http_json
           ~base_path:base_b
           ~created_by:"operator-b"
           ~args:
             (`Assoc
                 [ "id", `String approval_id
                 ; "decision", `String decision
                 ; "remember_rule", `Bool remember_rule
                 ])
       in
       List.iter
         (fun (decision, remember_rule) ->
            match resolve ~decision ~remember_rule with
            | Error
                (Server_dashboard_http.Gone
                   (AQ.Not_found missing_id)) ->
              Alcotest.(check string)
                "cross-workspace id is indistinguishable from missing"
                approval_id
                missing_id
            | Error error ->
              Alcotest.fail
                (Server_dashboard_http.approval_resolve_http_error_to_string error)
            | Ok _ -> Alcotest.fail "workspace B resolved workspace A approval")
         [ "approve", true; "reject", false ];
       Alcotest.(check bool)
         "source approval remains pending"
         true
         (Option.is_some (AQ.get_pending_entry ~id:approval_id));
       List.iter
         (fun base_path ->
            Alcotest.(check bool)
              "cross-workspace resolve did not persist a rule"
              false
              (Sys.file_exists
                 (AQ.For_testing.always_allowed_store_path ~base_path)))
         [ base_a; base_b ];
       reject_and_cleanup ~base_path:base_a approval_id)
;;

let test_lane_activity_does_not_retry_failed_auto_judge () =
  let base_path = temp_dir () in
  let keeper_a = "queue-retry-lane-a" in
  let keeper_b = "queue-retry-lane-b" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let id_a =
         submit
           ~base_path
           ~keeper_name:keeper_a
           ~input:(`Assoc [ "request", `String "lane-a" ])
       in
       let id_b =
         submit
           ~base_path
           ~keeper_name:keeper_b
           ~input:(`Assoc [ "request", `String "lane-b" ])
       in
       List.iter
         (fun id -> check_update "mark pending" true (AQ.mark_summary_pending ~id))
         [ id_a; id_b ];
       check_update
         "lane a failed"
         true
         (AQ.mark_summary_failed ~id:id_a ~reason:"lane-a-original" ~retryable:true);
       check_update
         "lane b failed"
         true
         (AQ.mark_summary_failed ~id:id_b ~reason:"lane-b-original" ~retryable:true);
       let request : Gate.request =
         { keeper_name = keeper_a
         ; operation = "external-effect"
         ; input = `Assoc [ "request", `String "new-lane-a-activity" ]
         ; base_path
         ; causal_context = None
         ; task_id = None
         ; goal_ids = []
         ; continuation_channel = None
         }
       in
       (match Gate.decide ~keeper_always_allow:true request with
        | Gate.Allow { source = Gate.Keeper_always_allow } -> ()
        | Gate.Allow _ | Gate.Deferred _ | Gate.Unavailable _ ->
          Alcotest.fail "lane activity did not retain Keeper Always Allow");
       (match AQ.get_pending_entry ~id:id_a with
        | Some
            { summary_status = AQ.Summary_failed { reason; retryable = true }
            ; _
            } ->
          Alcotest.(check string)
            "same lane failure remains untouched"
            "lane-a-original"
            reason
        | Some _ | None -> Alcotest.fail "same-lane failure state is not observable");
       (match AQ.get_pending_entry ~id:id_b with
        | Some
            { summary_status =
                AQ.Summary_failed { reason = "lane-b-original"; retryable = true }
            ; _
            } ->
          ()
        | Some _ | None ->
          Alcotest.fail "lane activity changed another Keeper's judge failure");
       reject_and_cleanup ~base_path id_a;
       reject_and_cleanup ~base_path id_b;
       List.iter
         (fun (keeper_name, approval_id) ->
            match durable_resolution_opt ~base_path ~keeper_name ~approval_id with
            | Some resolution -> drop_resolution ~base_path ~keeper_name resolution
            | None -> Alcotest.fail "lane-local retry cleanup was not durable")
         [ keeper_a, id_a; keeper_b, id_b ])
;;

let test_decisive_summary_finalizes_after_restart () =
  let base_path = temp_dir () in
  let keeper_name = "queue-summary-finalize-restart" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "request", `String "finalize-after-restart" ])
       in
       check_update "mark pending" true (AQ.mark_summary_pending ~id);
       let summary : AQ.hitl_context_summary =
         { summary_version = 2
         ; generated_at = Unix.gettimeofday ()
         ; model_run_id = "judge-before-restart"
         ; context_summary = "The exact request is justified."
         ; key_questions = []
         ; judgment = AQ.Approve
         ; rationale = "Visible context supports this exact request."
         }
       in
       check_update "persist decisive summary" true (AQ.attach_summary ~id summary);
       AQ.For_testing.reset_runtime_state ();
       let _ = install_exn ~base_path in
       let report = Gate.resume_persisted_auto_judges ~base_path in
       Alcotest.(check int) "one recovery candidate" 1 report.requested;
       Alcotest.(check (list string)) "judgment finalized" [ id ] report.finalized_ids;
       Alcotest.(check int) "no worker restart" 0 (List.length report.started_ids);
       Alcotest.(check int) "no skipped recovery" 0 (List.length report.skipped_ids);
       Alcotest.(check int) "no recovery failure" 0 (List.length report.failures);
       Alcotest.(check bool) "pending removed" true
         (Option.is_none (AQ.get_pending_entry ~id));
       let resolution =
         match durable_resolution_opt ~base_path ~keeper_name ~approval_id:id with
         | Some resolution -> resolution
         | None -> Alcotest.fail "decisive summary did not reach origin Keeper"
       in
       drop_resolution ~base_path ~keeper_name resolution)
;;

let test_v3_inflight_auto_judge_becomes_legacy_quarantine () =
  let base_path = temp_dir () in
  let keeper_name = "queue-v3-legacy-quarantine" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "target", `String "legacy-restart" ])
       in
       check_update "legacy judge marked in flight" true (AQ.mark_summary_pending ~id);
       let v4_snapshot = read_pending_snapshot ~base_path in
       let v3_snapshot =
         match v4_snapshot with
         | `Assoc fields ->
           let pending =
             match List.assoc_opt "pending" fields with
             | Some (`List entries) ->
               `List
                 (List.map
                    (function
                      | `Assoc entry_fields ->
                        `Assoc (List.remove_assoc "exact_attempt" entry_fields)
                      | _ -> Alcotest.fail "legacy pending entry object expected")
                    entries)
             | _ -> Alcotest.fail "legacy pending list expected"
           in
           `Assoc
             (("version", `Int 3)
              :: ("pending", pending)
              :: (fields
                  |> List.remove_assoc "version"
                  |> List.remove_assoc "pending"))
         | _ -> Alcotest.fail "legacy snapshot object expected"
       in
       AQ.For_testing.reset_runtime_state ();
       write_pending_snapshot ~base_path v3_snapshot;
       Alcotest.(check int) "process state cleared" 0 (List.length (AQ.list_pending_entries ()));
       let report = install_exn ~base_path in
       Alcotest.(check int) "one pending restored" 1 report.loaded_pending;
       Alcotest.(check int) "no delivery replay" 0 report.replayed_deliveries;
       Alcotest.(check int)
         "no delivery replay failure"
         0
         (List.length report.delivery_replay_failures);
       (match AQ.get_pending_entry ~id with
        | None -> Alcotest.fail "same approval id was not restored"
        | Some
            { summary_status = AQ.Summary_pending
            ; exact_attempt = AQ.Legacy_execution_uncertain
            ; _
            } ->
          ()
        | Some _ ->
          Alcotest.fail "v3 in-flight summary was not visibly quarantined");
       let open Yojson.Safe.Util in
       let persisted = read_pending_snapshot ~base_path in
       Alcotest.(check int) "legacy snapshot migrated to v4" 4
         (persisted |> member "version" |> to_int);
       Alcotest.(check string)
         "legacy execution uncertainty is durable"
         "legacy_execution_uncertain"
         (persisted
          |> member "pending"
          |> to_list
          |> List.hd
          |> member "exact_attempt"
          |> member "state"
          |> to_string);
       let summary = exact_summary "legacy-rejected-summary" in
       expect_summary_rejection
         "legacy attach"
         `Legacy
         (AQ.attach_summary ~id summary);
       expect_summary_rejection
         "legacy fail"
         `Legacy
         (AQ.mark_summary_failed
            ~id
            ~reason:"legacy execution uncertain"
            ~retryable:true);
       expect_summary_rejection
         "legacy restart"
         `Legacy
         (AQ.restart_failed_summary ~id);
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let identity = exact_identity id in
       (match pending_entry_exn id with
        | { exact_attempt = AQ.Legacy_execution_uncertain; _ } -> ()
        | _ -> Alcotest.fail "second restart changed legacy quarantine to unbound");
       (match run_exact_transition AQ.bind_summary_exact_attempt identity with
        | Error
            (AQ.Exact_attempt_rejected
              (AQ.Exact_attempt_legacy_execution_uncertain actual)) ->
          Alcotest.(check string) "legacy bind rejection identity" id actual
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ -> Alcotest.fail "legacy execution uncertainty rebound");
       reject_and_cleanup ~base_path id;
       (match durable_resolution_opt ~base_path ~keeper_name ~approval_id:id with
        | Some resolution -> drop_resolution ~base_path ~keeper_name resolution
        | None -> Alcotest.fail "cleanup resolution was not durable"))
;;

let test_malformed_snapshot_fails_install_and_is_observed () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       write_pending_snapshot
         ~base_path
         (`Assoc
            [ "version", `Int 3
            ; "next_sequence", `Int 1
            ; "pending", `List [ `String "malformed-entry" ]
            ; "deliveries", `List []
            ]);
       let before =
         Masc.Otel_metric_store.metric_value_or_zero
           Masc.Otel_metric_store.metric_persistence_read_drops
           ~labels:[ "surface", "keeper_gate_pending"; "reason", "invalid_payload" ]
           ()
       in
       (match AQ.install_persistence ~base_path with
        | Ok _ -> Alcotest.fail "malformed snapshot must not install"
       | Error (AQ.Install_storage_failed _) -> ()
        );
       Alcotest.(check int) "no partial install" 0 (List.length (AQ.list_pending_entries ()));
       (match
          AQ.submit_pending
            ~keeper_name:"queue-invalid-store"
            ~tool_name:"external-effect"
            ~input:(`Assoc [ "target", `String "must-not-overwrite" ])
            ~base_path
            ()
        with
        | Error _ -> ()
        | Ok _ -> Alcotest.fail "an invalid installed store must remain unavailable");
       let persisted = read_pending_snapshot ~base_path in
       Alcotest.(check bool) "invalid store is not overwritten" true
         (Yojson.Safe.equal
            persisted
            (`Assoc
               [ "version", `Int 3
               ; "next_sequence", `Int 1
               ; "pending", `List [ `String "malformed-entry" ]
               ; "deliveries", `List []
               ]));
       let after =
         Masc.Otel_metric_store.metric_value_or_zero
           Masc.Otel_metric_store.metric_persistence_read_drops
           ~labels:[ "surface", "keeper_gate_pending"; "reason", "invalid_payload" ]
           ()
       in
       Alcotest.(check bool) "malformed snapshot observed" true (after -. before >= 1.0))
;;

let test_unsupported_version_snapshot_is_quarantined_and_store_starts_fresh () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       write_pending_snapshot
         ~base_path
         (`Assoc
            [ "version", `Int 2
            ; "pending", `List []
            ; "deliveries", `List []
            ]);
       (match AQ.install_persistence ~base_path with
        | Ok _ -> ()
        | Error _ ->
          Alcotest.fail "unsupported version must quarantine, not fail install");
       let store_path = AQ.For_testing.pending_store_path ~base_path in
       Alcotest.(check bool) "original moved away" false
         (Sys.file_exists store_path);
       let quarantine_path = store_path ^ ".v2.quarantine" in
       Alcotest.(check bool) "quarantine file exists" true
         (Sys.file_exists quarantine_path);
       let preserved = Yojson.Safe.from_file quarantine_path in
       Alcotest.(check bool) "content preserved verbatim" true
         (Yojson.Safe.equal
            preserved
            (`Assoc
               [ "version", `Int 2
               ; "pending", `List []
               ; "deliveries", `List []
               ]));
       let id =
         submit ~base_path ~keeper_name:"queue-quarantine"
           ~input:(`Assoc [ "target", `String "after-quarantine" ])
       in
       Alcotest.(check int) "fresh generation starts at sequence 1" 1
         (pending_entry_exn id).sequence)
;;

let test_quarantine_name_collision_uses_next_free_name () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       let store_path = AQ.For_testing.pending_store_path ~base_path in
       write_pending_snapshot
         ~base_path
         (`Assoc
            [ "version", `Int 2
            ; "pending", `List []
            ; "deliveries", `List []
            ]);
       let occupied = store_path ^ ".v2.quarantine" in
       ensure_dir (Filename.dirname occupied);
       Out_channel.with_open_text occupied (fun channel ->
         output_string channel "prior quarantine");
       (match AQ.install_persistence ~base_path with
        | Ok _ -> ()
        | Error _ -> Alcotest.fail "install must quarantine");
       Alcotest.(check bool) "prior quarantine kept" true
         (Sys.file_exists occupied);
       Alcotest.(check bool) "next free name used" true
         (Sys.file_exists (store_path ^ ".v2.quarantine.1")))
;;

let test_unreadable_json_snapshot_is_not_quarantined () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       let store_path = AQ.For_testing.pending_store_path ~base_path in
       ensure_dir (Filename.dirname store_path);
       Out_channel.with_open_text store_path (fun channel ->
         output_string channel "{not-json");
       (match AQ.install_persistence ~base_path with
        | Ok _ -> Alcotest.fail "unreadable snapshot must not install"
        | Error _ -> ());
       Alcotest.(check bool) "file left in place" true
         (Sys.file_exists store_path);
       Alcotest.(check bool) "no quarantine created" false
         (Sys.file_exists (store_path ^ ".v2.quarantine")))
;;

let test_persisted_delivery_replays_before_origin_wake () =
  let base_path = temp_dir () in
  let keeper_name = "queue-replay-origin" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "target", `String "replay" ])
       in
       let pending_entry =
         match read_pending_snapshot ~base_path with
         | `Assoc fields ->
           (match List.assoc_opt "pending" fields with
            | Some (`List [ entry ]) -> entry
            | _ -> Alcotest.fail "expected one persisted pending entry")
         | _ -> Alcotest.fail "expected pending snapshot object"
       in
       write_pending_snapshot
         ~base_path
         (`Assoc
            [ "version", `Int 3
            ; "next_sequence", `Int 2
            ; "pending", `List []
            ; ( "deliveries"
              , `List
                  [ `Assoc
                      [ "entry", pending_entry
                      ; "decision", `Assoc [ "kind", `String "approve" ]
                      ; "source", `String "human_operator"
                      ; "remember_rule", `Bool false
                      ; "created_by", `Null
                      ; "grant_consumed", `Bool false
                      ]
                  ] )
            ]);
       AQ.For_testing.reset_runtime_state ();
       let report = install_exn ~base_path in
       Alcotest.(check int) "no pending restored" 0 report.loaded_pending;
       Alcotest.(check int) "delivery replayed" 1 report.replayed_deliveries;
       let resolution =
         match durable_resolution_opt ~base_path ~keeper_name ~approval_id:id with
         | Some resolution -> resolution
         | None -> Alcotest.fail "replayed delivery did not reach origin queue"
       in
       let open Yojson.Safe.Util in
       let snapshot = read_pending_snapshot ~base_path in
       Alcotest.(check int) "unconsumed delivery remains journaled" 1
         (snapshot |> member "deliveries" |> to_list |> List.length);
       (match
          AQ.consume_approved_resolution
            ~base_path
            ~id
            ~keeper_name
            ~tool_name:"external-effect"
            ~input:(`Assoc [ "target", `String "replay" ])
        with
        | Ok AQ.Consumption_committed -> ()
        | Ok (AQ.Consumption_already_committed | AQ.Consumption_not_matching) ->
          Alcotest.fail "replayed exact grant was not consumed"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       let snapshot = read_pending_snapshot ~base_path in
       Alcotest.(check int) "consumption tombstone remains explicit" 1
         (snapshot |> member "deliveries" |> to_list |> List.length);
       Alcotest.(check bool) "consumption tombstone is committed" true
         (snapshot
          |> member "deliveries"
          |> to_list
          |> List.hd
          |> member "grant_consumed"
          |> to_bool);
       drop_resolution ~base_path ~keeper_name resolution)
;;

let test_one_delivery_replay_failure_does_not_stop_others () =
  let base_path = temp_dir () in
  let keeper_name = "queue-independent-replay" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let first_id, second_id, successful_id =
         List.init 3 (fun index ->
           submit ~base_path ~keeper_name ~input:(`Assoc [ "target", `Int index ]))
         |> List.sort (fun left right -> String.compare right left)
         |> function
         | [ first; second; third ] -> first, second, third
         | _ -> Alcotest.fail "three approvals expected"
       in
       let pending_entries =
         let open Yojson.Safe.Util in
         read_pending_snapshot ~base_path |> member "pending" |> to_list
       in
       let entry_for id =
         let open Yojson.Safe.Util in
         match
           List.find_opt
             (fun json -> String.equal (json |> member "id" |> to_string) id)
             pending_entries
         with
         | Some entry -> entry
         | None -> Alcotest.fail ("missing persisted entry " ^ id)
       in
       let entry_at sequence id =
         match entry_for id with
         | `Assoc fields ->
           `Assoc (("sequence", `Int sequence) :: List.remove_assoc "sequence" fields)
         | _ -> Alcotest.fail "persisted entry object expected"
       in
       write_pending_snapshot
         ~base_path
         (`Assoc
            [ "version", `Int 3
            ; "next_sequence", `Int 4
            ; "pending", `List []
            ; ( "deliveries"
              , `List
                  [ delivery_json
                      ~entry:(entry_at 1 first_id)
                      ~remember_rule:true
                  ; delivery_json
                      ~entry:(entry_at 2 second_id)
                      ~remember_rule:true
                  ; delivery_json
                      ~entry:(entry_at 3 successful_id)
                      ~remember_rule:false
                  ] )
            ]);
       let rules_path = AQ.For_testing.always_allowed_store_path ~base_path in
       ensure_dir (Filename.dirname rules_path);
       Unix.mkdir rules_path 0o755;
       AQ.For_testing.reset_runtime_state ();
       let report = install_exn ~base_path in
       Alcotest.(check int) "independent delivery replayed" 1 report.replayed_deliveries;
       Alcotest.(check int)
         "two replay failures reported"
         2
         (List.length report.delivery_replay_failures);
       Alcotest.(check (list string))
         "replay failures preserve durable sequence"
         [ first_id; second_id ]
         (List.map (fun failure -> failure.AQ.approval_id) report.delivery_replay_failures);
       Alcotest.(check bool) "later delivery reached origin" true
         (Option.is_some
            (durable_resolution_opt
               ~base_path
               ~keeper_name
               ~approval_id:successful_id));
       List.iter
         (fun approval_id ->
            match durable_resolution_opt ~base_path ~keeper_name ~approval_id with
            | Some resolution -> drop_resolution ~base_path ~keeper_name resolution
            | None -> ())
         [ first_id; second_id; successful_id ])
;;

let test_submit_surfaces_storage_failure () =
  let base_path = Filename.temp_file "queue-storage-error" "" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      try Sys.remove base_path with
      | Sys_error _ -> ())
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       match
         AQ.submit_pending
           ~keeper_name:"queue-storage-error"
           ~tool_name:"external-effect"
           ~input:(`Assoc [ "target", `String "x" ])
           ~base_path
           ()
       with
       | Ok _ -> Alcotest.fail "submission must not succeed without durable storage"
       | Error _ -> Alcotest.(check int) "memory not mutated" 0 (List.length (AQ.list_pending_entries ())))
;;

let test_default_auto_judge_defers_without_blocking () =
  let base_path = temp_dir () in
  let keeper_name = "queue-default-auto-judge" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let request : Gate.request =
         { keeper_name
         ; operation = "external-effect"
         ; input = `Assoc [ "target", `String "auto-judge" ]
         ; base_path
         ; causal_context =
             Some { Gate.turn_id = Some 9; snapshot = `Assoc [] }
         ; task_id = Some "task-auto-judge"
         ; goal_ids = [ "goal-auto-judge" ]
         ; continuation_channel = None
         }
       in
       match Gate.decide ~keeper_always_allow:false request with
       | Gate.Deferred { approval_id; reason = Gate.Auto_judge_unavailable detail } ->
         Alcotest.(check bool) "unavailable reason is explicit" true
           (String.length detail > 0);
         (match AQ.get_pending_entry ~id:approval_id with
          | Some { summary_status = AQ.Summary_failed { retryable = true; _ }; _ } ->
            ()
          | Some _ -> Alcotest.fail "Auto Judge failure was not durably retryable"
          | None -> Alcotest.fail "Auto Judge request was not durably queued");
         reject_and_cleanup ~base_path approval_id
       | Gate.Deferred { reason = Gate.Judge_requested; _ } ->
         Alcotest.fail "test unexpectedly has a running server Auto Judge context"
       | Gate.Deferred { reason = (Gate.Human_requested | Gate.Mode_state_invalid _); _ } ->
         Alcotest.fail "default Gate mode did not select Auto Judge"
       | Gate.Allow _ -> Alcotest.fail "default Auto Judge allowed without a verdict"
       | Gate.Unavailable reason ->
         Alcotest.fail (Gate.unavailable_reason_to_string reason))
;;

let test_unavailable_cycle_grant_never_falls_through () =
  let base_path = temp_dir () in
  let keeper_name = "queue-stale-grant" in
  let input = `Assoc [ "target", `String "exact" ] in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let approval_id = submit ~base_path ~keeper_name ~input in
       (match aq_resolve ~base_path ~id:approval_id ~decision:AQ.Decision.Approve with
        | Ok () -> ()
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error));
       let resolution =
         durable_resolution_opt ~base_path ~keeper_name ~approval_id
         |> require_some "approved resolution was not delivered"
       in
       let grant =
         Gate.cycle_grant_of_resolution resolution
         |> require_some "approved resolution lacked grant"
       in
       let request : Gate.request =
         { keeper_name
         ; operation = "external-effect"
         ; input
         ; base_path
         ; causal_context = None
         ; task_id = None
         ; goal_ids = []
         ; continuation_channel = None
         }
       in
       AQ.For_testing.reset_runtime_state ();
       (match Gate.decide ~cycle_grant:grant ~keeper_always_allow:true request with
        | Gate.Unavailable (Gate.Approval_grant_unavailable _) -> ()
        | Gate.Allow _ ->
          Alcotest.fail "unconsumed grant failure fell through to Always Allow"
        | Gate.Deferred _ ->
          Alcotest.fail "unconsumed grant failure created a second approval"
        | Gate.Unavailable _ ->
          Alcotest.fail "unexpected unavailable reason for unreadable grant");
       ignore (install_exn ~base_path);
       (match Gate.decide ~cycle_grant:grant ~keeper_always_allow:false request with
        | Gate.Allow { source = Gate.One_shot_resolution actual } ->
          Alcotest.(check string) "grant remains unconsumed" approval_id actual
        | Gate.Allow _ -> Alcotest.fail "restored exact grant used the wrong source"
        | Gate.Deferred _ -> Alcotest.fail "restored exact grant did not authorize"
        | Gate.Unavailable reason ->
          Alcotest.fail (Gate.unavailable_reason_to_string reason));
       drop_resolution ~base_path ~keeper_name resolution)
;;

let test_nonapproved_resolution_payload_is_delivered () =
  let base_path = temp_dir () in
  let keeper_name = "queue-resolution-payload" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let reject_id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "target", `String "reject" ])
       in
       let rationale = "Use the project-scoped target." in
       (match
          aq_resolve
            ~base_path
            ~id:reject_id
            ~decision:(AQ.Decision.Reject rationale)
        with
        | Ok () -> ()
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error));
       let rejected =
         durable_resolution_opt
           ~base_path
           ~keeper_name
           ~approval_id:reject_id
         |> require_some "rejection resolution was not delivered"
       in
       (match rejected.decision with
        | Keeper_event_queue.Hitl_rejected actual ->
          Alcotest.(check string) "rejection rationale" rationale actual
        | _ -> Alcotest.fail "rejection resolution lost its typed decision");
       Alcotest.(check bool)
         "rejection is not a grant"
         true
         (Option.is_none (Gate.cycle_grant_of_resolution rejected));
       let edit_id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "target", `String "before" ])
       in
       let edited_input =
         `Assoc [ "target", `String "after"; "confirmed", `Bool true ]
       in
       (match aq_resolve ~base_path ~id:edit_id ~decision:(AQ.Decision.Edit edited_input) with
        | Ok () -> ()
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error));
       let edited =
         durable_resolution_opt ~base_path ~keeper_name ~approval_id:edit_id
         |> require_some "edited resolution was not delivered"
       in
       (match edited.decision with
        | Keeper_event_queue.Hitl_edited actual ->
          Alcotest.(check bool)
            "edited input"
            true
            (Yojson.Safe.equal edited_input actual)
        | _ -> Alcotest.fail "edited resolution lost its typed input");
       Alcotest.(check bool)
         "edit is not a grant"
         true
         (Option.is_none (Gate.cycle_grant_of_resolution edited));
       drop_resolution ~base_path ~keeper_name rejected;
       drop_resolution ~base_path ~keeper_name edited)
;;

let () =
  Alcotest.run
    "Keeper_approval_queue"
    [ ( "nonhierarchical queue"
      , [ Alcotest.test_case
            "durable lock serializes Eio fibers"
            `Quick
            test_pending_store_lock_serializes_eio_fibers
        ; Alcotest.test_case
            "install serializes snapshot read with mutation"
            `Quick
            test_install_serializes_snapshot_read_with_same_base_mutation
        ; Alcotest.test_case
            "submit is nonblocking and exact"
            `Quick
            test_submit_is_nonblocking_and_exactly_deduplicated
        ; Alcotest.test_case
            "unversioned context is never replayed as exact"
            `Quick
            test_unversioned_request_context_is_not_replayed_as_exact
        ; Alcotest.test_case
            "durable sequence survives restart"
            `Quick
            test_monotonic_sequence_survives_restart
        ; Alcotest.test_case
            "same owner drains by durable sequence"
            `Quick
            test_same_owner_drain_uses_sequence_not_wall_clock
        ; Alcotest.test_case
            "different owners activate in parallel"
            `Quick
            test_different_owners_claim_in_parallel
        ; Alcotest.test_case
            "dedup keeps distinct origins"
            `Quick
            test_dedup_never_merges_distinct_origins
        ; Alcotest.test_case
            "resolution wakes only origin"
            `Quick
            test_resolution_is_durable_and_origin_scoped
        ; Alcotest.test_case
            "remembered rule carries requested expiry"
            `Quick
            test_remembered_rule_carries_requested_expiry
        ; Alcotest.test_case
            "cycle grant binds origin and is consumed once"
            `Quick
            test_cycle_grant_uses_exact_effect_and_is_consumed_once
        ; Alcotest.test_case
            "summary is advisory"
            `Quick
            test_summary_updates_never_resolve_pending_request
        ; Alcotest.test_case
            "v4 exact binding codec validates entry identity"
            `Quick
            test_v4_exact_binding_codec_validates_entry_identity
        ; Alcotest.test_case
            "exact binding release and conflicts"
            `Quick
            test_exact_attempt_binding_release_and_conflicts
        ; Alcotest.test_case
            "final predispatch failure requires operator restart"
            `Quick
            test_exact_attempt_final_predispatch_failure_requires_operator_restart
        ; Alcotest.test_case
            "dispatch-uncertain restart is quarantined"
            `Quick
            test_dispatch_uncertain_restart_is_durably_quarantined
        ; Alcotest.test_case
            "exact completion is atomic"
            `Quick
            test_exact_attempt_completion_is_atomic
          ; Alcotest.test_case
              "exact bind storage failure is not success"
              `Quick
              test_exact_attempt_bind_storage_failure_is_not_success
          ; Alcotest.test_case
              "exact staged durability converges and rewrites"
              `Quick
              test_exact_attempt_staged_durability_and_idempotent_rewrite
          ; Alcotest.test_case
            "all summary failures accept explicit operator restart"
            `Quick
            test_all_summary_failures_accept_explicit_restart
        ; Alcotest.test_case
            "dashboard retry rejects cross-workspace approval"
            `Quick
            test_dashboard_retry_rejects_cross_workspace_approval
        ; Alcotest.test_case
            "dashboard resolve rejects cross-workspace approval"
            `Quick
            test_dashboard_resolve_rejects_cross_workspace_approval
        ; Alcotest.test_case
            "lane activity never retries a failed Auto Judge"
            `Quick
            test_lane_activity_does_not_retry_failed_auto_judge
        ; Alcotest.test_case
            "operator recovery reopens terminal failures"
            `Quick
            test_operator_recovery_reopens_all_failed_summaries
        ; Alcotest.test_case
            "decisive summary finalizes after restart"
            `Quick
            test_decisive_summary_finalizes_after_restart
        ; Alcotest.test_case
            "v3 in-flight judge becomes legacy quarantine"
            `Quick
            test_v3_inflight_auto_judge_becomes_legacy_quarantine
        ; Alcotest.test_case
            "malformed snapshot is explicit"
            `Quick
            test_malformed_snapshot_fails_install_and_is_observed
        ; Alcotest.test_case
            "unsupported version quarantines and restarts fresh"
            `Quick
            test_unsupported_version_snapshot_is_quarantined_and_store_starts_fresh
        ; Alcotest.test_case
            "quarantine name collision uses next free name"
            `Quick
            test_quarantine_name_collision_uses_next_free_name
        ; Alcotest.test_case
            "unreadable json is not quarantined"
            `Quick
            test_unreadable_json_snapshot_is_not_quarantined
        ; Alcotest.test_case
            "delivery journal replays"
            `Quick
            test_persisted_delivery_replays_before_origin_wake
        ; Alcotest.test_case
            "one replay failure does not stop others"
            `Quick
            test_one_delivery_replay_failure_does_not_stop_others
        ; Alcotest.test_case
            "storage failure is returned"
            `Quick
            test_submit_surfaces_storage_failure
        ; Alcotest.test_case
            "default Auto Judge defers without blocking"
            `Quick
            test_default_auto_judge_defers_without_blocking
        ; Alcotest.test_case
            "unavailable grant never falls through"
            `Quick
            test_unavailable_cycle_grant_never_falls_through
        ; Alcotest.test_case
            "non-approved resolution payload is delivered"
            `Quick
            test_nonapproved_resolution_payload_is_delivered
        ] )
    ]
;;
