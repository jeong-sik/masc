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
  let continuation=Keeper_continuation_channel.dashboard ~thread_id:"original-thread" |> require in
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
  let origin=Masc_tui_observation_origin.capture state.observation_instance ~expected_workspace in
  let admission_capture=Option.map (fun store ->
    Masc_tui_observation_store.record_admission store ~origin
      ~request:(Ui.Snapshot_read.request_id request) ~admission_started_ns) state.Ui.observation_store in
  let read=Protocol.capture_ask_followup_read ~origin ~request ~submission
    ~admission_started_ns ~admission_capture in
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
       && actual.afr_admission_capture==expected.afr_admission_capture
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
let actual_task_read ?reply_task_id config request =
  let ticket=match request.Ui.tcr_query with Ui.Original_task_query ticket -> ticket
    | Creation_query _ | Original_history_query _ | Original_evidence_query _ -> fail "Task query changed kind" in
  let task_id=Task_read.task_request_key ticket in
  let status,json=Server_dashboard_task_detail.inspect ~config ~task_id:(Some (Option.value ~default:task_id reply_task_id))
    |> Server_dashboard_task_detail.inspection_response in
  match status with
  | `OK -> Task_decode.observation ~task_id json
    |> Result.map_error (fun detail -> Task_read.Invalid_reply detail)
    |> fun result -> Result.bind result (Task_read.prepare_task ~task_id)
  | `Bad_request | `Not_found | `Service_unavailable -> Error (Task_read.Read_failed (Yojson.Safe.to_string json))
let actual_history_read ?reply_task_id config request =
  let ticket=match request.Ui.tcr_query with Ui.Original_history_query ticket -> ticket
    | Creation_query _ | Original_task_query _ | Original_evidence_query _ -> fail "history query changed kind" in
  let page=Task_read.history_page_request ticket in
  let status,json=Server_dashboard_task_history_page.read ~config ~task_id:(Some (Option.value ~default:page.hr_task_id reply_task_id))
    ~limit:(Some (string_of_int page.hr_limit)) ~cursor:page.hr_cursor in
  match status with
  | `OK -> Task_decode.history_page ~request:page json
    |> Result.map_error (fun detail -> Task_read.Invalid_reply detail) |> Result.map Task_read.prepare_history
  | `Bad_request | `Conflict | `Service_unavailable -> Error (Task_read.Read_failed (Yojson.Safe.to_string json))
let unrelated_inspection_task config =
  match Workspace_task_create.add_task_with_result config ~created_by:"other-inspection-source"
    ~title:"unrelated original source" ~priority:3 ~description:"different actual Task reply" with
  | Ok created -> created.task_id
  | Error error -> fail (Workspace_task_create.add_task_error_to_string error)
let evidence_ticket request = match request.Ui.tcr_query with
  | Ui.Original_evidence_query ticket -> ticket
  | Creation_query _ | Original_task_query _ | Original_history_query _ -> fail "evidence query changed kind"
let actual_evidence_read config request =
  let ticket=evidence_ticket request in
  let task_id=Task_read.evidence_task_id ticket and verification_id=Task_read.evidence_verification_id ticket in
  Server_routes_http_routes_verification.For_testing.operator_evidence_json ~config ~operator_id:"ask-task-reader"
    ~task_id ~verification_id |> Result.map_error (fun detail -> Task_read.Read_failed detail)
  |> fun result -> Result.bind result (fun json ->
    Masc.Tui_decode.decode_verification_evidence_for_request ~task_id ~verification_id (`Assoc ["ok",`Bool true;"result",json])
    |> Result.map_error (fun detail -> Task_read.Invalid_reply detail)
    |> fun result -> Result.bind result (Task_read.prepare_evidence ~task_id ~verification_id))
let submit_original_inspection_task config task_id =
  let transition action notes = match Masc.Workspace.transition_r config ~agent_name:"proof-worker" ~task_id ~action ~notes
    ~prepare_verification_request:(fun ~task ~assignee ~verification_id ~claim ->
      Masc.Verification_protocol.create_submit_request ~config ~task ~assignee ~verification_id ~claim) () with
    | Ok _ -> () | Error error -> fail (Masc_domain.masc_error_to_string error) in
  transition Masc_domain.Claim "claim original answered Task";
  transition Masc_domain.Start "start original answered Task";
  transition Masc_domain.Submit_for_verification "captured proof from original answered Task";
  match (List.find (fun (task : Masc_domain.task) -> task.id=task_id)
      (Masc.Workspace.get_tasks_raw config)).task_status with
  | AwaitingVerification value -> value.verification_id
  | Todo | Claimed _ | InProgress _ | Done _ | Cancelled _ -> fail "actual Task did not submit"
