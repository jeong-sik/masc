(** Real canonical answers, Tasks and follow-up reads pass through the server's
    frame producer, strict decoder and retained partial/result lifecycle.
    No HTTP networking, Main key loop, provider, TUI process or pixels. *)
open Alcotest
module Ui = Masc_tui_types
module Protocol = Masc_tui_async_protocol
module Results = Masc_tui_workspace_result
module Projection = Masc_tui_ask_projection
module Decode = Masc.Tui_decode_asks
module Wake = Masc.Keeper_ask_answer_wake
module Server = Server_routes_http_keeper_stream
module Observation = Masc_tui_ask_followup_observation

let () = Mirage_crypto_rng_unix.use_default ()
let () = Masc.Workspace_metric_hooks.install ()
let require = function Ok value -> value | Error detail -> fail detail
let identity base : Masc.Tui_decode.server_identity =
  {sid_version="0.24.0";sid_binary_commit="ask-followup-resource";sid_binary_commit_age_s=None;
   sid_base_path=Masc.Tui_decode.Canonical_path.of_path (Unix.realpath base);sid_masc_root=Masc.Tui_decode.Canonical_path.of_path (Unix.realpath (Filename.concat base ".masc"));
   sid_executable_in_worktree=None;sid_state_ready=Some true;sid_uptime=None;
   sid_sse_clients=None;sid_gc=None;sid_scheduler=None}
let with_answer f =
  let base=Filename.temp_dir "tui-ask-followup-resource-" "" in
  Fun.protect ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace base) @@ fun () ->
  let config=Masc.Workspace.default_config base and keeper="alpha" in
  ignore (Masc.Workspace.init config ~agent_name:(Some "test-operator"));
  let meta=Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name",`String keeper;"activation_mode",`String "manual"]) |> require in
  ignore (Masc.Keeper_meta_store.replace_snapshot config meta |> require);
  ignore (Masc.Keeper_registry.register_offline ~base_path:base keeper meta);
  Fun.protect ~finally:(fun () -> Masc.Keeper_registry.For_testing.unregister ~base_path:base keeper) @@ fun () ->
  let task_id=match Workspace_task_create.add_task_with_result config ~created_by:keeper
    ~title:"original answered Task" ~priority:3 ~description:"real follow-up source" with
    | Ok created -> created.task_id
    | Error error -> fail (Workspace_task_create.add_task_error_to_string error) in
  let choice=Masc.Keeper_ask.choice ~choice_id:"c1" ~label:"Proceed" ()
    |> Result.map_error Masc.Keeper_ask.invalid_choice_to_string |> require in
  let question=Masc.Keeper_ask.question ~question_id:"q1" ~header:"decision" ~prompt:"Proceed?"
    ~choices:[choice] ~mode:Masc.Keeper_ask.Single ~free_text:Masc.Keeper_ask.Choices_only
    |> Result.map_error Masc.Keeper_ask.invalid_question_to_string |> require in
  let continuation=Masc.Keeper_continuation_channel.dashboard ~thread_id:"original-thread" |> require in
  let ask=Masc.Keeper_ask.ask ~ask_id:"original-answer" ~keeper_name:keeper ~questions:[question]
    ~context:"original work" ~task_id ~continuation ~asked_at:100. ()
    |> Result.map_error Masc.Keeper_ask.invalid_ask_to_string |> require in
  Masc.Keeper_ask_store.record_ask ~base_path:base ask |> require;
  let responder={Masc.Keeper_ask.surface=Masc.Surface_ref.Dashboard {session_id=None};
    actor_id=Some "original-operator";display_name=None} in
  ignore (Masc.Keeper_ask_store.answer ~base_path:base ~keeper_name:keeper ~ask_id:ask.ask_id
    ~submissions:["q1",Masc.Keeper_ask.Chose {choice_ids=["c1"]}] ~responder ~now:200.
    |> Result.map_error Masc.Keeper_ask_store.answer_failure_to_string |> require);
  let resolution=match Masc.Keeper_ask_store.rows_result ~base_path:base ~keeper_name:keeper with
    | Ok (Stored_rows rows) -> List.assoc ask.ask_id rows
    | Ok Missing_log | Error _ -> fail "canonical answer did not persist" in
  ignore (Wake.deliver ~base_path:base ~keeper_name:keeper ~ask_id:ask.ask_id
    |> Result.map_error Wake.error_to_string |> require);
  let state=Ui.create_state ~workspace:"followup-resource" ~local_base_path:base ~port:0 ~refresh_interval:2. () in
  state.server_identity <- Some (identity base);state.workspace_identity <- Ui.Workspace_identity_match;
  state.view <- Ui.Approvals;
  let submission : Ui.ask_submission = {as_request=ref ();as_started_ns=0L;
    as_receipt=Ui.Ask_answer_receipt.create ();as_completion=Ui.Ask_answer_completion.create ();
    as_reading=Some state.workspace_read_authority;as_authority=state.workspace_authority;
    as_asker=Decode.Ask_keeper keeper;as_ask_id=ask.ask_id;as_source_turn_ref=None;as_answered_label="Proceed"} in
  Ui.begin_ask_submission_state ~submission state;
  ignore (Ui.retain_ask_answer_feedback state submission (Ok (Decode.Keeper_answer_receipt (Decode.Ask_answer_recorded Ask_wake_stored))));
  f base config ask resolution task_id state
let begin_read state = match Ui.begin_ask_followup_read state with
  | Some (request,submission,_keeper) -> request,submission | None -> fail "original recorded answer could not own a read"
