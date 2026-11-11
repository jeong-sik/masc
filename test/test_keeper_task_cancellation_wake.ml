(** A committed cancellation reaches the Keeper that authored the Task.

    Cancellation is the one terminal Task outcome with no Board projection. On
    the reference workspace 46 of 56 cancellations had a canceller different
    from the author, so every one of those reasons was written and never read.

    These tests drive [notify_author] against a real workspace and read the
    author's durable event queue, so a delivery that stops at the enqueue
    boundary, or a self-cancellation that wakes a Keeper about its own
    decision, is a failure. *)

open Alcotest
module D = Masc_domain
module Workspace = Masc.Workspace
module Keeper_meta_store = Masc.Keeper_meta_store
module Wake = Masc.Keeper_task_cancellation_wake
module Event_queue = Keeper_event_queue

let now = "2026-08-04T00:00:00Z"

let with_workspace f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc_cancel_wake_%d_%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir dir 0o755;
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace.default_config dir in
  ignore (Workspace.init config ~agent_name:(Some "operator"));
  Fun.protect
    ~finally:(fun () -> ignore (Workspace.reset config))
    (fun () -> f config)
;;

let ensure_keeper config ~keeper_name =
  match
    Result.bind
      (Masc_test_deps.meta_of_json_fixture
         (`Assoc
             [ "name", `String keeper_name
             ; "activation_mode", `String "manual"
             ]))
      (Keeper_meta_store.replace_snapshot config)
  with
  | Ok _ -> ()
  | Error err -> fail ("write keeper meta failed: " ^ err)
;;

let seed_task ?handoff_context config ~task_id ~created_by ~status =
  let task : D.task =
    { id = task_id
    ; title = "cancelled work"
    ; description = "desc"
    ; task_status = status
    ; priority = 3
    ; files = []
    ; created_at = now
    ; created_by
    ; predecessor_task_id = None
    ; contract = None
    ; handoff_context
    ; cycle_count = 0
    ; execution_links = Masc_domain.no_execution_links
    ; skills = []
    }
  in
  Workspace_backlog.write_backlog
    config
    { tasks = [ task ]; task_creation_receipts = []; task_deletion_receipts = []; pending_completion_approvals = []; pending_completion_rejections = []; delivered_completion_rejections = []; last_updated = now; version = 1 }
;;

let cancelled ~by ~reason =
  D.Cancelled { cancelled_by = by; cancelled_at = now; reason }
;;

let load_queue ~base_path ~keeper_name =
  match Keeper_event_queue_persistence.load_result ~base_path ~keeper_name with
  | Ok queue -> queue
  | Error detail -> fail ("event queue load failed: " ^ detail)
;;

let queued_cancellations ~base_path ~keeper_name =
  load_queue ~base_path ~keeper_name
  |> Event_queue.to_list
  |> List.filter_map (fun (stimulus : Event_queue.stimulus) ->
    match stimulus.payload with
    | Event_queue.Task_cancelled cancellation -> Some cancellation
    | Event_queue.Board_signal _
    | Event_queue.Board_routing_pending _ | Event_queue.Board_attention _
    | Event_queue.Bootstrap
    | Event_queue.Fusion_completed _
    | Event_queue.Schedule_due _
    | Event_queue.Connector_attention _
    | Event_queue.Hitl_resolved _
    | Event_queue.Ask_answered _
    | Event_queue.Completion_authority_rejected _
    | Event_queue.Task_outcome _
    | Event_queue.Workspace_message _
    | Event_queue.Delegate_completed _
    | Event_queue.Tool_result_ready _ | Event_queue.Owned_job_completed _
    | Event_queue.Composition_completed _ -> None)
;;

let committed_task config task_id =
  match Workspace_backlog.read_backlog_r config with
  | Error detail -> fail detail
  | Ok backlog ->
    match List.find_opt (fun (task : D.task) -> String.equal task.id task_id) backlog.tasks with
    | Some task -> task
    | None -> fail "committed Task fixture is absent"
;;

let test_cross_keeper_cancellation_is_delivered () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:"alpha";
    ensure_keeper config ~keeper_name:"beta";
    seed_task
      config
      ~task_id:"task-161"
      ~created_by:(Some "alpha")
      ~status:
        (cancelled
           ~by:"beta"
           ~reason:(Some "BLOCKED: service absent from sandbox"));
    let outcome =
      Wake.notify_author
        ~config
        ~actor:(Workspace_hooks.Task_terminal_agent "beta")
        ~task:(committed_task config "task-161")
    in
    check string "delivered to the author's lane" "delivered" (Wake.outcome_label outcome);
    match queued_cancellations ~base_path:config.base_path ~keeper_name:"alpha" with
    | [ cancellation ] ->
      check string "task id" "task-161" cancellation.Event_queue.tc_task_id;
      check string "canceller" "beta" cancellation.tc_cancelled_by;
      check
        (option string)
        "the reason travels with the wake"
        (Some "BLOCKED: service absent from sandbox")
        cancellation.tc_reason
    | queued ->
      failf "expected one queued cancellation, got %d" (List.length queued))
;;

(* RFC-0393: the keeper cancels under its own keeper_name — there is no
   other spelling of the same identity. *)
let test_self_cancellation_is_silent () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:"alpha";
    seed_task
      config
      ~task_id:"task-155"
      ~created_by:(Some "alpha")
      ~status:(cancelled ~by:"alpha" ~reason:(Some "focus change"));
    let outcome =
      Wake.notify_author ~config
        ~actor:(Workspace_hooks.Task_terminal_agent "alpha") ~task:(committed_task config "task-155")
    in
    check string "recognised as self-cancellation" "self_cancelled"
      (Wake.outcome_label outcome);
    check int "nothing queued" 0
      (List.length (queued_cancellations ~base_path:config.base_path ~keeper_name:"alpha")))
;;

(* A [masc_transition] cancel with no top-level reason but a persisted handoff
   context commits with an explanation, and the broadcast publishes it. Reading
   only [Cancelled.reason] here handed the author a row with no reason at all —
   the two channels describing the same cancellation differently, and the wake
   losing exactly the context it exists to carry. *)
let test_handoff_reason_reaches_the_author_when_the_status_carries_none () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:"alpha";
    ensure_keeper config ~keeper_name:"beta";
    seed_task
      config
      ~task_id:"task-171"
      ~created_by:(Some "alpha")
      ~handoff_context:
        { D.summary = "sandbox lacks the request-menu service"
        ; D.reason = Some "cannot verify without the service"
        ; next_step = None
        ; failure_mode = None
        ; evidence_refs = []
        ; updated_at = None
        ; updated_by = None
        }
      ~status:(cancelled ~by:"beta" ~reason:None);
    let outcome =
      Wake.notify_author
        ~config
        ~actor:(Workspace_hooks.Task_terminal_agent "beta")
        ~task:(committed_task config "task-171")
    in
    check string "delivered" "delivered" (Wake.outcome_label outcome);
    match queued_cancellations ~base_path:config.base_path ~keeper_name:"alpha" with
    | [ cancellation ] ->
      check
        (option string)
        "the handoff reason travels with the wake"
        (Some "cannot verify without the service")
        cancellation.Event_queue.tc_reason
    | queued -> failf "expected one queued cancellation, got %d" (List.length queued))
;;

let test_author_without_a_keeper_lane_is_not_an_error () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:"beta";
    seed_task
      config
      ~task_id:"task-007"
      ~created_by:(Some "dashboard")
      ~status:(cancelled ~by:"beta" ~reason:None);
    check string "no lane to wake" "author_not_a_keeper"
      (Wake.outcome_label
         (Wake.notify_author
            ~config
            ~actor:(Workspace_hooks.Task_terminal_agent "beta")
            ~task:(committed_task config "task-007"))))
;;

let test_task_without_author_has_no_addressee () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:"beta";
    seed_task
      config
      ~task_id:"task-008"
      ~created_by:None
      ~status:(cancelled ~by:"beta" ~reason:None);
    check string "no author recorded" "no_author"
      (Wake.outcome_label
         (Wake.notify_author
            ~config
            ~actor:(Workspace_hooks.Task_terminal_agent "beta")
            ~task:(committed_task config "task-008"))))
;;

(* Completion posts a verdict to Board, so it must not also travel this path. *)
let test_completion_is_not_a_cancellation () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:"alpha";
    ensure_keeper config ~keeper_name:"beta";
    seed_task
      config
      ~task_id:"task-009"
      ~created_by:(Some "alpha")
      ~status:
        (D.Done { assignee = "beta"; completed_at = now; notes = None });
    check string "other terminal outcomes are declined" "not_cancelled"
      (Wake.outcome_label
         (Wake.notify_author
            ~config
            ~actor:(Workspace_hooks.Task_terminal_agent "beta")
            ~task:(committed_task config "task-009")));
    check int "nothing queued" 0
      (List.length (queued_cancellations ~base_path:config.base_path ~keeper_name:"alpha")))
;;

let test_non_agent_name_collision_is_delivered actor =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:"alpha";
    seed_task config ~task_id:"task-172" ~created_by:(Some "alpha")
      ~status:(cancelled ~by:"alpha" ~reason:(Some "operator stopped the work"));
    let first = Wake.notify_author ~config ~actor ~task:(committed_task config "task-172") in
    let second = Wake.notify_author ~config ~actor ~task:(committed_task config "task-172") in
    check string "non-agent is not the Keeper with the same name" "delivered"
      (Wake.outcome_label first);
    check string "repeat non-agent notification remains idempotent" "already_present"
      (Wake.outcome_label second);
    match queued_cancellations ~base_path:config.base_path ~keeper_name:"alpha" with
    | [ cancellation ] ->
      check string "committed canceller identity is preserved" "alpha"
        cancellation.Event_queue.tc_cancelled_by;
      check (option string) "committed reason is preserved"
        (Some "operator stopped the work") cancellation.tc_reason
    | queued -> failf "expected one queued cancellation, got %d" (List.length queued))
;;

let test_repeat_delivery_dedups_on_task_identity () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:"alpha";
    ensure_keeper config ~keeper_name:"beta";
    seed_task
      config
      ~task_id:"task-160"
      ~created_by:(Some "alpha")
      ~status:(cancelled ~by:"beta" ~reason:(Some "blocked"));
    let first =
      Wake.notify_author
        ~config
        ~actor:(Workspace_hooks.Task_terminal_agent "beta")
        ~task:(committed_task config "task-160")
    in
    let second =
      Wake.notify_author
        ~config
        ~actor:(Workspace_hooks.Task_terminal_agent "beta")
        ~task:(committed_task config "task-160")
    in
    check string "first delivers" "delivered" (Wake.outcome_label first);
    check string "second is recognised as the same event" "already_present"
      (Wake.outcome_label second);
    check int "one queue entry, not two" 1
      (List.length (queued_cancellations ~base_path:config.base_path ~keeper_name:"alpha")))
;;

let test_terminal_delivery_releases_backlog_and_keeps_committed_task () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:"alpha";
    let profiles = Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path in
    Fs_compat.mkdir_p profiles;
    (match Fs_compat.save_file_atomic (Filename.concat profiles "alpha.toml")
        "[keeper]\ninstructions = \"Controlled mention recipient.\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\n" with
     | Ok () -> () | Error detail -> fail detail);
    seed_task config ~task_id:"task-173" ~created_by:(Some "alpha")
      ~status:(D.Claimed { assignee = "beta"; claimed_at = now });
    Eio.Switch.run (fun sw ->
      let started, start = Eio.Promise.create () in
      let broadcast_started, broadcast_start = Eio.Promise.create () in
      let finished, finish = Eio.Promise.create () in
      let delivered = ref None in
      let broadcast_delivered = ref None in
      let broadcast_calls = ref 0 in
      let previous_broadcast = Workspace_broadcast.For_testing.replace_on_broadcast_mention
          (fun (delivery : Workspace_broadcast.broadcast_delivery) ->
            match delivery.mention with
            | Some "alpha" ->
              incr broadcast_calls;
              Eio.Promise.resolve broadcast_start delivery;
              let result = Server_bootstrap_loops.For_testing.deliver_broadcast_mention
                  ~config ~base_path:config.base_path ~is_running:(fun _ -> false)
                  ~is_registered_keeper:(fun _ -> false) ~wakeup:(fun _ -> ()) delivery in
              broadcast_delivered := Some result;
              result
            | None | Some _ -> Workspace_broadcast.Passive) in
      let previous = Atomic.exchange Workspace_hooks.task_terminal_committed_fn
          (fun _ ~actor ~(task : D.task) ->
            Eio.Promise.resolve start task;
            delivered := Some (Wake.notify_author ~config ~actor ~task);
            Workspace_hooks.Task_terminal_delivered) in
      Fun.protect ~finally:(fun () ->
        Atomic.set Workspace_hooks.task_terminal_committed_fn previous;
        Workspace_broadcast.set_on_broadcast_mention previous_broadcast) (fun () ->
        let (lock_free, deleted, broadcast_snapshot), _ =
          Masc.Keeper_shutdown_intake_fence.run_durable_intake_observing
            ~base_path:config.base_path ~keeper_name:"alpha" (fun _ ->
              Eio.Fiber.fork ~sw (fun () ->
                Eio.Fiber.yield ();
                let result = Workspace.transition_task_r config ~agent_name:"beta"
                    ~task_id:"task-173" ~action:D.Cancel ~reason:"original @alpha committed reason" () in
                Eio.Promise.resolve finish result);
              let captured = match Eio.Fiber.first
                  (fun () -> `Broadcast (Eio.Promise.await broadcast_started))
                  (fun () -> Eio.Fiber.first
                    (fun () -> `Terminal_early (Eio.Promise.await started))
                    (fun () -> `Finished (Eio.Promise.await finished))) with
                | `Broadcast captured -> captured
                | `Terminal_early _ -> fail "terminal notification overtook the committed broadcast"
        | `Finished (Ok _) -> fail "cancellation returned without its terminal notification"
        | `Finished (Error error) -> fail (D.masc_error_to_string error)
      in
              (* The real mention handler now waits for this intake key.
                 Recovery must still acquire backlog, rather than cycle. *)
              let lock_free = match Workspace_utils_ops.try_with_file_lock config
                  (Workspace_backlog.backlog_lock_path config) (fun () -> ()) with
                | Workspace_utils_ops.Lock_acquired () -> true
                | Lock_contended | Lock_unavailable _ -> false in
              let deleted = if not lock_free then false else
                match Workspace.delete_task_r config ~task_id:"task-173" with
                | Ok Workspace.Task_deleted -> true
                | Ok (Task_already_absent | Task_delete_cleanup_failed _) | Error _ -> false in
              lock_free, deleted, captured)
        in
        (match Eio.Promise.await finished with
         | Ok _ -> () | Error error -> fail (D.masc_error_to_string error));
        let captured = match Eio.Promise.peek started with
          | Some task -> task | None -> fail "committed terminal notification was lost" in
        check bool "intake holder can acquire backlog after the cancellation commit" true lock_free;
        check bool "Task is deleted before intake is released" true deleted;
        check int "committed mention broadcast is delivered once" 1 !broadcast_calls;
        check string "broadcast retains its committed actor" "beta" broadcast_snapshot.from_agent;
        check bool "broadcast retains its System_record audience" true
          (match broadcast_snapshot.audience with System_record -> true | Fleet_conversation -> false);
        (match !broadcast_delivered with
         | Some Workspace_broadcast.Accepted -> ()
         | Some (Already_accepted | Passive | Pending | Deferred _ | Rejected _) | None ->
           fail "real raw-mention delivery did not accept the committed broadcast");
        let message_id = Event_queue.workspace_message_post_id
          { wmsg_request_id = broadcast_snapshot.request_id; wmsg_from = "beta" } in
        check bool "raw mention reaches the durable author queue" true
          (load_queue ~base_path:config.base_path ~keeper_name:"alpha" |> Event_queue.to_list
           |> List.exists (fun (stimulus : Event_queue.stimulus) -> String.equal stimulus.post_id message_id));
        check string "terminal snapshot keeps its original identity" "task-173" captured.id;
        (match !delivered with
         | Some (Wake.Delivered _) -> ()
         | Some _ | None -> fail "captured cancellation did not reach its original author");
        match queued_cancellations ~base_path:config.base_path ~keeper_name:"alpha" with
        | [cancellation] ->
          check string "deleted Task cancellation retains its original actor" "beta"
            cancellation.Event_queue.tc_cancelled_by;
          check (option string) "deleted Task cancellation retains its original reason"
            (Some "original @alpha committed reason") cancellation.tc_reason
        | _ -> fail "expected one captured cancellation after source deletion")))
