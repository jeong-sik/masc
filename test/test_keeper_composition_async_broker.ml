(** The broker actually calls the callback the composition surface hands it.

    {!Keeper_composition_completion_wake} is unit-tested by calling [deliver]
    and [on_worker_settled] directly, which proves what those do and nothing
    about whether anything reaches them. The wiring is the whole change: a
    callback the broker never invokes leaves the submitter exactly as uninformed
    as before.

    So this drives the real path. A root switch is installed, the request goes
    through {!Keeper_msg_async.submit_with_request_id} with the same
    [on_worker_settled] the surface passes, the worker runs on the background
    switch, and the assertion reads the submitter's durable event queue. *)

open Alcotest
module Workspace = Masc.Workspace
module Keeper_meta_store = Masc.Keeper_meta_store
module Wake = Masc.Keeper_composition_completion_wake
module Async = Masc.Keeper_msg_async
module Event_queue = Keeper_event_queue
module Registry = Masc.Keeper_registry
module Profile = Masc.Keeper_types_profile

let submitter = "alpha"
let composition_tool = "keeper_compose_background-snapshot"

(* A worker settles in single-digit milliseconds, so this is a generous bound
   on "the wake never arrived" rather than a latency assertion. Measured
   locally at 12.3-13.0ms over six runs. *)
let wake_deadline_seconds = 10.0
let poll_interval_seconds = 0.01

let composition_results ~base_path =
  match Keeper_event_queue_persistence.load_result ~base_path ~keeper_name:submitter with
  | Error detail -> fail ("event queue load failed: " ^ detail)
  | Ok queue ->
    Event_queue.to_list queue
    |> List.filter_map (fun (stimulus : Event_queue.stimulus) ->
      match stimulus.payload with
      | Event_queue.Composition_completed completion -> Some completion
      | Event_queue.Board_signal _
      | Event_queue.Board_attention _
      | Event_queue.Bootstrap
      | Event_queue.Fusion_completed _
      | Event_queue.Schedule_due _
      | Event_queue.Connector_attention _
      | Event_queue.Hitl_resolved _
      | Event_queue.Manual_compaction_requested
      | Event_queue.Completion_authority_rejected _
      | Event_queue.Task_cancelled _
      | Event_queue.Workspace_message _
      | Event_queue.Delegate_completed _ -> None)
;;

(* [f] receives the workspace and a clock: the worker runs on a forked fiber,
   so the assertion has to be able to wait for it. *)
let with_server_workspace f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc_async_broker_%d_%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir dir 0o755;
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun root_sw ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  (* [Keeper_msg_async.server_background_switch] resolves this and nothing
     else, so without it the submit fails before any worker is forked. *)
  Eio_context.set_switch root_sw;
  let config = Workspace.default_config dir in
  ignore (Workspace.init config ~agent_name:(Some "operator"));
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
            [ "name", `String submitter
            ; "agent_name", `String ("keeper-" ^ submitter ^ "-agent")
            ; "autoboot_enabled", `Bool false
            ])
    with
    | Ok meta -> meta
    | Error err -> fail ("keeper meta fixture failed: " ^ err)
  in
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok _ -> ()
   | Error err -> fail ("write keeper meta failed: " ^ err));
  ignore
    (Registry.register_offline
       ~base_path:config.Workspace.base_path
       submitter
       meta
     : Registry.registry_entry);
  Fun.protect
    ~finally:(fun () -> ignore (Workspace.reset config))
    (fun () -> f config (Eio.Stdenv.clock env))
;;

let submit ~base_path ~result () =
  let background_sw =
    match Async.server_background_switch () with
    | Ok sw -> sw
    | Error error ->
      fail
        ("no background switch: " ^ Yojson.Safe.to_string (Async.submit_error_to_json error))
  in
  match
    Async.submit_with_request_id
      ~background_sw
      ~base_path
      ~caller:submitter
      ~keeper_name:submitter
        (* The exact wiring keeper_tool_composition_surface.ml passes. *)
      ~on_worker_settled:(Wake.on_worker_settled ~base_path ~composition_tool)
      ~f:(fun ~request_id:_ _request_sw -> result)
      ()
  with
  | Ok { Async.request_id; acceptance = Async.Durably_accepted } -> request_id
  | Ok { Async.request_id = _; acceptance = Async.Reconciliation_required { reason } } ->
    fail ("acceptance was not durable: " ^ reason)
  | Error error ->
    fail ("submit failed: " ^ Yojson.Safe.to_string (Async.submit_error_to_json error))
;;

let await_wake ~clock ~base_path =
  let rec poll waited =
    match composition_results ~base_path with
    | completion :: _ -> completion
    | [] ->
      if waited >= wake_deadline_seconds
      then
        fail
          (Printf.sprintf
             "no wake reached the submitter's queue within %.0fs"
             wake_deadline_seconds)
      else (
        Eio.Time.sleep clock poll_interval_seconds;
        poll (waited +. poll_interval_seconds))
  in
  poll 0.0
;;

let a_settled_worker_wakes_the_submitter () =
  with_server_workspace (fun config clock ->
    let base_path = config.Workspace.base_path in
    let request_id =
      submit
        ~base_path
        ~result:
          (Profile.tool_result_ok_data
             ~tool_name:composition_tool
             (`Assoc [ "composition_tool", `String composition_tool; "actions", `List [] ]))
        ()
    in
    let completion = await_wake ~clock ~base_path in
    check
      string
      "the wake correlates to the id submit handed back"
      request_id
      completion.Event_queue.cc_request_id;
    check
      string
      "and names the composition that ran"
      composition_tool
      completion.Event_queue.cc_tool;
    (match completion.Event_queue.cc_terminal with
     | Event_queue.Composition_succeeded -> ()
     | Event_queue.Composition_failed detail ->
       fail ("a successful worker woke the submitter as failed: " ^ detail)
     | Event_queue.Composition_cancelled reason ->
       fail ("a successful worker woke the submitter as cancelled: " ^ reason));
    (* The result itself stays where keeper_composition_status reads it. The
       wake is an announcement, not a second copy of the answer. *)
    match Async.poll ~base_path ~caller:submitter request_id with
    | Async.Found entry ->
      check
        string
        "the durable request record still holds the result"
        "done"
        (Async.status_to_string entry.Async.status)
    | Async.Absent -> fail "the durable request record disappeared"
    | Async.Unreadable reason ->
      fail ("the durable request record is unreadable: " ^ reason)
    | Async.Rejected _ ->
      fail "the durable request record is outside the submitter's lane")
