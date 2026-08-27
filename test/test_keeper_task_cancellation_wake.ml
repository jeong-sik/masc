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
             ; "autoboot_enabled", `Bool false
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
    ; reclaim_policy = None
    ; execution_links = Masc_domain.no_execution_links
    ; do_not_reclaim_reason = None
    ; skills = []
    }
  in
  Workspace_backlog.write_backlog
    config
    { tasks = [ task ]; last_updated = now; version = 1 }
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
    | Event_queue.Board_attention _
    | Event_queue.Bootstrap
    | Event_queue.Fusion_completed _
    | Event_queue.Schedule_due _
    | Event_queue.Connector_attention _
    | Event_queue.Hitl_resolved _
    | Event_queue.Ask_answered _
    | Event_queue.Manual_compaction_requested
    | Event_queue.Completion_authority_rejected _
    | Event_queue.Workspace_message _
    | Event_queue.Delegate_completed _
    | Event_queue.Composition_completed _ -> None)
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
        ~cancelling_agent_name:"beta"
        ~task_id:"task-161"
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
      Wake.notify_author ~config ~cancelling_agent_name:"alpha" ~task_id:"task-155"
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
        ; reclaim_policy = None
        ; evidence_refs = []
        ; updated_at = None
        ; updated_by = None
        }
      ~status:(cancelled ~by:"beta" ~reason:None);
    let outcome =
      Wake.notify_author
        ~config
        ~cancelling_agent_name:"beta"
        ~task_id:"task-171"
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
            ~cancelling_agent_name:"beta"
            ~task_id:"task-007")))
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
            ~cancelling_agent_name:"beta"
            ~task_id:"task-008")))
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
            ~cancelling_agent_name:"beta"
            ~task_id:"task-009"));
    check int "nothing queued" 0
      (List.length (queued_cancellations ~base_path:config.base_path ~keeper_name:"alpha")))
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
        ~cancelling_agent_name:"beta"
        ~task_id:"task-160"
    in
    let second =
      Wake.notify_author
        ~config
        ~cancelling_agent_name:"beta"
        ~task_id:"task-160"
    in
    check string "first delivers" "delivered" (Wake.outcome_label first);
    check string "second is recognised as the same event" "already_present"
      (Wake.outcome_label second);
    check int "one queue entry, not two" 1
      (List.length (queued_cancellations ~base_path:config.base_path ~keeper_name:"alpha")))
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
        ; test_case "repeat delivery dedups on task identity" `Quick
            test_repeat_delivery_dedups_on_task_identity
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