let test_answered_ask_opens_actual_task_history_evidence () = with_answer @@ fun base config ask resolution task_id state ->
  Eio.Switch.run @@ fun sw -> Eio_context.with_turn_switch sw @@ fun () ->
  observe_actual_answer state base ask resolution;
  let verification_id=submit_original_inspection_task config task_id in
  let foreign_task=unrelated_inspection_task config in
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
  let failed=Ui.begin_original_history_inspection state ~earlier:false ~limit:1 |> require_inspection in
  launch_task_observation state results failed (fun result -> Protocol.Original_task_history_done (failed,result))
    (fun () -> actual_history_read ~reply_task_id:foreign_task config failed);
  check bool "actual foreign history is refused under original Task and prefix retained" true
    (admit_task_observation state (next_inspection_result results));
  (match Task_read.history_observation (inspect_source state) with
   | Masc_tui_fetched.Stale (value,Task_read.Invalid_reply _) ->
     check bool "failed refresh retains actual original submission IDs" true (List.mem verification_id value.history_verifications)
   | _ -> fail "foreign history replaced or erased the original prefix");
  let request=Ui.begin_original_evidence_inspection state ~next:true |> require_inspection in
  let ticket=evidence_ticket request in
  check string "pinned original evidence Task" task_id (Task_read.evidence_task_id ticket);
  check string "pinned original verification" verification_id (Task_read.evidence_verification_id ticket);
  (match Task_read.evidence_basis (inspect_source state) with
   | Some {eb_source=Task_read.From_history;eb_observation=Selection_retained (Invalid_reply _)} -> ()
   | Some _ | None -> fail "retained history selection lost its original failure basis");
  launch_task_observation state results request (fun result -> Protocol.Original_task_evidence_done (request,result))
    (fun () -> actual_evidence_read config request);
  check bool "actual original submitted evidence admitted" true (admit_task_observation state (next_inspection_result results));
  (match Task_read.evidence_observation (inspect_source state) with
   | Masc_tui_fetched.Ready (Masc.Tui_decode.Evidence_items items) -> check bool "actual captured proof retained" true (items<>[])
   | _ -> fail "actual submitted proof unavailable");
  check bool "reads leave original and unrelated Task records unchanged" true (before=Masc.Workspace.get_tasks_raw config);
  check bool "no replay, creation, handoff or global listing substitution" true
    (state.task_dispatch_requests=[] && state.pending_task_followups=[] && state.tasks=[] && Ui.task_domain_values state=[]);
  check string "unrelated operator input survives all observations" "unrelated draft remains" (Masc_tui_message_input.contents state.msg_input)
let test_retained_task_submission_keeps_selection_basis () = with_answer @@ fun base config ask resolution task_id state ->
  Eio.Switch.run @@ fun sw -> Eio_context.with_turn_switch sw @@ fun () ->
  observe_actual_answer state base ask resolution;
  let verification_id=submit_original_inspection_task config task_id in
  let foreign_task=unrelated_inspection_task config in
  let before=Masc.Workspace.get_tasks_raw config in
  Masc_tui_message_input.insert state.msg_input "new input survives retained proof inspection";
  check bool "original answered Ask opens for submitted Task" true (Ui.open_ask_task_inspection state);
  let results=Results.create () in
  Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  let original=Ui.begin_original_task_inspection state |> require_inspection in
  launch_task_observation state results original (fun result -> Protocol.Original_task_read_done (original,result))
    (fun () -> actual_task_read config original);
  check bool "actual submitted original Task admitted" true (admit_task_observation state (next_inspection_result results));
  let failed=Ui.begin_original_task_inspection state |> require_inspection in
  launch_task_observation state results failed (fun result -> Protocol.Original_task_read_done (failed,result))
    (fun () -> actual_task_read ~reply_task_id:foreign_task config failed);
  check bool "actual foreign Task reply settles as a rejected refresh" true (admit_task_observation state (next_inspection_result results));
  (match Task_read.task_observation (inspect_source state) with
   | Masc_tui_fetched.Stale (Task_decode.In_backlog detail,Task_read.Invalid_reply _) ->
     (match detail.task.task_status with
      | AwaitingVerification value -> check string "original actual submission retained" verification_id value.verification_id
      | Todo | Claimed _ | InProgress _ | Done _ | Cancelled _ -> fail "retained original submission lost")
   | _ -> fail "failed refresh erased original Task observation");
  let first=Ui.begin_original_evidence_inspection state ~next:true |> require_inspection in
  check string "retained original Task selects exact submission" verification_id
    (Task_read.evidence_verification_id (evidence_ticket first));
  (match Task_read.evidence_basis (inspect_source state) with
   | Some {eb_source=Task_read.From_task;eb_observation=Selection_retained (Invalid_reply _)} -> ()
   | Some _ | None -> fail "retained Task selection lost failure context");
  (* Retire that unstarted evidence read, begin a Task retry, then explicitly
     select the retained submission while that retry is still pending. *)
  let retry=Ui.begin_original_task_inspection state |> require_inspection in
  let selected=Ui.begin_original_evidence_inspection state ~next:true |> require_inspection in
  let basis=match Task_read.evidence_basis (inspect_source state) with
    | Some ({eb_source=Task_read.From_task;eb_observation=Selection_retrying (Invalid_reply _)} as basis) -> basis
    | Some _ | None -> fail "selection borrowed later suspension instead of original pending/failure context" in
  check bool "retired Task retry cannot replace selected evidence source" false
    (Ui.complete_original_task_inspection state retry (actual_task_read config retry));
  check bool "retired first evidence ticket cannot replace the next selection" false
    (Ui.complete_original_evidence_inspection state first (actual_evidence_read config first));
  launch_task_observation state results selected (fun result -> Protocol.Original_task_evidence_done (selected,result))
    (fun () -> actual_evidence_read config selected);
  check bool "original retained submission reads its actual stored proof" true (admit_task_observation state (next_inspection_result results));
  (match Task_read.evidence_observation (inspect_source state) with
   | Masc_tui_fetched.Ready (Masc.Tui_decode.Evidence_items items) -> check bool "actual retained proof items" true (items<>[])
   | _ -> fail "retained original submission proof unavailable");
  let refresh=Ui.begin_original_evidence_inspection state ~next:false |> require_inspection in
  check string "evidence refresh preserves pinned submission" verification_id
    (Task_read.evidence_verification_id (evidence_ticket refresh));
  check bool "evidence refresh preserves exact selection-time basis" true
    (match Task_read.evidence_basis (inspect_source state) with Some retained -> retained==basis | None -> false);
  check bool "original Task resources remain unchanged by proof inspection" true (before=Masc.Workspace.get_tasks_raw config);
  check string "operator input remains unchanged" "new input survives retained proof inspection"
    (Masc_tui_message_input.contents state.msg_input)

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