;;

(* Durability: the wake survives a restart, and "no reason given" must not come
   back as the string "null" or an empty reason. *)
let test_stimulus_round_trips_including_absent_reason () =
  let assert_round_trip cancellation =
    let payload = Event_queue.Task_cancelled cancellation in
    let stimulus : Event_queue.stimulus =
      { post_id = Event_queue.task_cancellation_post_id cancellation
      ; urgency = Event_queue.Normal
      ; arrived_at = 0.0
      ; payload
      }
    in
    match Event_queue.stimulus_of_yojson (Event_queue.stimulus_to_yojson stimulus) with
    | Error detail -> failf "round trip failed: %s" detail
    | Ok decoded ->
      (match decoded.payload with
       | Event_queue.Task_cancelled decoded_cancellation ->
         check string "task id" cancellation.Event_queue.tc_task_id
           decoded_cancellation.Event_queue.tc_task_id;
         check string "canceller" cancellation.tc_cancelled_by
           decoded_cancellation.tc_cancelled_by;
         check (option string) "reason" cancellation.tc_reason
           decoded_cancellation.tc_reason
       | _ -> fail "decoded payload is not a cancellation")
  in
  assert_round_trip
    { Event_queue.tc_task_id = "task-1"
    ; tc_cancelled_by = "beta"
    ; tc_reason = Some "blocked on sandbox"
    };
  assert_round_trip
    { Event_queue.tc_task_id = "task-2"
    ; tc_cancelled_by = "beta"
    ; tc_reason = None
    }