let actual_read base ask resolution ~before_source ~parts publish =
  let stream=ref Decode.empty_ask_followup_stream in
  let frame value =
    let workspace=`Assoc ["base_path",`String (Unix.realpath base);
      "masc_root",`String (Unix.realpath (Filename.concat base ".masc"))] in
    let json=Server.ask_followup_frame_json ~workspace ~state_ready:true
      ~keeper_name:ask.Masc.Keeper_ask.keeper_name ~ask_id:ask.ask_id value in
    let event=Decode.decode_ask_followup_event ~expected_base_path:(Unix.realpath base)
      ~expected_masc_root:(Unix.realpath (Filename.concat base ".masc"))
      ~keeper_name:ask.keeper_name ~ask_id:ask.ask_id json |> require in
    stream := Decode.accept_ask_followup_event !stream event |> require;
    let received_ns=Mtime_clock.elapsed_ns () in
    parts := (event,received_ns) :: !parts;
    publish (event,received_ns) in
  match Wake.observe_followup ~base_path:base ~keeper_name:ask.keeper_name ~ask ~resolution
    ~on_started:(fun original -> frame (Server.Followup_started original))
    ~on_source:(fun original source -> before_source source;frame (Server.Followup_source (original,source))) () with
  | Error detail -> Error detail
  | Ok observed ->
    frame (Server.Followup_completed {answered_at=observed.answered_at;stimulus_id=observed.stimulus_id});
    Decode.finish_ask_followup_stream !stream
let launch ?key state results request submission ~released perform =
  let admission_started_ns=Mtime_clock.elapsed_ns () in
  let expected_workspace=match state.Ui.server_identity with Some identity -> identity | None -> fail "fixture workspace identity is missing" in
  let read=Protocol.capture_ask_followup_read ~instance:state.observation_instance
    ~request ~submission ~expected_workspace ~admission_started_ns in
  let envelope=Protocol.capture_workspace_message state in
  let stop,resolve=Eio.Promise.create () in
  Ui.supersede_ask_followup_worker state
    (Some (request,fun detail -> ignore (Eio.Promise.try_resolve resolve detail))) ~detail:"original read superseded";
  let finish ()=Ui.finish_ask_followup_worker state request in
  Observation.emit read ~sources:(Ui.current_ask_followup state) Observation.Followup_read_started;
  Results.launch_observation ?key state ~results ~boundary_error:(fun detail -> Projection.Followup_read_failed detail)
    ~not_started:(fun detail -> Projection.Followup_not_started detail) ~on_not_run:finish
    ~observe_job:(fun event ->
      Observation.emit read ~sources:None (Observation.Followup_job_event event);
      match event with Masc_tui_workspace_job.Cancellation_requested -> () | Registration_released -> released ())
    ~cancelled:(envelope (Protocol.Ask_followup_finished (read,
      Error Projection.Followup_cancelled)))
    ~progress:(fun (event,received_ns) -> envelope (Protocol.Ask_followup_observed (read,event,received_ns)))
    ~deliver:(fun result -> envelope (Protocol.Ask_followup_finished (read,result)))
    (fun publish -> Fun.protect ~finally:finish (fun () ->
      Observation.emit read ~sources:None Observation.Followup_worker_entered;
      let result=try Eio.Fiber.first
        (fun () -> perform publish |> Result.map_error (fun detail -> Projection.Followup_read_failed detail))
        (fun () -> let _detail=Eio.Promise.await stop in Error Projection.Followup_withdrawn)
        with Eio.Cancel.Cancelled _ as exn ->
          let backtrace=Printexc.get_raw_backtrace () in
          Observation.emit read ~sources:None Observation.Followup_producer_cancelled;
          Printexc.raise_with_backtrace exn backtrace in
      Observation.emit read ~sources:None (Observation.Followup_producer_returned result);
      result))
type admission = Part of Decode.ask_followup_event * int64 | Terminal of Projection.followup_result | Refused
let apply state message = match message with
  | Protocol.Workspace_scoped (authority,reading,inner) ->
    if not (Protocol.workspace_message_admitted state ~authority ~reading inner) then Refused else
      (match inner with
       | Ask_followup_observed (read,event,received_ns) ->
         (match Ui.take_ask_followup_event state read.afr_request read.afr_submission event with
          | Some result ->
            Observation.emit read ~sources:(Ui.current_ask_followup state)
              (Observation.Followup_source_applied (event,received_ns,Result.is_ok result));
            (match result with Ok _ -> Part (event,received_ns) | Error detail -> fail detail)
          | None -> Refused)
       | Ask_followup_finished (read,result) ->
         (match Ui.finish_ask_followup_read state read.afr_request read.afr_submission result with
          | Some result ->
            Observation.emit read ~sources:(Ui.current_ask_followup state)
              (Observation.Followup_ui_settled result);
            Terminal result
          | None -> Refused)
       | _ -> fail "observation changed its original message kind")
  | _ -> fail "original follow-up lost its captured workspace envelope"
let apply_batch state seen batch =
  List.fold_left (fun terminal (ready : Protocol.async_msg Results.ready) ->
    match apply state ready.message with
    | Part (event,received_ns) -> seen:=(event,received_ns) :: !seen;terminal
    | Terminal result -> Some result
    | Refused -> fail "current original follow-up was refused") None batch
let apply_ready state results seen = apply_batch state seen (Results.take_ready results)
let rec terminal state results seen = match apply_ready state results seen with
  | Some result -> result | None -> Eio.Fiber.yield ();terminal state results seen
let view state = match Ui.current_ask_followup state with
  | Some source -> Projection.followup_view source | None -> fail "original follow-up has no owned observation"
let exact_task state task_id =
  let source=(view state).fv_task in
  check bool "actual Task source is received" true (source.fo_state=Projection.Followup_received);
  match source.fo_value with
  | Some (Decode.Ask_task_observed task) ->
    check string "source retains the original question's Task" task_id task.akt_task_id;
    check bool "Todo is an observation, never useful-work completion" true (task.akt_status=Masc_domain.Todo)
  | Some (Ask_task_unlinked | Ask_task_missing _ | Ask_task_unavailable _) | None -> fail "actual original Task was lost"
let occupied_queue () =
  let shared=Eio.Stream.create 1 in
  Eio.Stream.add shared {Protocol.ready_at_ns=0L;message=Protocol.Harness_label_done (Ok "original unrelated notification")};shared

let test_full_queue_keeps_partial_and_terminal () = with_answer @@ fun base config ask resolution task_id state ->
  Eio.Switch.run @@ fun sw -> Eio_context.with_turn_switch sw @@ fun () ->
  let shared=occupied_queue () and results=Results.create () in
  Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  let task_seen,task_resolve=Eio.Promise.create () and gate,release=Eio.Promise.create () in
  let left,left_resolve=Eio.Promise.create () in
  let before=Masc.Workspace.get_tasks_raw config in
  let parts=ref [] and seen=ref [] in
  let request,submission=begin_read state in
  launch state results request submission ~released:(fun () -> ignore (Eio.Promise.try_resolve left_resolve ()))
    (actual_read base ask resolution ~parts ~before_source:(function
      | Wake.Reaction_evidence _ -> Eio.Promise.await gate
      | Linked_task _ -> Eio.Promise.resolve task_resolve ()
      | Tool_results _ -> ()));
  Eio.Promise.await task_seen;Eio.Fiber.yield ();
  ignore (apply_ready state results seen);exact_task state task_id;
  check bool "unreturned reaction source stays pending" true ((view state).fv_reactions.fo_state=Projection.Followup_pending);
  check bool "held actual source remains unfinished" true
    (Option.bind (Ui.current_ask_followup state) Projection.followup_completion=None);
  Masc_tui_message_input.insert state.msg_input "new input while follow-up is observed";
  Eio.Promise.resolve release ();Eio.Promise.await left;
  check bool "terminal retained without taking shared notification" true (terminal state results seen=Ok ());
  Ui.retire_ask_followup_read state;
  check bool "retiring completed actual read preserves its original terminal cause" true
    (Option.bind (Ui.current_ask_followup state) Projection.followup_completion=Some (Ok ()));
  check bool "shared queue stayed physically occupied" true (Eio.Stream.length shared=1);
  check bool "all actual frame facts and received clocks keep publication order" true (List.rev !parts=List.rev !seen);
  check bool "physical job cleanup releases only its registration" true
    (state.ask_followup_cancel=None && state.workspace_observation_cancellations=[]);
  check bool "source reads leave actual Task resources unchanged" true (before=Masc.Workspace.get_tasks_raw config);
  check string "late source reads preserve new input" "new input while follow-up is observed" (Masc_tui_message_input.contents state.msg_input)

let test_failure_and_reopened_scope_keep_original_facts () = with_answer @@ fun base config ask resolution task_id state ->
  Eio.Switch.run @@ fun sw -> Eio_context.with_turn_switch sw @@ fun () ->
  let shared=occupied_queue () and results=Results.create () in
  Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  let task_seen,task_resolve=Eio.Promise.create () and gate,release=Eio.Promise.create () in
  let left,left_resolve=Eio.Promise.create () in
  let request,submission=begin_read state and parts=ref [] and seen=ref [] in
  launch state results request submission ~released:(fun () -> ignore (Eio.Promise.try_resolve left_resolve ()))
    (actual_read base ask resolution ~parts ~before_source:(function
      | Wake.Reaction_evidence _ -> Eio.Promise.await gate;raise (Sys_error "controlled stream disconnect after original Task")
      | Linked_task _ -> Eio.Promise.resolve task_resolve () | Tool_results _ -> ()));
  Eio.Promise.await task_seen;Eio.Fiber.yield ();ignore (apply_ready state results seen);exact_task state task_id;
  Eio.Promise.resolve release ();Eio.Promise.await left;
  (match terminal state results seen with
   | Error (Projection.Followup_read_failed _) -> ()
   | Ok () | Error (Followup_cancelled | Followup_not_started _ | Followup_withdrawn) -> fail "actual disconnect lost its failed cause");
  Ui.retire_ask_followup_read state;
  (match Option.bind (Ui.current_ask_followup state) Projection.followup_completion with
   | Some (Error (Projection.Followup_read_failed _)) -> ()
   | Some _ | None -> fail "retirement relabelled the actual failed read");
  exact_task state task_id;
  check bool "unreceived reaction is unconfirmed, never observed empty" true
    ((view state).fv_reactions.fo_state=Projection.Followup_unconfirmed);
  let old,owner=begin_read state and old_left,old_resolve=Eio.Promise.create () in
  launch state results old owner ~released:(fun () -> ignore (Eio.Promise.try_resolve old_resolve ()))
    (actual_read base ask resolution ~parts:(ref []) ~before_source:(fun _ -> ()));
  Eio.Promise.await old_left;
  let held=Results.take_ready results in Ui.retire_ask_followup_read state;
  check bool "active original read retirement retains a typed withdrawal" true
    (Option.bind (Ui.current_ask_followup state) Projection.followup_completion=Some (Error Projection.Followup_withdrawn));
  let fresh,owner=begin_read state and fresh_left,fresh_resolve=Eio.Promise.create () in
  launch state results fresh owner ~released:(fun () -> ignore (Eio.Promise.try_resolve fresh_resolve ()))
    (actual_read base ask resolution ~parts:(ref []) ~before_source:(fun _ -> ()));
  Eio.Promise.await fresh_left;
  check bool "fresh original visit admits its own actual observations" true (terminal state results (ref [])=Ok ());
  List.iter (fun (ready : Protocol.async_msg Results.ready) ->
    check bool "old completed visit cannot borrow the reopened same answer" true (apply state ready.message=Refused)) held;
  exact_task state task_id;
  let retired,owner=begin_read state and retired_left,retired_resolve=Eio.Promise.create () in
  launch state results retired owner ~released:(fun () -> ignore (Eio.Promise.try_resolve retired_resolve ()))
    (actual_read base ask resolution ~parts:(ref []) ~before_source:(fun _ -> ()));
  Eio.Promise.await retired_left;
  let held=Results.take_ready results and before=Masc.Workspace.get_tasks_raw config in
  (* Withdraw only the read lease first: the same answer/request still exists,
     so message admission must distinguish observations from operation facts. *)
  state.workspace_read_authority <- ref ();
  List.iter (fun (ready : Protocol.async_msg Results.ready) ->
    check bool "read withdrawal refuses original partial and terminal envelopes" true (apply state ready.message=Refused)) held;
  Ui.suspend_workspace_readings state;
  check bool "closed read scope leaves actual Task unchanged" true (before=Masc.Workspace.get_tasks_raw config);
  check bool "failure and retry do not drain the shared notification" true (Eio.Stream.length shared=1)

let test_session_close_and_unstarted_preserve_resources () = with_answer @@ fun base config ask resolution task_id state ->
  let before=Masc.Workspace.get_tasks_raw config in
  let results=Results.create () in
  check bool "unstarted fixture has no original turn switch" true (Option.is_none (Eio_context.get_switch_opt ()));
  let request,submission=begin_read state in
  launch state results request submission ~released:(fun () -> ())
    (actual_read base ask resolution ~parts:(ref []) ~before_source:(fun _ -> ()));
  (match terminal state results (ref []) with
   | Error (Projection.Followup_not_started _) -> ()
   | Ok () | Error (Followup_read_failed _ | Followup_cancelled | Followup_withdrawn) -> fail "missing switch was not retained as an unstarted attempt");
  Results.close results;
  Eio.Switch.run @@ fun sw -> Eio_context.with_turn_switch sw @@ fun () ->
  let results=Results.create () in
  let task_seen,task_resolve=Eio.Promise.create () and gate,release=Eio.Promise.create () in
  let left,left_resolve=Eio.Promise.create () in
  let request,submission=begin_read state in
  launch state results request submission ~released:(fun () -> ignore (Eio.Promise.try_resolve left_resolve ()))
    (actual_read base ask resolution ~parts:(ref []) ~before_source:(function
      | Wake.Reaction_evidence _ -> Eio.Promise.await gate
      | Linked_task _ -> Eio.Promise.resolve task_resolve () | Tool_results _ -> ()));
  Eio.Promise.await task_seen;Eio.Fiber.yield ();
  ignore (apply_ready state results (ref []));exact_task state task_id;
  Results.close results;Eio.Promise.resolve release ();Eio.Promise.await left;
  check bool "ended result session cannot reopen for late parts or terminal" true (Results.take_ready results=[]);
  check bool "close is separate from actual completed worker cleanup" true
    (state.workspace_observation_cancellations=[] && state.ask_followup_cancel=None);
  check bool "closed and unstarted reads do not alter original Task resources" true (before=Masc.Workspace.get_tasks_raw config)

let test_actual_followup_cancellation_settles_after_cleanup () = with_answer @@ fun base config ask resolution task_id state ->
  Eio.Switch.run @@ fun sw -> Eio_context.with_turn_switch sw @@ fun () ->
  let before=Masc.Workspace.get_tasks_raw config and results=Results.create () in
  Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  let key=ref () and seen=ref [] in
  let task_seen,task_resolve=Eio.Promise.create () and blocked,_release_blocked=Eio.Promise.create () in
  let cleaning,cleaning_resolve=Eio.Promise.create () and cleanup,cleanup_release=Eio.Promise.create () in
  let left,left_resolve=Eio.Promise.create () in
  let request,submission=begin_read state in
  launch ~key state results request submission ~released:(fun () -> ignore (Eio.Promise.try_resolve left_resolve ()))
    (actual_read base ask resolution ~parts:(ref []) ~before_source:(function
      | Wake.Reaction_evidence _ ->
        Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () ->
          Eio.Promise.resolve cleaning_resolve ();Eio.Promise.await cleanup))
          (fun () -> Eio.Promise.await blocked)
      | Linked_task _ -> Eio.Promise.resolve task_resolve () | Tool_results _ -> ()));
  Eio.Promise.await task_seen;Eio.Fiber.yield ();ignore (apply_ready state results seen);exact_task state task_id;
  Masc_tui_message_input.insert state.msg_input "input during cancelled follow-up";
  Masc_tui_workspace_job.cancel_observation state ~key;
  Eio.Promise.await cleaning;
  check bool "cancellation request is separate from actual producer cleanup" true
    (Ui.Snapshot_read.in_flight state.ask_followup_read && Option.is_some state.ask_followup_cancel
     && List.exists (fun (owner,_) -> owner==key) state.workspace_observation_cancellations);
  check bool "no cancelled terminal before actual producer cleanup" true (apply_ready state results seen=None);
  Eio.Promise.resolve cleanup_release ();Eio.Promise.await left;
  let held=Results.take_ready results in
  let cancelled=List.find_map (fun (ready : Protocol.async_msg Results.ready) -> match apply state ready.message with
    | Terminal (Error Projection.Followup_cancelled) -> Some ready.message
    | Part _ -> None
    | Terminal (Ok () | Error (Followup_read_failed _ | Followup_not_started _ | Followup_withdrawn)) -> fail "actual cancellation lost its typed cause"
    | Refused -> fail "current cancelled original read was refused") held in
  let cancelled=match cancelled with Some message -> message | None -> fail "cancelled worker left an orphaned read ticket" in
  check bool "cancelled original request settled and actual job registration released" true
    (not (Ui.Snapshot_read.in_flight state.ask_followup_read) && state.ask_followup_cancel=None
     && not (List.exists (fun (owner,_) -> owner==key) state.workspace_observation_cancellations));
  exact_task state task_id;
  check bool "cancelled unreceived source is unconfirmed, never a fabricated empty reaction" true
    ((view state).fv_reactions.fo_state=Projection.Followup_unconfirmed && (view state).fv_reactions.fo_value=None);
  let fresh,owner=begin_read state and fresh_left,fresh_resolve=Eio.Promise.create () in
  launch state results fresh owner ~released:(fun () -> ignore (Eio.Promise.try_resolve fresh_resolve ()))
    (actual_read base ask resolution ~parts:(ref []) ~before_source:(fun _ -> ()));
  check bool "old cancellation cannot settle the replacement read" true (apply state cancelled=Refused);
  Eio.Promise.await fresh_left;
  check bool "fresh actual read can complete after cancellation" true (terminal state results (ref [])=Ok ());
  check bool "actual cancellation and replacement preserve original Task resources" true (before=Masc.Workspace.get_tasks_raw config);
  check string "cancelled observation leaves operator input intact" "input during cancelled follow-up" (Masc_tui_message_input.contents state.msg_input)

let test_cancelled_dispatch_retains_unstarted_original_observation () = with_answer @@ fun base config ask resolution task_id state ->
  Eio.Switch.run @@ fun outer -> Eio_context.with_turn_switch outer @@ fun () ->
  let before=Masc.Workspace.get_tasks_raw config and results=Results.create () in
  Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  let request,submission=begin_read state in
  let exception Stop_before_dispatch in
  let propagated=try
    Eio.Cancel.sub (fun context -> Eio.Switch.run (fun cancelled_switch ->
      Eio_context.with_turn_switch cancelled_switch (fun () ->
        Eio.Cancel.cancel context Stop_before_dispatch;
        launch state results request submission ~released:(fun () -> ())
          (actual_read base ask resolution ~parts:(ref []) ~before_source:(fun _ -> ())))));
    false
  with Eio.Cancel.Cancelled Stop_before_dispatch -> true in
  check bool "original pre-dispatch cancellation still propagates" true propagated;
  check bool "pre-dispatch cancellation retains its actual cancellation cause" true
    (terminal state results (ref [])=Error Projection.Followup_cancelled);
  check bool "unstarted cancellation leaves no pending ticket or worker metadata" true
    (not (Ui.Snapshot_read.in_flight state.ask_followup_read) && state.ask_followup_cancel=None
     && state.workspace_observation_cancellations=[]);
  let original=view state in
  check bool "no source identity or Task observation is fabricated before actual entry" true
    (original.fv_identity=None && original.fv_task.fo_value=None
     && original.fv_task.fo_state=Projection.Followup_unconfirmed);
  let fresh,owner=begin_read state and left,left_resolve=Eio.Promise.create () in
  launch state results fresh owner ~released:(fun () -> ignore (Eio.Promise.try_resolve left_resolve ()))
    (actual_read base ask resolution ~parts:(ref []) ~before_source:(fun _ -> ()));
  Eio.Promise.await left;
  check bool "actual original read starts after cancelled dispatch" true (terminal state results (ref [])=Ok ());
  exact_task state task_id;
  check bool "cancelled dispatch and fresh actual observation preserve Task resources" true (before=Masc.Workspace.get_tasks_raw config)

module Origin = Masc_tui_observation_origin
let captured_read = function
  | Protocol.Workspace_scoped (_,_,(Protocol.Ask_followup_observed (read,_,_) | Ask_followup_finished (read,_))) -> read
  | _ -> fail "actual original observation lost its provenance capsule"
let first_read (batch : Protocol.async_msg Results.ready list) = match batch with
  | ready::_ -> captured_read ready.message | [] -> fail "actual original observation produced no retained messages"
let instance_id read = match Origin.to_json read.Protocol.afr_origin with
  | `Assoc fields -> (match List.assoc_opt "tui_instance_id" fields with
    | Some (`String value) -> value | Some _ | None -> fail "actual read has no instance provenance")
  | _ -> fail "actual read provenance is not an object"
let origin_field read ~section key =
  let object_fields = function `Assoc fields -> fields | _ -> fail "original provenance field is not an object" in
  let fields=Origin.to_json read.Protocol.afr_origin |> object_fields in
  let nested=match List.assoc_opt section fields with Some value -> object_fields value | None -> fail "original provenance section missing" in
  match List.assoc_opt key nested with Some (`String value) -> value
  | Some _ | None -> fail "original provenance identity field missing"
let check_captured_batch expected batch =
  List.iter (fun (ready : Protocol.async_msg Results.ready) ->
    let actual=captured_read ready.message in
    check bool "actual partial and terminal messages retain their original origin and clock" true
      (Origin.to_json actual.afr_origin=Origin.to_json expected.Protocol.afr_origin
       && actual.afr_admission_started_ns=expected.afr_admission_started_ns
       && Ui.Snapshot_read.request_id actual.afr_request=Ui.Snapshot_read.request_id expected.afr_request
       && actual.afr_submission.as_request==expected.afr_submission.as_request)) batch
let test_actual_workspaces_keep_distinct_original_provenance () =
  with_answer @@ fun base_a config_a ask_a resolution_a _task_a state_a ->
  with_answer @@ fun base_b config_b ask_b resolution_b task_b state_b ->
  Eio.Switch.run @@ fun sw -> Eio_context.with_turn_switch sw @@ fun () ->
  let before_a=Masc.Workspace.get_tasks_raw config_a and before_b=Masc.Workspace.get_tasks_raw config_b in
  let results_a=Results.create () and results_b=Results.create () in
  Fun.protect ~finally:(fun () -> Results.close results_a;Results.close results_b) @@ fun () ->
  let request_a,submission_a=begin_read state_a and request_b,submission_b=begin_read state_b in
  let left_a,resolve_a=Eio.Promise.create () and left_b,resolve_b=Eio.Promise.create () in
  launch state_a results_a request_a submission_a ~released:(fun () -> ignore (Eio.Promise.try_resolve resolve_a ()))
    (actual_read base_a ask_a resolution_a ~parts:(ref []) ~before_source:(fun _ -> ()));
  launch state_b results_b request_b submission_b ~released:(fun () -> ignore (Eio.Promise.try_resolve resolve_b ()))
    (actual_read base_b ask_b resolution_b ~parts:(ref []) ~before_source:(fun _ -> ()));
  Eio.Promise.await left_a;Eio.Promise.await left_b;
  let batch_a=Results.take_ready results_a and batch_b=Results.take_ready results_b in
  let original_a=first_read batch_a and original_b=first_read batch_b in
  check_captured_batch original_a batch_a;check_captured_batch original_b batch_b;
  check bool "independent actual TUI instances do not share a cohort identity" true
    (instance_id original_a<>instance_id original_b);
  check bool "per-source counters alone cannot identify these two actual reads" true
    (Ui.Snapshot_read.request_id request_a=Ui.Snapshot_read.request_id request_b);
  check string "first original read retains first real workspace" (Unix.realpath base_a)
    (origin_field original_a ~section:"workspace" "base_path");
  check string "second original read retains second real workspace" (Unix.realpath base_b)
    (origin_field original_b ~section:"workspace" "base_path");
  Ui.suspend_workspace_readings state_a;
  state_a.workspace_authority <- Ui.Workspace_authority 1;
  state_a.server_identity <- Some (identity base_b);
  List.iter (fun (ready : Protocol.async_msg Results.ready) ->
    check bool "old actual observations cannot borrow the replacement workspace" true (apply state_a ready.message=Refused)) batch_a;
  check_captured_batch original_a batch_a;
  check bool "second actual workspace admits only its own results" true
    (apply_batch state_b (ref []) batch_b=Some (Ok ()));
  exact_task state_b task_b;
  check bool "both actual Task resources remain unchanged" true
    (before_a=Masc.Workspace.get_tasks_raw config_a && before_b=Masc.Workspace.get_tasks_raw config_b)

let test_actual_read_keeps_admission_identity_after_health_changes () = with_answer @@ fun base config ask resolution task_id state ->
  Eio.Switch.run @@ fun sw -> Eio_context.with_turn_switch sw @@ fun () ->
  let before=Masc.Workspace.get_tasks_raw config and results=Results.create () in
  Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  let original_identity=match state.Ui.server_identity with Some value -> value | None -> fail "actual workspace identity missing" in
  let request,submission=begin_read state and left,resolve=Eio.Promise.create () in
  launch state results request submission ~released:(fun () -> ignore (Eio.Promise.try_resolve resolve ()))
    (actual_read base ask resolution ~parts:(ref []) ~before_source:(fun _ -> ()));
  Eio.Promise.await left;
  let first_batch=Results.take_ready results in let first=first_read first_batch in
  (* Protocol metadata changes, not an installed-binary or restart claim. *)
  let refreshed={original_identity with sid_binary_commit="newly-reported-protocol-identity";
    sid_version="newly-reported-protocol-version"} in
  state.server_identity <- Some refreshed;
  check string "held actual response retains identity observed at its admission" original_identity.sid_binary_commit
    (origin_field first ~section:"server_identity_at_admission" "reported_binary_commit");
  check_captured_batch first first_batch;
  check bool "same-workspace health metadata refresh does not revoke the actual original result" true
    (apply_batch state (ref []) first_batch=Some (Ok ()));
  let request,submission=begin_read state and left,resolve=Eio.Promise.create () in
  launch state results request submission ~released:(fun () -> ignore (Eio.Promise.try_resolve resolve ()))
    (actual_read base ask resolution ~parts:(ref []) ~before_source:(fun _ -> ()));
  Eio.Promise.await left;
  let second_batch=Results.take_ready results in let second=first_read second_batch in
  check string "same actual TUI instance persists across reads" (instance_id first) (instance_id second);
  check string "next original read captures newly observed admission identity" refreshed.sid_binary_commit
    (origin_field second ~section:"server_identity_at_admission" "reported_binary_commit");
  check string "earlier read is never relabelled by later health data" original_identity.sid_binary_commit
    (origin_field first ~section:"server_identity_at_admission" "reported_binary_commit");
  check_captured_batch second second_batch;
  check bool "next actual original result applies under its own ticket" true
    (apply_batch state (ref []) second_batch=Some (Ok ()));
  exact_task state task_id;
  check bool "provenance never mutates actual Task resources" true (before=Masc.Workspace.get_tasks_raw config)

module Task_read = Masc_tui_original_task_read
module Task_decode = Masc.Tui_decode_task_inspection
let require_inspection = function Some value -> value | None -> fail "original Task inspection did not begin"
let inspect_source state =
  let reader=Ui.current_task_inspector state |> require_inspection in
  Ui.task_inspection_source reader.tci_original
let observe_actual_answer state base ask resolution =
  let request,submission=begin_read state in
  let result=actual_read base ask resolution ~before_source:(fun _ -> ()) ~parts:(ref [])
    (fun (event,_) -> match Ui.take_ask_followup_event state request submission event with
      | Some (Ok _) -> () | Some (Error detail) -> fail detail | None -> fail "actual answer source refused") in
  check bool "actual canonical follow-up completed" true
    (Ui.finish_ask_followup_read state request submission (Result.map_error (fun detail -> Projection.Followup_read_failed detail) result)=Some (Ok ()))
let launch_task_observation state results request deliver read =
  let envelope=Protocol.capture_workspace_message state in
  Results.launch ~key:request.Ui.tcr_job ~observation:true state ~results
    ~boundary_error:(fun detail -> Task_read.Read_failed detail)
    ~deliver:(fun result -> envelope (deliver result)) read
let rec next_inspection_result results = match Results.take_ready results with
  | [ready] -> ready.Results.message
  | [] -> Eio.Fiber.yield ();next_inspection_result results
  | _ -> fail "one original inspection produced multiple results"
let admit_task_observation state = function
  | Protocol.Workspace_scoped (authority,reading,message) ->
    Protocol.workspace_message_admitted state ~authority ~reading message &&
    (match message with
     | Original_task_read_done (request,result) -> Ui.complete_original_task_inspection state request result
     | Original_task_history_done (request,result) -> Ui.complete_original_history_inspection state request result
     | Original_task_evidence_done (request,result) -> Ui.complete_original_evidence_inspection state request result
     | _ -> fail "original Task inspection changed message kind")
  | _ -> fail "Task inspection lost its captured read authority"
let actual_task_read config request =
  let ticket=match request.Ui.tcr_query with Ui.Original_task_query ticket -> ticket
    | Creation_query _ | Original_history_query _ | Original_evidence_query _ -> fail "Task query changed kind" in
  let task_id=Task_read.task_request_key ticket in
  let status,json=Server_dashboard_task_detail.inspect ~config ~task_id:(Some task_id)
    |> Server_dashboard_task_detail.inspection_response in
  match status with
  | `OK -> Task_decode.observation ~task_id json
    |> Result.map_error (fun detail -> Task_read.Invalid_reply detail)
    |> fun result -> Result.bind result (Task_read.prepare_task ~task_id)
  | `Bad_request | `Not_found | `Service_unavailable -> Error (Task_read.Read_failed (Yojson.Safe.to_string json))
let actual_history_read config request =
  let ticket=match request.Ui.tcr_query with Ui.Original_history_query ticket -> ticket
    | Creation_query _ | Original_task_query _ | Original_evidence_query _ -> fail "history query changed kind" in
  let page=Task_read.history_page_request ticket in
  let status,json=Server_dashboard_task_history_page.read ~config ~task_id:(Some page.hr_task_id)
    ~limit:(Some (string_of_int page.hr_limit)) ~cursor:page.hr_cursor in
  match status with
  | `OK -> Task_decode.history_page ~request:page json
    |> Result.map_error (fun detail -> Task_read.Invalid_reply detail) |> Result.map Task_read.prepare_history
  | `Bad_request | `Conflict | `Service_unavailable -> Error (Task_read.Read_failed (Yojson.Safe.to_string json))
let test_answered_ask_opens_actual_task_history_evidence () = with_answer @@ fun base config ask resolution task_id state ->
  Eio.Switch.run @@ fun sw -> Eio_context.with_turn_switch sw @@ fun () ->
  observe_actual_answer state base ask resolution;
  let transition action notes = match Masc.Workspace.transition_r config ~agent_name:"proof-worker" ~task_id ~action ~notes
    ~prepare_verification_request:(fun ~task ~assignee ~verification_id ~claim ->
      Masc.Verification_protocol.create_submit_request ~config ~task ~assignee ~verification_id ~claim) () with
    | Ok _ -> () | Error error -> fail (Masc_domain.masc_error_to_string error) in
  transition Masc_domain.Claim "claim original answered Task";
  transition Masc_domain.Start "start original answered Task";
  transition Masc_domain.Submit_for_verification "captured proof from original answered Task";
  let verification_id=match (List.find (fun (task : Masc_domain.task) -> task.id=task_id)
      (Masc.Workspace.get_tasks_raw config)).task_status with
    | AwaitingVerification value -> value.verification_id
    | Todo | Claimed _ | InProgress _ | Done _ | Cancelled _ -> fail "actual Task did not submit" in
  (match Masc.Workspace.commit_verdict_r config ~authority:(Masc_domain.Human_operator {operator_id="ask-task-reader"})
    ~task_id ~verification_id ~verdict:Masc_domain.Verdict_approved ~notes:"actual private fixture verdict" () with
   | Ok _ -> () | Error error -> fail (Masc_domain.masc_error_to_string error));
  let before=Masc.Workspace.get_tasks_raw config in
  state.msg_target_keeper_name <- Some "unrelated-composer-keeper";
  state.tasks_error <- Some "global listing unavailable";
  Masc_tui_message_input.insert state.msg_input "unrelated draft remains";
  check bool "canonical Ask opens independently of global rows or composer target" true (Ui.open_ask_task_inspection state);
  check bool "Ask has no creation lookup to manufacture or send" true
    (Task_read.observation (inspect_source state)=None && Ui.begin_task_creation_inspection state=None);
  let results=Results.create () in
  Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  let request=Ui.begin_original_task_inspection state |> require_inspection in
  launch_task_observation state results request (fun result -> Protocol.Original_task_read_done (request,result))
    (fun () -> actual_task_read config request);
  check bool "actual original Task observation admitted" true (admit_task_observation state (next_inspection_result results));
  (match Task_read.task_observation (inspect_source state) with
   | Masc_tui_fetched.Ready (Task_decode.In_backlog detail) ->
     check string "exact canonical Ask Task" task_id detail.task.id;
     (match detail.task.task_status with Done _ -> () | _ -> fail "actual Task verdict not preserved")
   | _ -> fail "original Task disappeared behind unrelated listing failure");
  let rec history earlier =
    let request=Ui.begin_original_history_inspection state ~earlier ~limit:1 |> require_inspection in
    launch_task_observation state results request (fun result -> Protocol.Original_task_history_done (request,result))
      (fun () -> actual_history_read config request);
    check bool "actual original history page admitted" true (admit_task_observation state (next_inspection_result results));
    match Task_read.history_observation (inspect_source state) with
    | Masc_tui_fetched.Ready value when Option.is_some value.history_next_cursor -> history true
    | Ready value -> value | _ -> fail "actual stored Task history unavailable" in
  let observed=history false in
  check bool "original stored history retains submitted verification" true (List.mem verification_id observed.history_verifications);
  let request=Ui.begin_original_evidence_inspection state ~next:true |> require_inspection in
  let ticket=match request.tcr_query with Ui.Original_evidence_query ticket -> ticket
    | Creation_query _ | Original_task_query _ | Original_history_query _ -> fail "evidence query changed kind" in
  check string "pinned original evidence Task" task_id (Task_read.evidence_task_id ticket);
  check string "pinned original verification" verification_id (Task_read.evidence_verification_id ticket);
  launch_task_observation state results request (fun result -> Protocol.Original_task_evidence_done (request,result)) (fun () ->
    Server_routes_http_routes_verification.For_testing.operator_evidence_json ~config ~operator_id:"ask-task-reader"
      ~task_id ~verification_id |> Result.map_error (fun detail -> Task_read.Read_failed detail)
    |> fun result -> Result.bind result (fun json ->
      Masc.Tui_decode.decode_verification_evidence_for_request ~task_id ~verification_id (`Assoc ["ok",`Bool true;"result",json])
      |> Result.map_error (fun detail -> Task_read.Invalid_reply detail)
      |> fun result -> Result.bind result (Task_read.prepare_evidence ~task_id ~verification_id)));
  check bool "actual original submitted evidence admitted" true (admit_task_observation state (next_inspection_result results));
  (match Task_read.evidence_observation (inspect_source state) with
   | Masc_tui_fetched.Ready (Masc.Tui_decode.Evidence_items items) -> check bool "actual captured proof retained" true (items<>[])
   | _ -> fail "actual submitted proof unavailable");
  check bool "reads leave actual Task and all completion resources unchanged" true (before=Masc.Workspace.get_tasks_raw config);
  check bool "no replay, creation, handoff or global listing substitution" true
    (state.task_dispatch_requests=[] && state.pending_task_followups=[] && state.tasks=[] && Ui.task_domain_values state=[]);
  check string "unrelated operator input survives all observations" "unrelated draft remains" (Masc_tui_message_input.contents state.msg_input)
let test_answered_ask_inspection_reopen_and_withdraw () = with_answer @@ fun base config ask resolution task_id state ->
  Eio.Switch.run @@ fun sw -> Eio_context.with_turn_switch sw @@ fun () ->
  observe_actual_answer state base ask resolution;
  check bool "original Ask opens" true (Ui.open_ask_task_inspection state);
  let results=Results.create () in
  Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  let request=Ui.begin_original_task_inspection state |> require_inspection in
  launch_task_observation state results request (fun result -> Protocol.Original_task_read_done (request,result)) (fun () -> actual_task_read config request);
  let late=next_inspection_result results in
  Ui.close_task_inspection state ~reason:Task_read.Interrupted;
  check bool "same canonical Ask reopens" true (Ui.open_ask_task_inspection state);
  let fresh=Ui.begin_original_task_inspection state |> require_inspection in
  check bool "old visit cannot finish reopened original Task" false (admit_task_observation state late);
  launch_task_observation state results fresh (fun result -> Protocol.Original_task_read_done (fresh,result)) (fun () -> actual_task_read config fresh);
  check bool "fresh exact Task observation applies" true (admit_task_observation state (next_inspection_result results));
  let retry=Ui.begin_original_task_inspection state |> require_inspection in
  check bool "read failure settles this original source" true
    (Ui.complete_original_task_inspection state retry (Error (Task_read.Read_failed "original source disconnected")));
  (match Task_read.task_observation (inspect_source state) with
   | Masc_tui_fetched.Stale (Task_decode.In_backlog detail,Task_read.Read_failed _) -> check string "failure preserves original Task" task_id detail.task.id
   | _ -> fail "failure erased previous Task observation");
  let pending=Ui.begin_original_task_inspection state |> require_inspection in
  launch_task_observation state results pending (fun result -> Protocol.Original_task_read_done (pending,result)) (fun () -> actual_task_read config pending);
  let old_scope=next_inspection_result results in
  Ui.suspend_workspace_readings state;
  check bool "original Ask can reopen under a fresh read scope" true (Ui.open_ask_task_inspection state);
  let pending=Ui.begin_original_task_inspection state |> require_inspection in
  check bool "withdrawn read scope cannot finish the reopened source" false (admit_task_observation state old_scope);
  launch_task_observation state results pending (fun result -> Protocol.Original_task_read_done (pending,result)) (fun () -> actual_task_read config pending);
  let withdrawn=next_inspection_result results in
  let before=Masc.Workspace.get_tasks_raw config in
  Ui.begin_ask_submission_state state;
  check bool "new answer owner retires original inspector" true (Ui.current_task_inspector state=None && state.ask_task_inspection=None);
  check bool "old actual Task result cannot become a new question's result" false (admit_task_observation state withdrawn);
  check bool "no canonical Task authority is borrowed after withdrawal" false (Ui.open_ask_task_inspection state);
  check bool "withdrawal preserves actual resources" true (before=Masc.Workspace.get_tasks_raw config)


let test_actual_followup_structured_sink_and_export () = with_answer @@ fun base config ask resolution task_id state ->
  (* Last case: the process-global production sink owns its channel until exit.
     This private directory is removed only after all sink reads have finished. *)
  Log.set_level Log.Info;
  let server_logs=Filename.concat (Masc.Workspace.masc_dir config) "logs" in
  Fs_compat.mkdir_p server_logs;
  Log.Ring.init_file_sink server_logs;
  Log.Server.info "Original server log resource before client storage";
  let stored_files directory=Array.to_list (Sys.readdir directory)
    |> List.filter_map (fun name ->
      let path=Filename.concat directory name in
      if Sys.is_directory path then None else
        Some (name,In_channel.with_open_bin path In_channel.input_all))
    |> List.sort (fun (left,_) (right,_) -> String.compare left right) in
  let server_before=stored_files server_logs in
  let log_dir=Masc_tui_observation_store.initialize ~base_path:base |> require in
  let since_seq=(Log.Ring.bounds ()).total-1 in
  let before=Masc.Workspace.get_tasks_raw config in
  let run_read before_source = Eio.Switch.run @@ fun sw -> Eio_context.with_turn_switch sw @@ fun () ->
    let results=Results.create () in
    Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
    let left,release=Eio.Promise.create () in
    let request,submission=begin_read state in
    launch state results request submission ~released:(fun () -> ignore (Eio.Promise.try_resolve release ()))
      (actual_read base ask resolution ~parts:(ref []) ~before_source);
    Eio.Promise.await left;
    let batch=Results.take_ready results in
    let read=first_read batch in
    read,apply_batch state (ref []) batch in
  let completed,result=run_read (fun _ -> ()) in
  check bool "actual completed source retained" true (result=Some (Ok ()));
  exact_task state task_id;
  let failed,result=run_read (function
    | Wake.Reaction_evidence _ -> raise (Sys_error "private disconnect explanation")
    | Linked_task _ | Tool_results _ -> ()) in
  (match result with
   | Some (Error (Projection.Followup_read_failed _)) -> ()
   | Some _ | None -> fail "actual failed source lost its terminal");
  let results=Results.create () in
  Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  check bool "missing switch is an actual dispatch boundary" true (Option.is_none (Eio_context.get_switch_opt ()));
  let request,submission=begin_read state in
  launch state results request submission ~released:(fun () -> ())
    (actual_read base ask resolution ~parts:(ref []) ~before_source:(fun _ -> ()));
  let batch=Results.take_ready results in
  let unstarted=first_read batch in
  (match apply_batch state (ref []) batch with
   | Some (Error (Projection.Followup_not_started _)) -> ()
   | Some _ | None -> fail "unstarted original source lost its terminal");
  let entries=Log.Ring.recent ~limit:Log.Ring.capacity ~since_seq ~module_filter:"Transport" () in
  let exported=Server_dashboard_logs_json.build ~config ~limit:Log.Ring.capacity
    ~level_filter:"info" ~applied_level:Log.Info ~min_level:(Log.level_to_int Log.Info)
    ~module_filter:"Transport" ~since_seq:(Some since_seq) ~before_seq:None
    ~category_filter:(Some "lifecycle") ~exclude_category:None ~ring_bounds:(Log.Ring.bounds ()) entries in
  let decoded=Masc.Tui_decode.decode_system_log_snapshot exported |> require in
  let disk=Array.to_list (Sys.readdir log_dir) |> List.concat_map (fun name ->
    let path=Filename.concat log_dir name in
    let channel=open_in path in
    Fun.protect ~finally:(fun () -> close_in channel) @@ fun () ->
    In_channel.input_lines channel |> List.map (fun line -> Log.Ring.entry_of_json (Yojson.Safe.from_string line))) in
  let member key json=Yojson.Safe.Util.member key json in
  let originals=[completed;failed;unstarted] in
  let selected (entry : Masc.Tui_decode.system_log_entry) =
    member "event" entry.sl_details=`String "tui_ask_followup" in
  let observed=List.filter selected decoded.sys_entries in
  check bool "actual exported structured observations exist" true (observed<>[]);
  List.iter (fun (entry : Masc.Tui_decode.system_log_entry) ->
    let details=entry.sl_details in
    check bool "structured row retains original Info lifecycle channel" true
      (entry.sl_level=Masc.Tui_decode.System_info && entry.sl_category=Some "lifecycle" && entry.sl_keeper=Some "alpha");
    let original=List.find (fun (read : Protocol.ask_followup_read) ->
      member "request" details=`Int (Ui.Snapshot_read.request_id read.afr_request)) originals in
    check string "export preserves original capsule provenance"
      (Yojson.Safe.to_string (Masc_tui_observation_origin.to_json original.afr_origin))
      (Yojson.Safe.to_string (member "origin" details));
    let persisted=List.find (fun (row : Log.Ring.entry) -> row.seq=entry.sl_seq) disk in
    check string "daily JSONL and actual dashboard decoder preserve the same details"
      (Yojson.Safe.to_string persisted.details) (Yojson.Safe.to_string details)) observed;
  let has read phase completion = List.exists (fun (row : Masc.Tui_decode.system_log_entry) ->
    let details=row.sl_details in
    member "request" details=`Int (Ui.Snapshot_read.request_id read.Protocol.afr_request)
    && member "phase" details=`String phase && member "completion" details=completion) observed in
  check bool "producer return remains distinct from UI settlement" true
    (has completed "producer_returned" (Projection.followup_result_to_json (Ok ()))
     && has completed "finished" (Projection.followup_result_to_json (Ok ()))
     && has completed "registration_released" `Null);
  check bool "actual failed and unstarted attempts stay in exported denominator" true
    (has failed "finished" (Projection.followup_result_to_json (Error (Projection.Followup_read_failed "")))
     && has unstarted "finished" (Projection.followup_result_to_json (Error (Projection.Followup_not_started "")))
     && not (has unstarted "worker_entered" `Null));
  let first_before=stored_files log_dir in
  let replacement=Masc_tui_observation_store.initialize ~base_path:base |> require in
  check bool "same PID starts a fresh private client store" true (replacement<>log_dir);
  check bool "client store is private" true ((Unix.stat replacement).Unix.st_perm land 0o077=0);
  let replacement_before=stored_files replacement in
  check bool "new client sink imports no prior Ask payload" true
    (List.for_all (fun (_,body) ->
      String.split_on_char '\n' body |> List.filter (fun line -> line<>"")
      |> List.for_all (fun line ->
        member "event" (member "details" (Yojson.Safe.from_string line))<>`String "tui_ask_followup")) replacement_before);
  let blocker=Filename.concat base "blocked-log-base" in
  Out_channel.with_open_bin blocker (fun channel -> output_string channel "owned regular file");
  (match Masc_tui_observation_store.initialize ~base_path:blocker with
   | Error _ -> () | Ok _ -> fail "non-directory base unexpectedly initialized a store");
  let _read,result=run_read (fun _ -> ()) in
  check bool "actual original read continues after storage setup failure" true (result=Some (Ok ()));
  exact_task state task_id;
  check bool "replacement leaves original session bytes intact" true (first_before=stored_files log_dir);
  check bool "client stores do not append to server daily logs" true (server_before=stored_files server_logs);
  check bool "current store still receives actual original reads" true
    (List.exists (fun (_,body) ->
      String.split_on_char '\n' body |> List.filter (fun line -> line<>"")
      |> List.exists (fun line ->
        member "event" (member "details" (Yojson.Safe.from_string line))=`String "tui_ask_followup")) (stored_files replacement));
  check bool "observation and persistence do not mutate canonical Task resources" true
    (before=Masc.Workspace.get_tasks_raw config)

let () = Eio_main.run @@ fun env ->
  let original=Eio_context.snapshot_state () in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:(fun () -> Fs_compat.clear_fs ();Eio_context.restore_state original) (fun () ->
    run "TUI retained actual Ask follow-up results" ["protocol/resources",[
      test_case "actual partial and terminal observations survive a full shared queue" `Quick test_full_queue_keeps_partial_and_terminal;
      test_case "actual stream failure and old visits preserve original Task evidence" `Quick test_failure_and_reopened_scope_keep_original_facts;
      test_case "session close and missing turn switch preserve actual resources" `Quick test_session_close_and_unstarted_preserve_resources;
      test_case "actual follow-up cancellation settles only after producer cleanup" `Quick test_actual_followup_cancellation_settles_after_cleanup;
      test_case "cancelled dispatch retains an unstarted original observation and still propagates" `Quick test_cancelled_dispatch_retains_unstarted_original_observation;
      test_case "actual workspace reads preserve distinct original provenance across replacement" `Quick test_actual_workspaces_keep_distinct_original_provenance;
      test_case "actual original read retains admission identity after health metadata changes" `Quick test_actual_read_keeps_admission_identity_after_health_changes;
      test_case "canonical answered Ask opens actual Task history and submitted evidence" `Quick test_answered_ask_opens_actual_task_history_evidence;
      test_case "answered Ask inspection preserves failed observations and rejects old visits" `Quick test_answered_ask_inspection_reopen_and_withdraw;
      test_case "actual structured observations survive daily JSONL and dashboard decode" `Quick test_actual_followup_structured_sink_and_export]])