let test_actual_followup_report_keeps_unobserved_and_bad_artifacts () =
  with_answer @@ fun base config ask resolution _task state ->
  with_answer @@ fun base2 config2 ask2 resolution2 _task2 state2 ->
  let resources=Masc.Workspace.get_tasks_raw config and resources2=Masc.Workspace.get_tasks_raw config2 in
  Log.set_level Log.Info;
  let packet_dir=Filename.temp_dir ~temp_dir:base "comparison-packet-" "" in
  let sha bytes=Digestif.SHA256.(to_hex (digest_string bytes)) in
  let copy_logs label directory=Array.to_list (Sys.readdir directory)
    |> List.filter (fun name -> not (Sys.is_directory (Filename.concat directory name))) |> List.mapi (fun index name ->
    let body=In_channel.with_open_bin (Filename.concat directory name) In_channel.input_all in
    let relative=Printf.sprintf "%s-%d.jsonl" label index in
    Out_channel.with_open_bin (Filename.concat packet_dir relative) (fun channel -> output_string channel body);
    `Assoc ["path",`String relative;"sha256",`String (sha body)]) in
  let copy_admissions label store =
    let body=In_channel.with_open_bin (Masc_tui_observation_store.admissions_path store) In_channel.input_all in
    let relative=label ^ "-admissions.jsonl" in
    Out_channel.with_open_bin (Filename.concat packet_dir relative) (fun channel -> output_string channel body);
    [`Assoc ["path",`String relative;"sha256",`String (sha body)]] in
  let declaration (read : Protocol.ask_followup_read)=`Assoc [
    "instance_id",`String (instance_id read);
    "request",`Int (Ui.Snapshot_read.request_id read.afr_request);
    "read_admission_started_ns",`Intlit (Int64.to_string read.afr_admission_started_ns)] in
  let before_store=Masc_tui_observation_store.initialize ~base_path:base |> require in
  state.observation_store <- Some before_store;
  let before_dir=Masc_tui_observation_store.directory before_store in
  let blocked_admission=Masc_tui_observation_store.admissions_path before_store in
  Sys.remove blocked_admission;
  Unix.mkdir blocked_admission 0o700;
  let results=Results.create () in
  let request,submission=begin_read state in
  launch state results request submission ~released:(fun () -> ())
    (actual_read base ask resolution ~parts:(ref []) ~before_source:(fun _ -> ()));
  let batch=Results.take_ready results in
  let unstarted=first_read batch in
  (match apply_batch state (ref []) batch with
   | Some (Error (Projection.Followup_not_started _)) -> ()
   | Some _ | None -> fail "actual missing-switch attempt did not settle");
  Results.close results;
  Unix.rmdir blocked_admission;
  Out_channel.with_open_gen [Open_wronly;Open_creat;Open_excl;Open_binary]
    0o600 blocked_admission (fun _ -> ());
  let complete_read state base ask resolution =
    Eio.Switch.run @@ fun sw -> Eio_context.with_turn_switch sw @@ fun () ->
    let results=Results.create () in
    Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
    let left,release=Eio.Promise.create () in
    let request,submission=begin_read state in
    launch state results request submission ~released:(fun () -> ignore (Eio.Promise.try_resolve release ()))
      (actual_read base ask resolution ~parts:(ref []) ~before_source:(fun _ -> ()));
    Eio.Promise.await left;
    let batch=Results.take_ready results in
    let read=first_read batch in
    check bool "actual comparison source settles" true (apply_batch state (ref []) batch=Some (Ok ()));
    read in
  let before_completed=complete_read state base ask resolution in
  (* This original admitted read is never dispatched. Its Info observation is
     filtered, but the production admission journal must retain its identity. *)
  let admission_started_ns=Mtime_clock.elapsed_ns () in
  let request,submission=begin_read state in
  let origin=Origin.capture state.observation_instance ~expected_workspace:(identity base) in
  let unobserved=Fun.protect ~finally:(fun () -> Log.set_level Log.Info) (fun () ->
    Log.set_level Log.Warn;
    let capture=Masc_tui_observation_store.record_admission before_store ~origin
      ~request:(Ui.Snapshot_read.request_id request) ~admission_started_ns in
    (match capture.capture_outcome with
     | Masc_tui_observation_store.Capture_returned -> ()
     | Capture_failed detail -> fail detail);
    let read=Protocol.capture_ask_followup_read ~origin ~request ~submission
      ~admission_started_ns ~admission_capture:(Some capture) in
    Observation.emit read ~sources:None Observation.Followup_read_started;
    read) in
  let before_admissions=copy_admissions "before" before_store in
  let before_logs=copy_logs "before" before_dir in
  let after_store=Masc_tui_observation_store.initialize ~base_path:base2 |> require in
  state2.observation_store <- Some after_store;
  let after_dir=Masc_tui_observation_store.directory after_store in
  let completed=complete_read state2 base2 ask2 resolution2 in
  let after_logs=copy_logs "after" after_dir in
  let after_admissions=copy_admissions "after" after_store in
  let member=Yojson.Safe.Util.member in
  let matches_declaration read row =
    let expected=Yojson.Safe.from_string (Yojson.Safe.to_string (declaration read)) in
    List.for_all (fun key -> member key (member "identity" row)=member key expected)
      ["instance_id";"request";"read_admission_started_ns"] in
  let conditions=`Assoc (List.map (fun key -> key,`Null)
    ["fixture";"workspace_snapshot";"action";"server_binary";"terminal"]) in
  let arm reads logs admissions=`Assoc ["instances",`List [`String (instance_id (List.hd reads))];
    "attempts",`List (List.map declaration reads);"condition_files",conditions;
    "source_commit",`Null;"binary",`Null;
    "logs",`List (List.map (member "path") logs);
    "admissions",`List (List.map (member "path") admissions)] in
  let plan=`Assoc ["schema_version",`Int 1;"cases",`List [`Assoc ["id",`String "actual-protocol-resources";
    "before",arm [unstarted;before_completed] before_logs before_admissions;"after",arm [completed] after_logs after_admissions]]] in
  let plan_bytes=Yojson.Safe.to_string plan in
  let plan_path=Filename.concat packet_dir "plan.json" in
  Out_channel.with_open_bin plan_path (fun channel -> output_string channel plan_bytes);
  let script_dir=Filename.concat (Filename.dirname Sys.executable_name) "../scripts/harness/perf" in
  let run args =
    let argv=Array.of_list ("python3"::args) in
    let pid=Unix.create_process "python3" argv Unix.stdin Unix.stdout Unix.stderr in
    snd (Unix.waitpid [] pid) in
  let materialize_plan path output=run [Filename.concat script_dir "tui_ask_followup_packet.py";path;
    "--source-root";packet_dir;"--output";output] in
  let materialize=materialize_plan plan_path in
  let output=Filename.concat packet_dir "materialized" in
  check bool "actual original artifacts materialize through public CLI" true (materialize output=Unix.WEXITED 0);
  let receipt=Yojson.Safe.from_file (Filename.concat output "materialization.json") in
  check bool "materialization never certifies execution or complete capture" true
    (member "execution_verified" receipt=`Bool false && member "complete_capture_verified" receipt=`Bool false
     && member "atomic_cohort_snapshot_verified" receipt=`Bool false);
  check string "materializer preserves independent original plan bytes" plan_bytes
    (In_channel.with_open_bin (Filename.concat output "source-plan.json") In_channel.input_all);
  let packet_path=Filename.concat output "packet.json" in
  let packet_bytes=In_channel.with_open_bin packet_path In_channel.input_all in
  let packet=Yojson.Safe.from_string packet_bytes in
  let json_path=Filename.concat output "report.json" and markdown_path=Filename.concat output "report.md" in
  let report () =
    let status=run [Filename.concat script_dir "tui_ask_followup_report.py";packet_path;
      "--json";json_path;"--markdown";markdown_path] in
    status,Yojson.Safe.from_file json_path in
  let status,reported=report () in
  check bool "actual artifacts yield a descriptive report" true (status=Unix.WEXITED 0);
  let case=match member "cases" reported with `List [case] -> case | _ -> fail "report lost its original case" in
  let outcomes arm=member "outcomes" (member "summary" (member arm case)) in
  check bool "actual unstarted and declared unobserved reads stay in denominator" true
    (member "not_started" (outcomes "before")=`Int 1 && member "unobserved" (outcomes "before")=`Int 1);
  let before_attempts=match member "attempts" (member "before" case) with `List rows -> rows | _ -> fail "admitted attempts lost" in
  check bool "actual capture failure remains separate from unstarted read outcome" true
    (member "observed_failures" (member "admission_capture" (member "summary" (member "before" case)))=`Int 1
     && List.exists (fun row -> member "outcome" row=`String "not_started"
       && (match member "capture_failures" row with
           | `List [failure] -> member "origin" failure=Masc_tui_observation_origin.to_json unstarted.afr_origin
           | _ -> false)) before_attempts);
  let after_attempts=match member "attempts" (member "after" case) with
    | `List rows -> rows | _ -> fail "completed attempts lost" in
  check bool "actual successful capture receipt reaches report exactly once per original read" true
    (match after_attempts with
     | [row] -> let receipt=member "admission_capture" row in
       member "state" receipt=`String "returned"
       && member "admission_capture_ns" (member "metrics" row)<>`Null
       && member "observed" (member "admission_capture_ns" (member "metrics"
         (member "summary" (member "after" case))))=`Int 1
     | _ -> false);
  check bool "actual failed capture receipt remains distinct from read not-started" true
    (List.exists (fun row -> member "outcome" row=`String "not_started"
       && member "state" (member "admission_capture" row)=`String "failed"
       && member "admission_capture_ns" (member "metrics" row)<>`Null) before_attempts);
  check bool "filtered admission has original file evidence without a supplied declaration" true
    (List.exists (fun row ->
       matches_declaration unobserved row
       && member "outcome" row=`String "unobserved"
       && (match member "admission_evidence" row with `List (_::_) -> true | _ -> false)) before_attempts);
  check bool "actual completed read remains its own outcome" true (member "complete" (outcomes "after")=`Int 1);
  check bool "unknown conditions never become matching or execution proof" true
    (member "declared_conditions_match" (member "comparison" case)=`Bool false
     && member "execution_verified" (member "comparison" case)=`Bool false);
  let set key value = function
    | `Assoc fields -> `Assoc ((key,value)::List.remove_assoc key fields)
    | _ -> fail "expected actual report object" in
  (* Reuse supplied bytes as declared-only condition inputs. Matching hashes
     are required to reach the comparative path; they certify no execution. *)
  let matching_conditions=match conditions with
    | `Assoc fields -> `Assoc (List.map (fun (key,_) -> key,`String "plan.json") fields)
    | _ -> fail "condition declaration missing" in
  let matching_arm name original=set "condition_files" matching_conditions (member name original) in
  let matching_case=match member "cases" plan with
    | `List [original] -> set "after" (matching_arm "after" original)
        (set "before" (matching_arm "before" original) original)
    | _ -> fail "original materialization case missing" in
  let write_plan name case =
    let path=Filename.concat packet_dir name in
    Out_channel.with_open_bin path (fun channel -> output_string channel
      (Yojson.Safe.to_string (set "cases" (`List [case]) plan)));
    path in
  let matching_path=write_plan "matching-plan.json" matching_case in
  let matching_output=Filename.concat packet_dir "matching-materialization" in
  check bool "actual sources reach the declared matching comparison path" true
    (materialize_plan matching_path matching_output=Unix.WEXITED 0);
  let validation_case output=match member "cases"
      (Yojson.Safe.from_file (Filename.concat output "validation.json")) with
    | `List [case] -> case | _ -> fail "materialization lost the original case" in
  let valid_case=validation_case matching_output in
  let valid_comparison=member "comparison" valid_case in
  check bool "original Task source contributes a numeric descriptive delta before capture failure" true
    (member "declared_conditions_match" valid_comparison=`Bool true
     && member "descriptive_delta_available" valid_comparison=`Bool true
     && (match member "source_received_to_processed_ns"
         (member "linked_task" (member "source_metrics" valid_comparison)) with
       | `Assoc _ -> true | _ -> false)
     && member "execution_verified" valid_comparison=`Bool false);
  let after=member "after" matching_case in
  let incomplete_logs=match member "logs" after with
    | `List logs -> `List (`String "missing-extra-source.jsonl"::logs)
    | _ -> fail "actual source artifact roster missing" in
  let incomplete_path=write_plan "incomplete-plan.json"
    (set "after" (set "logs" incomplete_logs after) matching_case) in
  let incomplete_output=Filename.concat packet_dir "incomplete-materialization" in
  check bool "one extra missing capture rejects otherwise comparable actual sources" true
    (materialize_plan incomplete_path incomplete_output=Unix.WEXITED 2);
  let incomplete_case=validation_case incomplete_output in
  let incomplete_comparison=member "comparison" incomplete_case in
  check bool "incomplete capture withdraws overall and source deltas together" true
    (member "declared_conditions_match" incomplete_comparison=`Bool true
     && member "descriptive_delta_available" incomplete_comparison=`Bool false
     && member "metrics" incomplete_comparison=`Assoc []
     && member "source_metrics" incomplete_comparison=`Assoc []
     && member "execution_verified" incomplete_comparison=`Bool false);
  check bool "failed publication retains observed sources and original attempt denominator" true
    (member "summary" (member "before" incomplete_case)=member "summary" (member "before" valid_case)
     && member "summary" (member "after" incomplete_case)=member "summary" (member "after" valid_case)
     && not (Sys.file_exists (Filename.concat incomplete_output "packet.json")));
  (* The real producer finishes before this case admits its queued sources.
     Replacing receipt by UI-processing time is therefore a contradictory
     same-owner clock fact, even though each individual row remains ordered. *)
  let completed_row=List.find (matches_declaration completed) after_attempts in
  let source_row=match member "records" completed_row with
    | `List rows -> List.find (fun row -> member "phase" row=`String "source_processed"
        && member "source" row=`String "linked_task") rows
    | _ -> fail "actual source processing record missing" in
  let source_evidence=member "evidence" source_row in
  check bool "source interval retains its original artifact reference" true
    (match member "observations" (member "linked_task" (member "source_observations" completed_row)) with
     | `List [row] -> member "evidence" row=source_evidence
     | _ -> false);
  let source_path=member "artifact" source_evidence |> Yojson.Safe.Util.to_string in
  let source_line=member "line" source_evidence |> Yojson.Safe.Util.to_int in
  let bytes=In_channel.with_open_bin (Filename.concat output source_path) In_channel.input_all in
  let changed=String.split_on_char '\n' bytes |> List.mapi (fun index line ->
    if index+1<>source_line then line else
    let entry=Yojson.Safe.from_string line in
    let details=member "details" entry in
    set "details" (set "received_ns" (member "observed_ns" details) details) entry |> Yojson.Safe.to_string)
    |> String.concat "\n" in
  let bad_source="source-clock.jsonl" in
  Out_channel.with_open_bin (Filename.concat output bad_source) (fun channel -> output_string channel changed);
  let original_case=match member "cases" packet with `List [row] -> row | _ -> fail "actual packet case missing" in
  let after_arm=member "after" original_case in
  let bad_logs=match member "logs" after_arm with
    | `List logs -> `List (List.map (fun row -> if member "path" row=`String source_path
        then `Assoc ["path",`String bad_source;"sha256",`String (sha changed)] else row) logs)
    | _ -> fail "actual source artifact list missing" in
  let bad_packet=Filename.concat output "source-clock-packet.json" in
  let bad_json=Filename.concat output "source-clock-report.json" in
  Out_channel.with_open_bin bad_packet (fun channel -> output_string channel
    (Yojson.Safe.to_string (set "cases" (`List [set "after" (set "logs" bad_logs after_arm) original_case]) packet)));
  check bool "UI processing cannot masquerade as an earlier source receipt" true
    (run [Filename.concat script_dir "tui_ask_followup_report.py";bad_packet;"--json";bad_json;
      "--markdown";Filename.concat output "source-clock-report.md"]=Unix.WEXITED 2);
  let bad_report=Yojson.Safe.from_file bad_json in
  check bool "contradictory original clocks withhold source intervals" true
    (match member "cases" bad_report with
     | `List [case] -> (match member "attempts" (member "after" case) with
       | `List [row] -> member "outcome" row=`String "invalid"
         && member "state" (member "linked_task" (member "source_observations" row))=`String "invalid_attempt"
         && member "source_received_to_processed_ns" (member "metrics"
              (member "linked_task" (member "source_observations" row)))=`Null
       | _ -> false)
     | _ -> false);
  let original_path=match before_logs with
    | entry::_ -> (match member "path" entry with `String path -> path | _ -> fail "source artifact path missing")
    | [] -> fail "actual before store had no artifact" in
  let copied_path=match member "cases" packet with
    | `List [case] -> (match member "logs" (member "before" case) with
        | `List (entry::_) -> (match member "path" entry with `String path -> Filename.concat output path | _ -> fail "copied artifact path missing")
        | _ -> fail "copied before artifacts missing")
    | _ -> fail "materialized case missing" in
  let frozen=In_channel.with_open_bin copied_path In_channel.input_all in
  Out_channel.with_open_bin (Filename.concat packet_dir original_path) (fun channel -> output_string channel "interrupted source");
  check string "source mutation cannot change frozen comparison bytes" frozen
    (In_channel.with_open_bin copied_path In_channel.input_all);
  check bool "existing output is refused" true (materialize output=Unix.WEXITED 2);
  check string "refused publication cannot replace original packet" packet_bytes (In_channel.with_open_bin packet_path In_channel.input_all);
  let failed=Filename.concat packet_dir "failed-materialization" in
  check bool "actual damaged source cannot publish a packet" true (materialize failed=Unix.WEXITED 2);
  check bool "failed preparation leaves no ready packet" false (Sys.file_exists (Filename.concat failed "packet.json"));
  check string "failed preparation retains original denominator plan" plan_bytes
    (In_channel.with_open_bin (Filename.concat failed "source-plan.json") In_channel.input_all);
  let failed_validation=Yojson.Safe.from_file (Filename.concat failed "validation.json") in
  check bool "failed materialization retains known journaled attempts" true
    (match member "cases" failed_validation with
     | `List [case] -> member "attempts" (member "summary" (member "before" case))=`Int 3
       && member "descriptive_delta_available" (member "comparison" case)=`Bool false
     | _ -> false);
  Out_channel.with_open_bin copied_path (fun channel -> output_string channel "interrupted artifact");
  Sys.remove json_path;Sys.remove markdown_path;
  let status,damaged_report=report () in
  check bool "mutated real artifact is reported as invalid" true (status=Unix.WEXITED 2);
  let case=match member "cases" damaged_report with `List [case] -> case | _ -> fail "invalid artifact erased the case" in
  check bool "artifact failure retains original declared attempts" true
    (member "attempts" (member "summary" (member "before" case))=`Int 3);
  Ui.retire_ask_followup_read state;
  check bool "offline report leaves actual canonical resources unchanged" true
    (resources=Masc.Workspace.get_tasks_raw config && resources2=Masc.Workspace.get_tasks_raw config2)

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
  let store=Masc_tui_observation_store.initialize ~base_path:base |> require in
  state.observation_store <- Some store;
  let log_dir=Masc_tui_observation_store.directory store in
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
  let module Logs=Masc_tui_system_logs in
  state.system_logs <- Logs.apply Logs.Server (Ok decoded) state.system_logs;
  let local=Logs.client_snapshot ~limit:Log.Ring.capacity ~min_level:None |> require in
  let shared_seq=match List.find_opt (fun (entry : Masc.Tui_decode.system_log_entry) ->
    List.exists (fun (other : Masc.Tui_decode.system_log_entry) -> other.sl_seq=entry.sl_seq) local.sys_entries) decoded.sys_entries with
    | Some entry -> entry.sl_seq | None -> fail "actual source pages have no common ring sequence" in
  state.system_logs <- Logs.update_current (fun page -> {page with
    lp_min_level=Some Masc.Tui_decode.System_info;lp_detail_seq=Some shared_seq}) state.system_logs;
  state.system_logs <- Logs.select Logs.This_tui state.system_logs;
  state.system_logs <- Logs.apply This_tui (Ok local) state.system_logs;
  state.system_logs <- Logs.update_current (fun page -> {page with lp_category=Some "lifecycle"}) state.system_logs;
  let client_page=Logs.current state.system_logs in
  Log.Server.info "Actual later server observation after client source selection";
  let late_entries=Log.Ring.recent ~limit:Log.Ring.capacity ~since_seq () in
  let late_frame=Server_dashboard_logs_json.build ~config ~limit:Log.Ring.capacity
    ~level_filter:"info" ~applied_level:Log.Info ~min_level:(Log.level_to_int Log.Info)
    ~module_filter:"" ~since_seq:(Some since_seq) ~before_seq:None
    ~category_filter:None ~exclude_category:None ~ring_bounds:(Log.Ring.bounds ()) late_entries in
  let late_server=Masc.Tui_decode.decode_system_log_snapshot late_frame |> require in
  state.system_logs <- Logs.apply Server (Ok late_server) state.system_logs;
  check bool "late actual server frame cannot replace client data, filters or detail target" true
    (Logs.current state.system_logs=client_page && (Logs.current state.system_logs).lp_detail_seq=None);
  state.system_logs <- Logs.select Server state.system_logs;
  check bool "server owns its actual late frame and original severity/detail selection" true
    ((Logs.current state.system_logs).lp_snapshot=Some late_server
     && (Logs.current state.system_logs).lp_min_level=Some Masc.Tui_decode.System_info
     && (Logs.current state.system_logs).lp_detail_seq=Some shared_seq);
  let empty_entries=Log.Ring.recent ~limit:Log.Ring.capacity ~before_seq:0 () in
  let empty_frame=Server_dashboard_logs_json.build ~config ~limit:Log.Ring.capacity
    ~level_filter:"debug" ~applied_level:Log.Debug ~min_level:(Log.level_to_int Log.Debug)
    ~module_filter:"" ~since_seq:None ~before_seq:(Some 0)
    ~category_filter:None ~exclude_category:None ~ring_bounds:(Log.Ring.bounds ()) empty_entries in
  let empty=Masc.Tui_decode.decode_system_log_snapshot empty_frame |> require in
  check bool "actual empty server page carries no invented latest sequence" true
    (empty.sys_entries=[] && empty.sys_latest_seq=None);
  state.system_logs <- Logs.apply Server (Ok empty) state.system_logs;
  state.system_logs <- Logs.select This_tui state.system_logs;
  state.system_logs <- Logs.apply Server (Error "controlled server source failure after actual frames") state.system_logs;
  check bool "server empty/error observations cannot become local empty/error state" true
    (Logs.current state.system_logs=client_page);
  state.system_logs <- Logs.clear_server state.system_logs;
  check bool "server workspace retirement preserves process-local page" true (Logs.current state.system_logs=client_page);
  check bool "retired server detail cannot resolve a colliding client sequence" true
    ((Logs.page Server state.system_logs).lp_snapshot=None && (Logs.page Server state.system_logs).lp_detail_seq=None);
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
  let replacement_store=Masc_tui_observation_store.initialize ~base_path:base |> require in
  state.observation_store <- Some replacement_store;
  let replacement=Masc_tui_observation_store.directory replacement_store in
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
  let admission_path=Masc_tui_observation_store.admissions_path replacement_store in
  Sys.remove admission_path;
  Unix.mkdir admission_path 0o700;
  (match Masc_tui_observation_store.record_admission replacement_store
     ~origin:completed.afr_origin ~request:(Ui.Snapshot_read.request_id completed.afr_request)
     ~admission_started_ns:completed.afr_admission_started_ns with
   | {capture_outcome=Masc_tui_observation_store.Capture_failed _;_} -> ()
   | {capture_outcome=Capture_returned;_} -> fail "directory blocker accepted an admission record");
  let capture_failed_read,result=run_read (fun _ -> ()) in
  check bool "actual original read completes despite capture failure" true (result=Some (Ok ()));
  let local_after_failure=Masc_tui_system_logs.client_snapshot ~limit:(Log.Ring.bounds ()).total ~min_level:None |> require in
  let capture_entry=List.find_opt (fun entry ->
    let details=entry.Masc.Tui_decode.sl_details in
    member "event" details=`String "tui_ask_followup"
    && member "request" details=`Int (Ui.Snapshot_read.request_id capture_failed_read.afr_request)
    && member "origin" details=Origin.to_json capture_failed_read.afr_origin)
    local_after_failure.sys_entries in
  check bool "local decoder retains original failed receipt without filesystem text in Info" true
    (match capture_entry with None -> false | Some entry ->
       let receipt=member "admission_capture" entry.sl_details in
       receipt=Masc_tui_observation_store.admission_capture_to_json capture_failed_read.afr_admission_capture
       && member "state" receipt=`String "failed" && member "error" receipt=`Null);
  let failure_entry=List.find_opt (fun entry ->
    let details=entry.Masc.Tui_decode.sl_details in
    member "event" details=`String "tui_ask_followup_admission_failed"
    && member "request" details=`Int (Ui.Snapshot_read.request_id capture_failed_read.afr_request)
    && member "origin" details=Masc_tui_observation_origin.to_json capture_failed_read.afr_origin)
    local_after_failure.sys_entries in
  (match failure_entry with
   | None -> fail "actual capture failure missing from local decoded Logs source"
   | Some entry ->
     check bool "capture diagnostic retains original admission clock and channel" true
       (Yojson.Safe.to_string (member "read_admission_started_ns" entry.sl_details)=Int64.to_string capture_failed_read.afr_admission_started_ns
        && entry.sl_level=Masc.Tui_decode.System_warn && entry.sl_category=Some "boundary"));
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
      test_case "retained original submitted Task preserves selection provenance and proof" `Quick test_retained_task_submission_keeps_selection_basis;
      test_case "answered Ask inspection preserves failed observations and rejects old visits" `Quick test_answered_ask_inspection_reopen_and_withdraw;
      test_case "actual comparison artifacts retain missing attempts and corrupted input" `Quick test_actual_followup_report_keeps_unobserved_and_bad_artifacts;
      test_case "actual structured observations survive daily JSONL and dashboard decode" `Quick test_actual_followup_structured_sink_and_export]])