;;

(* A failed run is as much an answer as a successful one: the submitter stops
   counting on it either way, so the failure has to make the same trip. *)
let a_failed_worker_wakes_the_submitter () =
  with_server_workspace (fun config clock ->
    let base_path = config.Workspace.base_path in
    let request_id =
      submit
        ~base_path
        ~result:
          (Profile.tool_result_error
             ~tool_name:composition_tool
             ~class_:Tool_result.Dependency_unavailable
             "node board: store unavailable")
        ()
    in
    let completion = await_wake ~clock ~base_path in
    check
      string
      "the failure correlates to the submitted request"
      request_id
      completion.Event_queue.cc_request_id;
    match completion.Event_queue.cc_terminal with
    | Event_queue.Composition_failed detail ->
      check
        bool
        "the failure detail travels with the wake"
        true
        (String.length detail > 0)
    | Event_queue.Composition_succeeded ->
      fail "a failed worker woke the submitter as succeeded"
    | Event_queue.Composition_cancelled reason ->
      fail ("a failed worker woke the submitter as cancelled: " ^ reason))
;;

let () =
  run
    "keeper composition async broker"
    [ ( "the broker calls the callback"
      , [ test_case "a settled worker wakes the submitter" `Quick
            a_settled_worker_wakes_the_submitter
        ; test_case "a failed worker wakes the submitter" `Quick
            a_failed_worker_wakes_the_submitter
        ] )
    ]
;;