;;

let () =
  run
    "keeper task cancellation wake"
    [ ( "delivery"
      , [ test_case "cross-keeper cancellation is delivered" `Quick
            test_cross_keeper_cancellation_is_delivered
        ; test_case "self-cancellation is silent" `Quick
            test_self_cancellation_is_silent
        ; test_case "operator name collision is delivered" `Quick
            (fun () -> test_non_agent_name_collision_is_delivered
                (Workspace_hooks.Task_terminal_operator "alpha"))
        ; test_case "system name collision is delivered" `Quick
            (fun () -> test_non_agent_name_collision_is_delivered
                (Workspace_hooks.Task_terminal_system "alpha"))
        ; test_case "repeat delivery dedups on task identity" `Quick
            test_repeat_delivery_dedups_on_task_identity
        ; test_case "terminal delivery releases backlog and keeps the committed Task" `Quick
            test_terminal_delivery_releases_backlog_and_keeps_committed_task
        ] )
    ; ( "declined"
      , [ test_case "handoff reason reaches the author" `Quick
            test_handoff_reason_reaches_the_author_when_the_status_carries_none
        ; test_case "author without a keeper lane" `Quick
            test_author_without_a_keeper_lane_is_not_an_error
        ; test_case "task without author" `Quick test_task_without_author_has_no_addressee
        ; test_case "completion is not a cancellation" `Quick
            test_completion_is_not_a_cancellation
        ] )
    ; ( "durability"
      , [ test_case "stimulus round trips including absent reason" `Quick
            test_stimulus_round_trips_including_absent_reason
        ] )
    ]
;;
