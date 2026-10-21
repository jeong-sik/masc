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
let launch state results request submission ~released perform =
  let envelope=Protocol.capture_workspace_message state in
  let stop,resolve=Eio.Promise.create () in
  Ui.supersede_ask_followup_worker state
    (Some (request,fun detail -> ignore (Eio.Promise.try_resolve resolve detail))) ~detail:"original read superseded";
  let finish ()=Ui.finish_ask_followup_worker state request in
  Results.launch_observation state ~results ~boundary_error:Fun.id ~on_not_run:finish
    ~observe_job:(function Masc_tui_workspace_job.Cancellation_requested -> () | Registration_released -> released ())
    ~progress:(fun (event,received_ns) -> envelope (Protocol.Ask_followup_observed (request,submission,event,received_ns)))
    ~deliver:(fun result -> envelope (Protocol.Ask_followup_finished (request,submission,result)))
    (fun publish -> Fun.protect ~finally:finish (fun () ->
      Eio.Fiber.first (fun () -> perform publish) (fun () -> Error (Eio.Promise.await stop))))
type admission = Part of Decode.ask_followup_event * int64 | Terminal of (unit,string) result | Refused
let apply state message = match message with
  | Protocol.Workspace_scoped (authority,reading,inner) ->
    if not (Protocol.workspace_message_admitted state ~authority ~reading inner) then Refused else
      (match inner with
       | Ask_followup_observed (request,submission,event,received_ns) ->
         (match Ui.take_ask_followup_event state request submission event with
          | Some (Ok _) -> Part (event,received_ns) | Some (Error detail) -> fail detail | None -> Refused)
       | Ask_followup_finished (request,submission,result) ->
         (match Ui.finish_ask_followup_read state request submission result with
          | Some result -> Terminal result | None -> Refused)
       | _ -> fail "observation changed its original message kind")
  | _ -> fail "original follow-up lost its captured workspace envelope"
let apply_ready state results seen =
  List.fold_left (fun terminal (ready : Protocol.async_msg Results.ready) ->
    match apply state ready.message with
    | Part (event,received_ns) -> seen:=(event,received_ns) :: !seen;terminal
    | Terminal result -> Some result
    | Refused -> fail "current original follow-up was refused") None (Results.take_ready results)
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
  Masc_tui_message_input.insert state.msg_input "new input while follow-up is observed";
  Eio.Promise.resolve release ();Eio.Promise.await left;
  check bool "terminal retained without taking shared notification" true (terminal state results seen=Ok ());
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
  check bool "failed aggregate is retained beside actual partial fact" true (Result.is_error (terminal state results seen));
  exact_task state task_id;
  check bool "unreceived reaction is unconfirmed, never observed empty" true
    ((view state).fv_reactions.fo_state=Projection.Followup_unconfirmed);
  let old,owner=begin_read state and old_left,old_resolve=Eio.Promise.create () in
  launch state results old owner ~released:(fun () -> ignore (Eio.Promise.try_resolve old_resolve ()))
    (actual_read base ask resolution ~parts:(ref []) ~before_source:(fun _ -> ()));
  Eio.Promise.await old_left;
  let held=Results.take_ready results in Ui.retire_ask_followup_read state;
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
  check bool "missing actual turn switch retains an unstarted read failure" true
    (Result.is_error (terminal state results (ref [])));
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
    (Ui.finish_ask_followup_read state request submission result=Some (Ok ()))
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

let () = Eio_main.run @@ fun env ->
  let original=Eio_context.snapshot_state () in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:(fun () -> Fs_compat.clear_fs ();Eio_context.restore_state original) (fun () ->
    run "TUI retained actual Ask follow-up results" ["protocol/resources",[
      test_case "actual partial and terminal observations survive a full shared queue" `Quick test_full_queue_keeps_partial_and_terminal;
      test_case "actual stream failure and old visits preserve original Task evidence" `Quick test_failure_and_reopened_scope_keep_original_facts;
      test_case "session close and missing turn switch preserve actual resources" `Quick test_session_close_and_unstarted_preserve_resources;
      test_case "canonical answered Ask opens actual Task history and submitted evidence" `Quick test_answered_ask_opens_actual_task_history_evidence;
      test_case "answered Ask inspection preserves failed observations and rejects old visits" `Quick test_answered_ask_inspection_reopen_and_withdraw]])
