(** Actual in-process operator cancellation commit and persistent workspaces meet the
    production retained-result producer and finite UI delivery policy. HTTP
    authentication, network, TUI process, screen and provider are not exercised. *)
open Alcotest
open Masc_tui_types
module Mcp = Masc.Mcp_server_eio
module Wire = Masc_tui_mcp
module Results = Masc_tui_workspace_result
module Protocol = Masc_tui_async_protocol

let () = Mirage_crypto_rng_unix.use_default ()
let () = Masc.Workspace_metric_hooks.install ()

let identity base : Masc.Tui_decode.server_identity =
  {sid_version="0.24.0";sid_binary_commit="task-cancel-resource";sid_binary_commit_age_s=None;
   sid_base_path=Masc.Tui_decode.Canonical_path.of_path (Unix.realpath base);sid_masc_root=Masc.Tui_decode.Canonical_path.of_path (Unix.realpath (Filename.concat base ".masc"));
   sid_executable_in_worktree=None;sid_state_ready=Some true;sid_uptime=None;
   sid_sse_clients=None;sid_gc=None;sid_scheduler=None}
let handshake ~id ~method_ params = Yojson.Safe.to_string
  (`Assoc ["jsonrpc",`String "2.0";"id",`Int id;"method",`String method_;"params",params])
let tool_result ~request_id response =
  match Wire.outcome_of_body ~request_id (Yojson.Safe.to_string response) with
  | Ok outcome when outcome.is_error -> Error outcome.text
  | Ok outcome -> Ok outcome.text
  | Error detail -> Error detail
let require_ok = function Ok value -> value | Error detail -> fail detail
let task config = match Masc.Workspace.get_tasks_raw config with
  | [task] -> task | _ -> fail "original fixture Task disappeared or changed membership"
let with_server ~clock ~sw ~owner f =
  let base = Filename.temp_dir "tui-task-cancel-resource-" "" in
  Fun.protect ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace base) @@ fun () ->
  let server = Mcp.For_testing.create_state ~base_path:base () in
  let call request = Mcp.handle_request ~clock ~sw ~mcp_session_id:owner server request in
  let initialized = call (handshake ~id:1 ~method_:"initialize"
    (`Assoc ["protocolVersion",`String "2025-11-25";"capabilities",`Assoc [];
      "clientInfo",`Assoc ["name",`String owner;"version",`String "1"]])) in
  (match initialized with `Assoc fields when List.mem_assoc "result" fields -> ()
   | _ -> fail "original MCP session did not initialize");
  let notified = call (Yojson.Safe.to_string (`Assoc ["jsonrpc",`String "2.0";
    "method",`String "notifications/initialized";"params",`Assoc []])) in
  (match notified with `Null -> () | _ -> fail "MCP initialized notification refused");
  ignore (require_ok (tool_result ~request_id:"start" (call (Wire.request_body ~request_id:"start"
    ~tool:"masc_start" ~arguments:["path",`String base;"task_title",`String "Original cancellation resource";
      "_agent_name",`String owner]))));
  let config = Masc.Mcp_server.workspace_config server in
  let original = task config in
  (match original.Masc_domain.task_status with
   | Claimed {assignee;_} -> check string "original Task belongs to its session" owner assignee
   | _ -> fail "original session did not claim its Task");
  f base config (identity base) original call
let cancel ~config ~task_id ~(expected_workspace : Masc.Tui_decode.server_identity) ~reason =
  Server_routes_http_routes_verification.For_testing.commit_operator_cancel_json
    ~config ~operator_id:"operator-cancel-test"
    (`Assoc ["task_id", `String task_id; "reason", `String reason;
      "expected_workspace", `Assoc [
        "base_path", `String (Masc.Tui_decode.Canonical_path.to_string expected_workspace.sid_base_path);
        "masc_root", `String (Masc.Tui_decode.Canonical_path.to_string expected_workspace.sid_masc_root)]])
  |> Result.map (fun _ -> "operator cancellation accepted")
  |> Result.map_error Masc_domain.masc_error_to_string

let claimed config owner = match (task config).Masc_domain.task_status with
  | Claimed {assignee;_} -> check string "original owner remains" owner assignee
  | _ -> fail "unstarted/refused operation changed the actual Task"
let cancelled config ~owner ~reason = match (task config).Masc_domain.task_status with
  | Cancelled {cancelled_by;reason=actual;_} ->
      check string "actual cancellation owner retained" owner cancelled_by;
      check (option string) "actual operator reason persisted" (Some reason) actual
  | _ -> fail "accepted cancellation did not persist"
let take results shared round = Protocol.Delivery_round.take round
  ~can_take:(fun () -> true) ~queued:(fun () -> Eio.Stream.length shared)
  ~take_shared:(fun () -> Eio.Stream.take_nonblocking shared)
  ~collect_owned:(fun () -> List.map (fun (ready : Protocol.async_msg Results.ready) ->
    {Protocol.ready_at_ns=ready.ready_at_ns;message=ready.message}) (Results.take_ready results))
let ready = function Some value -> value | None -> fail "original operation reply not retained"
let receipt = function
  | Protocol.Task_cancel_done (task_id,expected_workspace,result) -> task_id,expected_workspace,result
  | _ -> fail "original cancellation receipt changed kind or acquired a workspace envelope"
let cancellation_outcome = function
  | Ok text -> Protocol.Task_cancel_confirmed text
  | Error detail -> Protocol.Task_cancel_refused detail
let cancellation_message ~task_id ~expected_workspace result =
  let outcome = match result with Ok outcome | Error outcome -> outcome in
  Protocol.Task_cancel_done (task_id,expected_workspace,outcome)
let launch results ~delivered ~task_id ~expected_workspace perform =
  Results.launch_session ~results
    ~boundary_error:(fun detail -> Protocol.Task_cancel_unconfirmed detail)
    ~deliver:(fun result ->
      let message = cancellation_message ~task_id ~expected_workspace result in
      Eio.Promise.resolve delivered ();
      message)
    (fun () -> Ok (cancellation_outcome (perform ())))
let seed_shared () =
  let shared = Eio.Stream.create 1 in
  let original = {Protocol.ready_at_ns=0L;message=Protocol.Harness_label_done (Ok "unrelated-original")} in
  Eio.Stream.add shared original;
  shared,original
let after_shared results shared original =
  let first,round = take results shared Protocol.Delivery_round.empty in
  check bool "original shared notification precedes owned receipts unchanged" true (ready first == original);
  let reply,_ = take results shared round in (ready reply).message

let test_accepted_cancel_outlives_workspace_withdrawal env () =
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  with_server ~clock ~sw ~owner:"cancel-owner-a" @@ fun base_a config_a expected_a original_a _call_a ->
  with_server ~clock ~sw ~owner:"cancel-owner-b" @@ fun _base_b config_b expected_b _original_b _call_b ->
  let foreign_before = Masc.Workspace.get_tasks_raw config_b in
  let state = create_state ~workspace:"cancel-resource" ~local_base_path:base_a ~port:8935 ~refresh_interval:2. () in
  state.server_identity <- Some expected_a;
  let results = Results.create () and shared,notification = seed_shared () in
  Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  let accepted,accept = Eio.Promise.create () and release,resume = Eio.Promise.create () in
  let delivered,deliver = Eio.Promise.create () in
  let reason = "original operator cancellation reason" in
  Eio_context.with_turn_switch sw (fun () ->
    launch results ~delivered:deliver ~task_id:original_a.id ~expected_workspace:expected_a (fun () ->
      let result = cancel ~config:config_a ~task_id:original_a.id ~expected_workspace:expected_a ~reason in
      ignore (require_ok result);
      cancelled config_a ~owner:"operator-cancel-test" ~reason;
      Eio.Promise.resolve accept ();
      Eio.Promise.await release;
      result));
  Eio.Promise.await accepted;
  (* Exercise the actual workspace cancellation boundary while the original
     accepted operation's result is still with its producer. *)
  List.iter (fun (_,cancel) -> cancel ()) state.workspace_cancellations;
  state.workspace_authority <- Workspace_authority 1;
  state.workspace_read_authority <- ref ();
  state.server_identity <- Some expected_b;
  state.task_detail_id <- Some original_a.id;
  Eio.Promise.resolve resume ();
  Eio.Promise.await delivered;
  let task_id,expected,result = receipt (after_shared results shared notification) in
  check string "receipt retains its original Task" original_a.id task_id;
  check string "receipt retains its original physical workspace" (Masc.Tui_decode.Canonical_path.to_string expected_a.sid_masc_root) (Masc.Tui_decode.Canonical_path.to_string expected.sid_masc_root);
  (match result with
   | Protocol.Task_cancel_confirmed _ -> ()
   | Protocol.Task_cancel_refused _ | Protocol.Task_cancel_unconfirmed _ ->
       fail "accepted cancellation lost its confirmed receipt");
  remember_task_followup state ~expected_workspace:expected
    (Task_cancel_refresh {task_id;certainty=Cancellation_confirmed});
  let run,withdrawn = take_task_followups state ~ready:(fun _ -> true) in
  check bool "original receipt cannot authorize a foreign workspace read" true (run=[]);
  check bool "foreign follow-up is explicitly withdrawn" true (withdrawn=[Task_cancel_refresh {task_id=original_a.id;certainty=Cancellation_confirmed}]);
  cancelled config_a ~owner:"operator-cancel-test" ~reason;
  check bool "foreign actual Task resources remain unchanged" true (foreign_before=Masc.Workspace.get_tasks_raw config_b)

let test_no_switch_closed_owner_and_real_workspace_refusal env () =
  let snapshot = Eio_context.snapshot_state () in
  Fun.protect ~finally:(fun () -> Eio_context.restore_state snapshot) @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  with_server ~clock ~sw ~owner:"cancel-owner-original" @@ fun _base config expected original _call ->
  with_server ~clock ~sw ~owner:"cancel-owner-foreign" @@ fun _foreign_base foreign_config foreign _other _call ->
  let reason = "original reason retained on refusal" in
  let perform () = cancel ~config ~task_id:original.id ~expected_workspace:expected ~reason in
  Eio_context.For_testing.clear_root_switch ();
  check bool "fixture has no operation switch" true (Option.is_none (Eio_context.get_switch_opt ()));
  let results = Results.create () and shared,notification = seed_shared () in
  Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  let delivered,deliver = Eio.Promise.create () in
  launch results ~delivered:deliver ~task_id:original.id ~expected_workspace:expected perform;
  Eio.Promise.await delivered;
  let task_id,workspace,result = receipt (after_shared results shared notification) in
  check string "no-switch refusal retains Task identity" original.id task_id;
  check string "no-switch refusal retains workspace identity" (Masc.Tui_decode.Canonical_path.to_string expected.sid_masc_root) (Masc.Tui_decode.Canonical_path.to_string workspace.sid_masc_root);
  (match result with
   | Protocol.Task_cancel_unconfirmed _ -> ()
   | Protocol.Task_cancel_confirmed _ | Protocol.Task_cancel_refused _ ->
       fail "unstarted cancellation lost its boundary receipt");
  claimed config "cancel-owner-original";
  Results.close results;
  Eio_context.with_turn_switch sw (fun () ->
    Results.launch_session ~results
      ~boundary_error:(fun detail -> Protocol.Task_cancel_unconfirmed detail)
      ~deliver:(cancellation_message ~task_id:original.id ~expected_workspace:expected)
      (fun () -> Ok (cancellation_outcome (perform ()))));
  claimed config "cancel-owner-original";
  let successor = Results.create () in
  Fun.protect ~finally:(fun () -> Results.close successor) @@ fun () ->
  let delivered,deliver = Eio.Promise.create () in
  Eio_context.with_turn_switch sw (fun () ->
    launch successor ~delivered:deliver ~task_id:original.id ~expected_workspace:expected (fun () ->
      cancel ~config ~task_id:original.id ~expected_workspace:foreign ~reason));
  Eio.Promise.await delivered;
  let reply,_ = take successor shared Protocol.Delivery_round.empty in
  let _,workspace,result = receipt (ready reply).message in
  check string "server refusal remains associated with the original receipt" (Masc.Tui_decode.Canonical_path.to_string expected.sid_masc_root) (Masc.Tui_decode.Canonical_path.to_string workspace.sid_masc_root);
  (match result with
   | Protocol.Task_cancel_refused _ -> ()
   | Protocol.Task_cancel_confirmed _ | Protocol.Task_cancel_unconfirmed _ ->
       fail "server refusal lost its refused receipt");
  claimed config "cancel-owner-original";
  claimed foreign_config "cancel-owner-foreign"

module Dispatch = Masc_tui_task_dispatch
module Input = Masc_tui_message_input
let rec await_task request = match Dispatch.progress request.tdr_dispatch with
  | Completed _ -> ()
  | Not_started | Reserved | Preparing | Sending -> Eio.Fiber.yield (); await_task request
let creation_intent ~workspace ~original ~title ~body : Dispatch.intent =
  {request_id="original-task-create";keeper="creation-keeper";title;body;original;workspace=Some workspace}
let send_creation call ~session_id:_ ~request_id ~arguments =
  let response = call (Wire.request_body ~request_id ~tool:"masc_add_task" ~arguments) in
  Wire.outcome_of_body ~request_id (Yojson.Safe.to_string response)
let creation_reply state shared original =
  let take round = Protocol.Delivery_round.take round ~can_take:(fun () -> true)
    ~queued:(fun () -> Eio.Stream.length shared)
    ~take_shared:(fun () -> Eio.Stream.take_nonblocking shared)
    ~collect_owned:(fun () -> Protocol.collect_owned_results state) in
  let first,round = take Protocol.Delivery_round.empty in
  check bool "unrelated shared notification survives original Task completion" true (ready first == original);
  let next,_ = take round in
  match (ready next).message with
  | Protocol.Task_dispatch_completed request -> request
  | _ -> fail "Task creation acquired a foreign scope or lost its original request"

let test_created_task_survives_workspace_withdrawal env () = Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  with_server ~clock ~sw ~owner:"creation-session-a" @@ fun base_a config_a expected_a _original call_a ->
  with_server ~clock ~sw ~owner:"creation-session-b" @@ fun _base_b config_b expected_b _other _call_b ->
  let before_b = Masc.Workspace.get_tasks_raw config_b in
  let state = create_state ~workspace:"task-resource" ~local_base_path:base_a ~port:8935 ~refresh_interval:2. () in
  state.server_identity <- Some expected_a;
  state.workspace_identity <- Workspace_identity_match;
  state.msg_target_keeper_name <- Some "creation-keeper";
  let intent = creation_intent ~workspace:expected_a ~original:"/task original title\noriginal body"
    ~title:"original title" ~body:"original body" in
  Input.clear state.msg_input;
  let request = begin_task_dispatch state intent in
  let shared,notification = seed_shared () in
  let committed,commit = Eio.Promise.create () and gate,release = Eio.Promise.create () in
  Eio_context.with_turn_switch sw (fun () -> Dispatch.launch request.tdr_dispatch
    ~prepare:(fun () -> Ok "original-session")
    ~send:(fun ~session_id ~request_id ~arguments ->
      let answer = send_creation call_a ~session_id ~request_id ~arguments in
      Eio.Promise.resolve commit ();
      Eio.Promise.await gate;
      answer));
  Eio.Promise.await committed;
  List.iter (fun (_,cancel) -> cancel ()) state.workspace_cancellations;
  state.workspace_authority <- Workspace_authority 1;
  state.workspace_read_authority <- ref ();
  state.server_identity <- Some expected_b;
  Input.insert state.msg_input "new operator input";
  Eio.Promise.resolve release ();
  await_task request;
  let delivered = creation_reply state shared notification in
  check bool "original request wrapper remains the owner" true (delivered==request);
  let task_id,workspace = match take_task_dispatch_completion state delivered with
    | Some (Dispatch.Created {task_id;workspace}) -> task_id,workspace
    | _ -> fail "actual created Task lost its original receipt" in
  let created = match List.find_opt (fun (task : Masc_domain.task) -> task.id=task_id)
      (Masc.Workspace.get_tasks_raw config_a) with Some task -> task | None -> fail "created Task resource absent" in
  check string "original title persisted" intent.title created.title;
  check string "original body persisted" intent.body created.description;
  remember_task_followup state ~expected_workspace:workspace
    (Task_handoff {keeper=intent.keeper;task_id;title=intent.title;body=intent.body;editor=None});
  let run,withdrawn = take_task_followups state ~ready:(fun _ -> true) in
  check bool "created Task cannot grant a foreign Keeper handoff" true (run=[] && withdrawn<>[]);
  check string "new operator input remains" "new operator input" (Input.contents state.msg_input);
  check bool "duplicate receipt cannot create a second handoff decision" true (take_task_dispatch_completion state request=None);
  check bool "foreign Task resources remain unchanged" true (before_b=Masc.Workspace.get_tasks_raw config_b);
  state.workspace_authority <- Workspace_authority 2;
  state.server_identity <- Some expected_a;
  state.msg_target_keeper_name <- None;
  Input.clear state.msg_input;
  let second_intent = {intent with request_id="original-task-create-second";title="same-workspace original"} in
  let second = begin_task_dispatch state second_intent in
  Eio_context.with_turn_switch sw (fun () -> Dispatch.launch second.tdr_dispatch
    ~prepare:(fun () -> Ok "original-session") ~send:(send_creation call_a));
  Input.insert state.msg_input "new unbound composer draft";
  await_task second;
  let task_id,workspace = match take_task_dispatch_completion state second with
    | Some (Dispatch.Created {task_id;workspace}) -> task_id,workspace
    | _ -> fail "same-workspace actual Task creation lost its receipt" in
  check bool "same-workspace Task is an actual persistent resource" true
    (List.exists (fun (task : Masc_domain.task) -> task.id=task_id && task.title=second_intent.title)
      (Masc.Workspace.get_tasks_raw config_a));
  let editor = Some {the_authority=second.tdr_authority;the_revision=second.tdr_editor;
    the_target=second.tdr_editor_keeper} in
  remember_task_followup state ~expected_workspace:workspace
    (Task_handoff {keeper=second_intent.keeper;task_id;title=second_intent.title;body=second_intent.body;editor});
  let run,withdrawn = take_task_followups state ~ready:(fun _ -> true) in
  check bool "new input blocks only automatic focus, not the fresh original handoff" true
    (run<>[] && withdrawn=[] && not (task_handoff_may_focus state ~keeper:second_intent.keeper editor));
  check string "successful late creation keeps the unbound new draft" "new unbound composer draft" (Input.contents state.msg_input)

let test_unknown_task_and_original_input_recovery env () = Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  with_server ~clock ~sw ~owner:"creation-session-original" @@ fun base config expected _original call ->
  let state = create_state ~workspace:"task-resource" ~local_base_path:base ~port:8935 ~refresh_interval:2. () in
  state.server_identity <- Some expected;
  state.workspace_identity <- Workspace_identity_match;
  state.msg_target_keeper_name <- Some "creation-keeper";
  Input.clear state.msg_input;
  let intent = creation_intent ~workspace:expected ~original:"/task uncertain original\noriginal body"
    ~title:"uncertain original" ~body:"original body" in
  let request = begin_task_dispatch state intent in
  Eio_context.with_turn_switch sw (fun () -> Dispatch.launch request.tdr_dispatch
    ~prepare:(fun () -> Ok "original-session")
    ~send:(fun ~session_id ~request_id ~arguments ->
      let answer = send_creation call ~session_id ~request_id ~arguments in
      ignore (require_ok answer);
      Error "controlled reply loss after actual resource commit"));
  await_task request;
  (match take_task_dispatch_completion state request with Some (Dispatch.Unconfirmed _) -> ()
   | _ -> fail "lost actual creation response became not-created or success");
  check bool "unconfirmed creation never automatically restores a resubmittable command" false
    (restore_task_dispatch_input state request);
  let actual_before_recovery = Masc.Workspace.get_tasks_raw config in
  check bool "uncertain outcome still has its actual Task resource" true
    (List.exists (fun (task : Masc_domain.task) -> task.title=intent.title) actual_before_recovery);
  (match Masc_tui_command.parse "/task-recover" with Task_recover -> () | _ -> fail "explicit recovery intent was not parsed");
  check bool "explicit original command recovery is available" true
    (Option.is_some (recover_task_dispatch_input state ~keeper:intent.keeper));
  check string "recovery retains exact original command" intent.original (Input.contents state.msg_input);
  check bool "input recovery cannot replay Task creation" true (actual_before_recovery=Masc.Workspace.get_tasks_raw config);
  Input.clear state.msg_input;
  let unsent = begin_task_dispatch state {intent with original="/task unstarted";title="unstarted"} in
  Input.insert state.msg_input "a newer edit";
  Input.clear state.msg_input;
  let snapshot = Eio_context.snapshot_state () in
  Fun.protect ~finally:(fun () -> Eio_context.restore_state snapshot) (fun () ->
    Eio_context.For_testing.clear_root_switch ();
    Dispatch.launch unsent.tdr_dispatch ~prepare:(fun () -> Ok "original-session") ~send:(send_creation call));
  (match take_task_dispatch_completion state unsent with Some (Dispatch.Not_sent _) -> ()
   | _ -> fail "no-switch request became a sent operation");
  check bool "editing back to empty cannot lend the original editor revision" false
    (restore_task_dispatch_input state unsent);
  check string "late failure keeps the newer empty editor" "" (Input.contents state.msg_input);
  check bool "not-started intent cannot mutate the actual workspace" true
    (actual_before_recovery=Masc.Workspace.get_tasks_raw config);
  ignore (recover_task_dispatch_input state ~keeper:intent.keeper);
  check string "explicit recovery selects latest original intent" "/task unstarted" (Input.contents state.msg_input)

(* Actual MCP resources and the strict persisted backlog are the assertions.
   The response is deliberately discarded after the resource commits. *)
let read_creation_receipt ~call ~workspace ~request_id =
  let text = call (Wire.request_body ~request_id:"inspect-creation" ~tool:"masc_tasks"
    ~arguments:["creation_request_id",`String request_id;
      "expected_workspace",`Assoc ["base_path",`String (Masc.Tui_decode.Canonical_path.to_string workspace.Masc.Tui_decode.sid_base_path);
                                   "masc_root",`String (Masc.Tui_decode.Canonical_path.to_string workspace.sid_masc_root)]])
    |> tool_result ~request_id:"inspect-creation" |> require_ok in
  let json = Yojson.Safe.from_string text in
  let open Yojson.Safe.Util in
  let ids = json |> member "creation_receipt" |> member "task_ids" |> to_list |> List.map to_string in
  let state = json |> member "creation_receipt" |> member "state" |> to_string in
  check string "lookup retains original opaque request" request_id
    (json |> member "creation_request_id" |> to_string);
  check string "lookup names the original workspace" (Masc.Tui_decode.Canonical_path.to_string workspace.sid_masc_root)
    (json |> member "workspace" |> member "masc_root" |> to_string);
  state,ids

let test_creation_receipt_after_lost_reply_and_duplicate_request env () = Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  with_server ~clock ~sw ~owner:"receipt-resource" @@ fun _base config workspace _original call ->
  let create request_id =
    let intent = { (creation_intent ~workspace ~original:"/task equal title"
      ~title:"equal title" ~body:"exact original body") with request_id } in
    let source = Dispatch.create intent in
    Eio_context.with_turn_switch sw (fun () -> Dispatch.launch source
      ~prepare:(fun () -> Ok "original-session")
      ~send:(fun ~session_id ~request_id ~arguments ->
        ignore (require_ok (send_creation call ~session_id ~request_id ~arguments));
        Error "response deliberately discarded after actual creation"));
    let rec await () = match Dispatch.progress source with
      | Completed {outcome=Unconfirmed _;_} -> ()
      | Completed _ -> fail "lost reply became a success or a no-send"
      | Not_started | Reserved | Preparing | Sending -> Eio.Fiber.yield ();await () in
    await () in
  let original_request = "creation-receipt-original" in
  create original_request;
  let state,ids = read_creation_receipt ~call ~workspace ~request_id:original_request in
  check string "actual committed original was found" "recorded" state;
  let original_id = match ids with [id] -> id | _ -> fail "original has no exact creation identity" in
  create "creation-receipt-other";
  let state,ids = read_creation_receipt ~call ~workspace ~request_id:original_request in
  check (pair string (list string)) "equal title cannot borrow another request's Task"
    ("recorded",[original_id]) (state,ids);
  let before = Masc.Workspace.get_tasks_raw config in
  let _ = read_creation_receipt ~call ~workspace ~request_id:"not-observed-request" in
  check (pair string (list string)) "missing request is unobserved, never not-created"
    ("not_observed",[]) (read_creation_receipt ~call ~workspace ~request_id:"not-observed-request");
  check bool "receipt reads do not create or change any Task" true (before=Masc.Workspace.get_tasks_raw config);
  (* A repeated non-idempotent request is not suppressed or guessed away. *)
  create original_request;
  let state,ids = read_creation_receipt ~call ~workspace ~request_id:original_request in
  check string "repeated actual request remains ambiguous" "ambiguous" state;
  check int "both actual creations remain visible" 2 (List.length ids);
  check bool "the original identity is retained" true (List.mem original_id ids);
  check bool "the actual Task identities are distinct" true
    (match ids with [a;b] -> a<>b | _ -> false);
  (* Durable creation evidence outlives the deleted current Task. *)
  (match Masc.Workspace.delete_task_r config ~task_id:original_id with
   | Ok _ -> () | Error error -> fail (Masc_domain.masc_error_to_string error));
  check bool "original Task was actually deleted" false
    (List.exists (fun (task : Masc_domain.task) -> task.id=original_id) (Masc.Workspace.get_tasks_raw config));
  check (pair string (list string)) "deletion cannot rewrite the original creation facts"
    (state,ids) (read_creation_receipt ~call ~workspace ~request_id:original_request)

let test_creation_receipt_refusals_and_corrupt_primary env () = Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  with_server ~clock ~sw ~owner:"receipt-original" @@ fun _base config workspace _original call ->
  with_server ~clock ~sw ~owner:"receipt-foreign" @@ fun _other_base other_config other_workspace _other _other_call ->
  let before = Masc.Workspace.get_tasks_raw config and foreign_before = Masc.Workspace.get_tasks_raw other_config in
  let invoke tool arguments =
    call (Wire.request_body ~request_id:"receipt-invalid" ~tool ~arguments)
    |> tool_result ~request_id:"receipt-invalid" in
  let refused = function Error _ -> () | Ok _ -> fail "invalid creation receipt request was accepted" in
  refused (invoke "masc_add_task" ["title",`String "must not exist";"creation_request_id",`Null]);
  refused (invoke "masc_add_task" ["title",`String "must not exist";"creation_request_id",`String "   "]);
  refused (invoke "masc_add_task" ["title",`String "must not exist";
    "creation_request_id",`String "one";"creation_request_id",`String "two"]);
  refused (invoke "masc_tasks" ["creation_request_id",`String "original";"status",`String "done"]);
  refused (invoke "masc_tasks" ["creation_request_id",`String "original";
    "expected_workspace",`Assoc ["base_path",`String (Masc.Tui_decode.Canonical_path.to_string other_workspace.sid_base_path);
                                 "masc_root",`String (Masc.Tui_decode.Canonical_path.to_string other_workspace.sid_masc_root)]]);
  check bool "refused requests preserve original Task resources" true (before=Masc.Workspace.get_tasks_raw config);
  check bool "foreign Task resources remain unchanged" true (foreign_before=Masc.Workspace.get_tasks_raw other_config);
  let request_id = "receipt-before-primary-corruption" in
  let reply = invoke "masc_add_task" ["title",`String "durable original";"creation_request_id",`String request_id]
    |> require_ok in
  let task_id = Wire.task_id_of_add_task reply |> require_ok in
  check (pair string (list string)) "actual durable receipt available before corruption"
    ("recorded",[task_id]) (read_creation_receipt ~call ~workspace ~request_id);
  (* A valid recovery copy must not certify an unreadable primary. *)
  let primary = Masc.Workspace.backlog_path config in
  let json = Fs_compat.load_file primary |> Yojson.Safe.from_string in
  let corrupt = match json with
    | `Assoc fields -> `Assoc (("task_creation_receipts",`String "corrupt") :: List.remove_assoc "task_creation_receipts" fields)
    | _ -> fail "actual backlog is not an object" in
  Fs_compat.save_file primary (Yojson.Safe.to_string corrupt);
  refused (invoke "masc_tasks" ["creation_request_id",`String request_id]);
  refused (invoke "masc_add_task" ["title",`String "must not use recovery";"creation_request_id",`String "new-after-corruption"]);
  check bool "refused lookup cannot repair or replace its primary" true
    (Yojson.Safe.from_string (Fs_compat.load_file primary)=corrupt)

module Creation_read = Masc_tui_task_creation_read
let retained_actual_creation state call ~workspace ~request_id =
  let intent={ (creation_intent ~workspace ~original:"/task inspect original\noriginal body"
    ~title:"inspect original" ~body:"original body") with request_id } in
  let original=begin_task_dispatch state intent and committed=ref None in
  Dispatch.launch original.tdr_dispatch ~prepare:(fun () -> Ok "original-session")
    ~send:(fun ~session_id ~request_id ~arguments ->
      let answer=send_creation call ~session_id ~request_id ~arguments |> require_ok in
      committed := Some (Wire.task_id_of_add_task answer.text |> require_ok);
      Error "controlled lost reply after actual commit");
  await_task original;
  (match take_task_dispatch_completion state original with Some (Dispatch.Unconfirmed _) -> ()
   | _ -> fail "original creation outcome was rewritten");
  original,(match !committed with Some id -> id | None -> fail "fixture creation never committed")
let inspect_actual call source =
  let arguments=match Creation_read.arguments source with Ok args -> args
    | Error _ -> fail "original workspace arguments were not available" in
  let response=call (Wire.request_body ~request_id:"original-inspection" ~tool:"masc_tasks" ~arguments) in
  match Wire.outcome_of_body ~request_id:"original-inspection" (Yojson.Safe.to_string response) with
  | Ok answer -> Creation_read.decode source answer
  | Error detail -> Error (Creation_read.Read_failed detail)
let launch_inspection results state call request =
  let source=request.tcr_original.tdr_inspection in
  let envelope=Protocol.capture_workspace_message state in
  Results.launch ~key:request.tcr_job ~observation:true state ~results
    ~boundary_error:(fun detail -> Creation_read.Read_failed detail)
    ~deliver:(fun result -> envelope (Protocol.Task_creation_read_done (request,result)))
    (fun () -> inspect_actual call source)
let rec owned_message results = match Results.take_ready results with
  | [] -> Eio.Fiber.yield ();owned_message results
  | [ready] -> ready.message
  | _ -> fail "fixture admitted unrelated owned results"
let admit_inspection state = function
  | Protocol.Workspace_scoped (authority,reading,(Protocol.Task_creation_read_done (request,result) as message)) ->
    if Protocol.workspace_message_admitted state ~authority ~reading message then
      complete_task_creation_inspection state request result else false
  | _ -> fail "inspection lost its original workspace observation envelope"
let original_unconfirmed original = match Dispatch.progress original.tdr_dispatch with
  | Completed {outcome=Unconfirmed _;_} -> ()
  | _ -> fail "inspection rewrote original creation transport evidence"
let creation_state base workspace =
  let state=create_state ~workspace:"creation-inspection" ~local_base_path:base ~port:8935 ~refresh_interval:2. () in
  state.server_identity <- Some workspace;state.workspace_identity <- Workspace_identity_match;
  state.msg_target_keeper_name <- Some "creation-keeper";state
let begin_inspection state = match begin_task_creation_inspection state with
  | Some request -> request | None -> fail "explicit original inspection did not begin"
let recorded original task_id = match Creation_read.observation original.tdr_inspection with
  | Masc_tui_fetched.Ready (Creation_read.Recorded receipt) ->
    check string "exact actual created Task observed" task_id receipt.task_id
  | _ -> fail "actual original creation fact was not retained"

let test_original_inspection_and_refused_actual_reply env () = Eio.Switch.run @@ fun sw ->
  let clock=Eio.Stdenv.clock env in
  with_server ~clock ~sw ~owner:"inspect-original" @@ fun base config workspace _original call ->
  Eio_context.with_turn_switch sw @@ fun () ->
  let state=creation_state base workspace in
  let original,task_id=retained_actual_creation state call ~workspace ~request_id:"inspect-exact-original" in
  let before=Masc.Workspace.get_tasks_raw config in
  (match Masc_tui_command.parse "/task-inspect" with Task_inspect -> () | _ -> fail "explicit inspection intent missing");
  check bool "original failed request is inspectable" true (open_task_creation_inspection state ~keeper:"creation-keeper");
  let request=begin_inspection state and results=Results.create () in
  Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  launch_inspection results state call request;
  Input.insert state.msg_input "newer input while original creation is inspected";
  check bool "actual original receipt admitted" true (admit_inspection state (owned_message results));
  recorded original task_id;original_unconfirmed original;
  check (option string) "only ready exact fact offers explicit Task inspection" (Some task_id)
    (Creation_read.recorded_task original.tdr_inspection);
  (* Read another actual protocol key, then offer that real answer to the
     original source. It must not become an empty/foreign success. *)
  let retry=begin_inspection state in
  let response=call (Wire.request_body ~request_id:"different-original" ~tool:"masc_tasks"
    ~arguments:["creation_request_id",`String "another-request"]) in
  let answer=Wire.outcome_of_body ~request_id:"different-original" (Yojson.Safe.to_string response) |> require_ok in
  let result=Creation_read.decode original.tdr_inspection answer in
  (match result with Error (Creation_read.Invalid_reply _) -> () | _ -> fail "foreign original request was accepted");
  check bool "refused reply settles only its current source" true (complete_task_creation_inspection state retry result);
  (match Creation_read.observation original.tdr_inspection with
   | Masc_tui_fetched.Stale (Creation_read.Recorded receipt,Creation_read.Invalid_reply _) ->
       check string "failed recheck keeps original fact" task_id receipt.task_id
   | _ -> fail "refused reply erased the retained creation fact");
  check (option string) "stale fact grants no ready Task-open decision" None
    (Creation_read.recorded_task original.tdr_inspection);
  original_unconfirmed original;
  check string "read result preserves newer input" "newer input while original creation is inspected" (Input.contents state.msg_input);
  check bool "inspection never creates another Task or changes resources" true (before=Masc.Workspace.get_tasks_raw config);
  check bool "inspection never grants a Keeper handoff" true (state.pending_task_followups=[])

let test_inspection_reopen_history_and_workspace_withdrawal env () = Eio.Switch.run @@ fun sw ->
  let clock=Eio.Stdenv.clock env in
  with_server ~clock ~sw ~owner:"inspect-scope-a" @@ fun base config workspace _original call ->
  with_server ~clock ~sw ~owner:"inspect-scope-b" @@ fun _other other_config other_workspace _other_task _other_call ->
  Eio_context.with_turn_switch sw @@ fun () ->
  let state=creation_state base workspace in
  let original,task_id=retained_actual_creation state call ~workspace ~request_id:"inspect-reopened-original" in
  check bool "original inspection opened" true (open_task_creation_inspection state ~keeper:"creation-keeper");
  let first=begin_inspection state and results=Results.create () in
  Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  launch_inspection results state call first;
  let late=owned_message results in
  close_task_creation_inspection state ~reason:Creation_read.Interrupted;
  check bool "same original inspector can reopen" true (open_task_creation_inspection state ~keeper:"creation-keeper");
  let second=begin_inspection state in
  launch_inspection results state call second;
  check bool "new original ticket admitted" true (admit_inspection state (owned_message results));
  recorded original task_id;
  check bool "old completed reply cannot finish reopened same original" false (admit_inspection state late);
  recorded original task_id;
  let newer,newer_id=retained_actual_creation state call ~workspace ~request_id:"inspect-newer-original" in
  let neighbor=match task_creation_neighbor state ~older:false with Some original -> original
    | None -> fail "newer retained original disappeared" in
  check bool "history chooses original identity, not equal title" true (neighbor==newer && neighbor!=original);
  close_task_creation_inspection state ~reason:Creation_read.Interrupted;
  check bool "newer exact original selectable" true (select_task_creation_inspection state neighbor);
  let latest=begin_inspection state in
  launch_inspection results state call latest;
  check bool "newer exact actual fact admitted" true (admit_inspection state (owned_message results));
  recorded newer newer_id;
  let before=Masc.Workspace.get_tasks_raw config and other_before=Masc.Workspace.get_tasks_raw other_config in
  let withdrawn=begin_inspection state in
  launch_inspection results state call withdrawn;
  let late_foreign=owned_message results in
  suspend_workspace_readings state;
  state.workspace_authority <- Workspace_authority 1;
  state.server_identity <- Some other_workspace;
  check bool "foreign workspace never displays the original inspector" true (current_task_creation_reader state=None);
  check bool "late original reading cannot borrow foreign workspace" false (admit_inspection state late_foreign);
  (match Creation_read.observation newer.tdr_inspection with
   | Masc_tui_fetched.Stale (Creation_read.Recorded receipt,Creation_read.Workspace_unconfirmed _) ->
       check string "withdrawal retains its last original creation fact" newer_id receipt.task_id
   | _ -> fail "withdrawal erased the original reading or left it pending");
  original_unconfirmed original;original_unconfirmed newer;
  check bool "original Task resources unchanged by all reads" true (before=Masc.Workspace.get_tasks_raw config);
  check bool "foreign actual Task resources remain untouched" true (other_before=Masc.Workspace.get_tasks_raw other_config)

module Task_inspection = Masc.Tui_decode_task_inspection
let original_task_request state = match begin_original_task_inspection state with
  | Some request -> request | None -> fail "original recorded Task inspection did not begin"
let actual_task_snapshot config request =
  let task_id=match request.tcr_query with
    | Original_task_query ticket -> Creation_read.task_request_key ticket
    | Creation_query _ | Original_history_query _ | Original_evidence_query _ -> fail "Task request changed kind" in
  let status,json=Server_dashboard_task_detail.inspect ~config ~task_id:(Some task_id)
    |> Server_dashboard_task_detail.inspection_response in
  match status with
  | `OK ->
    let decoded=Task_inspection.observation ~task_id json
      |> Result.map_error (fun detail -> Creation_read.Invalid_reply detail) in
    Result.bind decoded (Creation_read.prepare_task ~task_id)
  | `Bad_request | `Not_found | `Service_unavailable -> Error (Creation_read.Read_failed (Yojson.Safe.to_string json))
let launch_original_inspection results state config request =
  let envelope=Protocol.capture_workspace_message state in
  Results.launch ~key:request.tcr_job ~observation:true state ~results
    ~boundary_error:(fun detail -> Creation_read.Read_failed detail)
    ~deliver:(fun result -> envelope (Protocol.Original_task_read_done (request,result)))
    (fun () -> actual_task_snapshot config request)
let admit_original_inspection state = function
  | Protocol.Workspace_scoped (authority,reading,(Protocol.Original_task_read_done (request,result) as message)) ->
    if Protocol.workspace_message_admitted state ~authority ~reading message then
      complete_original_task_inspection state request result else false
  | _ -> fail "original Task observation lost its read scope"
let creation_proof state call results =
  let request=begin_inspection state in
  launch_inspection results state call request;
  check bool "original creation proof admitted" true (admit_inspection state (owned_message results))

let test_original_task_read_without_global_rows_and_archive env () = Eio.Switch.run @@ fun sw ->
  let clock=Eio.Stdenv.clock env in
  with_server ~clock ~sw ~owner:"original-task-live-archive" @@ fun base config workspace _initial call ->
  Eio_context.with_turn_switch sw @@ fun () ->
  let state=creation_state base workspace in
  let original,task_id=retained_actual_creation state call ~workspace ~request_id:"task-independent-original" in
  check bool "fixture has no global Task rows" true (task_domain_values state=[] && state.tasks=[]);
  state.tasks_error <- Some "global Task listing remains unavailable";
  check bool "original source opens without inventory" true (open_task_creation_inspection state ~keeper:"creation-keeper");
  let results=Results.create () in
  Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  creation_proof state call results;
  let request=original_task_request state in
  launch_original_inspection results state config request;
  Input.insert state.msg_input "new input while original Task is read";
  check bool "live original Task admitted without global rows" true (admit_original_inspection state (owned_message results));
  (match Creation_read.task_observation original.tdr_inspection with
   | Masc_tui_fetched.Ready (Task_inspection.In_backlog detail) ->
     check string "read exact actual original Task" task_id detail.task.id;
     check string "full original Task description retained" "original body" detail.task.description
   | _ -> fail "live original Task observation missing");
  ignore (cancel ~call ~task_id ~expected_workspace:workspace ~reason:"archive original after actual cancel" |> require_ok);
  (* Keep the actual cancellation and creation receipts. Only its timestamp is
     aged in this private fixture so production GC can archive it without a
     sleep or an invalid zero-day retention. *)
  let backlog=Masc.Workspace.read_backlog_r config |> require_ok in
  let tasks=List.map (fun (task : Masc_domain.task) ->
    if task.id<>task_id then task else match task.task_status with
    | Cancelled cancelled ->
      {task with task_status=Cancelled {cancelled with cancelled_at="2000-01-01T00:00:00Z"}}
    | Todo | Claimed _ | InProgress _ | AwaitingVerification _ | Done _ -> fail "actual cancellation did not persist") backlog.tasks in
  Masc.Workspace.write_backlog config {backlog with tasks};
  ignore (Masc.Workspace.archive_terminal_tasks config ~days:1 ());
  check bool "original was actually archived from live backlog" false
    (List.exists (fun (task : Masc_domain.task) -> task.id=task_id) (Masc.Workspace.get_tasks_raw config));
  let request=original_task_request state in
  launch_original_inspection results state config request;
  check bool "archive observation admitted" true (admit_original_inspection state (owned_message results));
  (match Creation_read.task_observation original.tdr_inspection with
   | Masc_tui_fetched.Ready (Task_inspection.In_archive detail) ->
     check string "archive keeps exact original identity" task_id detail.task.id;
     check string "archive keeps full original body" "original body" detail.task.description;
     (match detail.task.task_status with Cancelled _ -> () | _ -> fail "archive invented terminal status")
   | _ -> fail "archived Task became missing/failure or borrowed global rows");
  check bool "lookup never fills global rows or clears listing failure" true
    (task_domain_values state=[] && state.tasks=[] && state.tasks_error=Some "global Task listing remains unavailable");
  check string "late Task read leaves input intact" "new input while original Task is read" (Input.contents state.msg_input);
  original_unconfirmed original;
  check bool "inspection does not hand work to a Keeper" true (state.pending_task_followups=[])

let test_original_task_delete_failure_and_late_scope env () = Eio.Switch.run @@ fun sw ->
  let clock=Eio.Stdenv.clock env in
  with_server ~clock ~sw ~owner:"original-task-delete-a" @@ fun base config workspace _initial call ->
  with_server ~clock ~sw ~owner:"original-task-delete-b" @@ fun _other other_config other_workspace _other_task _other_call ->
  Eio_context.with_turn_switch sw @@ fun () ->
  let state=creation_state base workspace in
  let original,task_id=retained_actual_creation state call ~workspace ~request_id:"task-deletion-original" in
  check bool "original source selected" true (open_task_creation_inspection state ~keeper:"creation-keeper");
  let results=Results.create () in
  Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  creation_proof state call results;
  let first=original_task_request state in
  launch_original_inspection results state config first;
  let late=owned_message results in
  close_task_creation_inspection state ~reason:Creation_read.Interrupted;
  check bool "same original reopens" true (open_task_creation_inspection state ~keeper:"creation-keeper");
  creation_proof state call results;
  let fresh=original_task_request state in
  launch_original_inspection results state config fresh;
  check bool "fresh original Task reply admitted" true (admit_original_inspection state (owned_message results));
  check bool "old Task ticket cannot finish the reopened original" false (admit_original_inspection state late);
  let status,json=Server_dashboard_task_detail.inspect ~config ~task_id:(Some "task-unobserved-original")
    |> Server_dashboard_task_detail.inspection_response in
  check bool "unknown is an actual observation response" true (status=`OK);
  (match Task_inspection.observation ~task_id:"task-unobserved-original" json with
   | Ok Task_inspection.Not_observed -> () | _ -> fail "unobserved Task became deleted/completed");
  (match Masc.Workspace.delete_task_r config ~task_id with
   | Ok _ -> () | Error error -> fail (Masc_domain.masc_error_to_string error));
  let deleted=original_task_request state in
  launch_original_inspection results state config deleted;
  check bool "durable deletion observation admitted" true (admit_original_inspection state (owned_message results));
  (match Creation_read.task_observation original.tdr_inspection with
   | Masc_tui_fetched.Ready (Task_inspection.Deletion_recorded _) -> ()
   | _ -> fail "actual deletion became unobserved or stayed live");
  (* Archive storage failure cannot certify absence even with a deletion record. *)
  Fs_compat.save_file (Masc.Workspace.archive_path config) "{invalid archive";
  let failed=original_task_request state in
  launch_original_inspection results state config failed;
  check bool "failed current refresh settles" true (admit_original_inspection state (owned_message results));
  (match Creation_read.task_observation original.tdr_inspection with
   | Masc_tui_fetched.Stale (Task_inspection.Deletion_recorded _,Creation_read.Read_failed _) -> ()
   | _ -> fail "archive failure lost prior deletion or invented absence");
  let withdrawn=original_task_request state in
  launch_original_inspection results state config withdrawn;
  let late_foreign=owned_message results in
  let other_before=Masc.Workspace.get_tasks_raw other_config in
  suspend_workspace_readings state;state.workspace_authority <- Workspace_authority 1;
  state.server_identity <- Some other_workspace;
  check bool "original Task reply cannot borrow foreign workspace" false (admit_original_inspection state late_foreign);
  check bool "foreign Task resources unchanged" true (other_before=Masc.Workspace.get_tasks_raw other_config);
  original_unconfirmed original

let proof_transition config ~owner ~task_id action notes =
  match Masc.Workspace.transition_r config ~agent_name:owner ~task_id ~action ~notes
    ~prepare_verification_request:(fun ~task ~assignee ~verification_id ~claim ->
      Masc.Verification_protocol.create_submit_request ~config ~task ~assignee ~verification_id ~claim) () with
  | Ok _ -> () | Error error -> fail (Masc_domain.masc_error_to_string error)
let actual_submission config task_id =
  let task=Masc.Workspace.get_tasks_raw config |> List.find (fun (task : Masc_domain.task) -> task.id=task_id) in
  match task.Masc_domain.task_status with
  | AwaitingVerification {verification_id;_} -> verification_id
  | Todo | Claimed _ | InProgress _ | Done _ | Cancelled _ -> fail "actual submission did not enter awaiting verification"
let settle_proof config ~task_id ~verification_id verdict =
  match Masc.Workspace.commit_verdict_r config ~authority:(Masc_domain.Human_operator {operator_id="proof-reader-operator"})
    ~task_id ~verification_id ~verdict ~notes:"actual private fixture verdict" () with
  | Ok _ -> () | Error error -> fail (Masc_domain.masc_error_to_string error)
let actual_proof_submissions config ~owner ~task_id =
  proof_transition config ~owner ~task_id Masc_domain.Claim "claim original proof Task";
  proof_transition config ~owner ~task_id Masc_domain.Start "start original proof Task";
  proof_transition config ~owner ~task_id Masc_domain.Submit_for_verification "first captured proof note";
  let first=actual_submission config task_id in
  settle_proof config ~task_id ~verification_id:first (Masc_domain.Verdict_rejected {reason="actual revision requested"});
  proof_transition config ~owner ~task_id Masc_domain.Submit_for_verification "second captured proof note";
  let second=actual_submission config task_id in
  settle_proof config ~task_id ~verification_id:second Masc_domain.Verdict_approved;
  first,second
let history_request state ~earlier = match begin_original_history_inspection state ~earlier ~limit:1 with
  | Some request -> request | None -> fail "original history request did not begin"
let history_snapshot config request =
  let page=match request.tcr_query with
    | Original_history_query ticket -> Creation_read.history_page_request ticket
    | Creation_query _ | Original_task_query _ | Original_evidence_query _ -> fail "history request changed kind" in
  let status,json=Server_dashboard_task_history_page.read ~config ~task_id:(Some page.hr_task_id)
    ~limit:(Some (string_of_int page.hr_limit)) ~cursor:page.hr_cursor in
  match status with
  | `OK -> Task_inspection.history_page ~request:page json
    |> Result.map_error (fun detail -> Creation_read.Invalid_reply detail) |> Result.map Creation_read.prepare_history
  | `Bad_request | `Conflict | `Service_unavailable -> Error (Creation_read.Read_failed (Yojson.Safe.to_string json))
let launch_history results state config request =
  let envelope=Protocol.capture_workspace_message state in
  Results.launch ~key:request.tcr_job ~observation:true state ~results
    ~boundary_error:(fun detail -> Creation_read.Read_failed detail)
    ~deliver:(fun result -> envelope (Protocol.Original_task_history_done (request,result)))
    (fun () -> history_snapshot config request)
let admit_history state = function
  | Protocol.Workspace_scoped (authority,reading,(Protocol.Original_task_history_done (request,result) as message)) ->
    if Protocol.workspace_message_admitted state ~authority ~reading message then complete_original_history_inspection state request result else false
  | _ -> fail "history response lost original read envelope"
let rec read_history_prefix results state config original ~earlier =
  let request=history_request state ~earlier in
  launch_history results state config request;
  check bool "actual original history page admitted" true (admit_history state (owned_message results));
  match Creation_read.history_observation original.tdr_inspection with
  | Masc_tui_fetched.Ready history when Option.is_some history.history_next_cursor ->
    read_history_prefix results state config original ~earlier:true
  | Ready history -> history
  | Absent | Loading | Failed _ | Stale _ -> fail "actual history prefix became unavailable"
let evidence_request state ~next = match begin_original_evidence_inspection state ~next with
  | Some request -> request | None -> fail "observed original submission did not start evidence read"
let evidence_coordinates request = match request.tcr_query with
  | Original_evidence_query ticket -> Creation_read.evidence_task_id ticket,Creation_read.evidence_verification_id ticket
  | Creation_query _ | Original_task_query _ | Original_history_query _ -> fail "evidence request changed kind"
let evidence_snapshot config request =
  let task_id,verification_id=evidence_coordinates request in
  match Server_routes_http_routes_verification.For_testing.operator_evidence_json
    ~config ~operator_id:"proof-reader-operator" ~task_id ~verification_id with
  | Error detail -> Error (Creation_read.Read_failed detail)
  | Ok json ->
    let decoded=Masc.Tui_decode.decode_verification_evidence_for_request ~task_id ~verification_id
      (`Assoc ["ok",`Bool true;"result",json]) |> Result.map_error (fun detail -> Creation_read.Invalid_reply detail) in
    Result.bind decoded (Creation_read.prepare_evidence ~task_id ~verification_id)
let launch_evidence results state config request =
  let envelope=Protocol.capture_workspace_message state in
  Results.launch ~key:request.tcr_job ~observation:true state ~results
    ~boundary_error:(fun detail -> Creation_read.Read_failed detail)
    ~deliver:(fun result -> envelope (Protocol.Original_task_evidence_done (request,result)))
    (fun () -> evidence_snapshot config request)
let admit_evidence state = function
  | Protocol.Workspace_scoped (authority,reading,(Protocol.Original_task_evidence_done (request,result) as message)) ->
    if Protocol.workspace_message_admitted state ~authority ~reading message then complete_original_evidence_inspection state request result else false
  | _ -> fail "evidence response lost original read envelope"
let check_submitted_note original expected = match Creation_read.evidence_observation original.tdr_inspection with
  | Masc_tui_fetched.Ready (Masc.Tui_decode.Evidence_items items) ->
    check bool "original persisted note content observed" true
      (List.exists (function Masc.Tui_decode.Ev_note note -> note=expected
        | Ev_collaboration _ | Ev_artifact _ | Ev_artifact_unreadable _ | Ev_binary _ -> false) items)
  | Absent | Loading | Failed _ | Stale _ | Ready (Evidence_access_unavailable _) -> fail "original evidence content unavailable"
let test_original_history_and_historical_evidence env () = Eio.Switch.run @@ fun sw ->
  let clock=Eio.Stdenv.clock env and owner="proof-history-original" in
  with_server ~clock ~sw ~owner @@ fun base config workspace _initial call ->
  Eio_context.with_turn_switch sw @@ fun () ->
  let state=creation_state base workspace in
  let original,task_id=retained_actual_creation state call ~workspace ~request_id:"original-proof-history" in
  let first,second=actual_proof_submissions config ~owner ~task_id in
  (* Archive the actually approved Task; only age its terminal fixture time. *)
  let backlog=Masc.Workspace.read_backlog_r config |> require_ok in
  let tasks=List.map (fun (task : Masc_domain.task) -> if task.id<>task_id then task else match task.task_status with
    | Done done_ -> {task with task_status=Done {done_ with completed_at="2000-01-01T00:00:00Z"}}
    | Todo | Claimed _ | InProgress _ | AwaitingVerification _ | Cancelled _ -> fail "actual proof was not approved") backlog.tasks in
  Masc.Workspace.write_backlog config {backlog with tasks};ignore (Masc.Workspace.archive_terminal_tasks config ~days:1 ());
  check bool "proof Task actually absent from live backlog" false
    (List.exists (fun (task : Masc_domain.task) -> task.id=task_id) (Masc.Workspace.get_tasks_raw config));
  check bool "original inspector opens without global rows" true (open_task_creation_inspection state ~keeper:"creation-keeper");
  let results=Results.create () in Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  creation_proof state call results;
  Input.insert state.msg_input "new input while original proof is read";
  let history=read_history_prefix results state config original ~earlier:false in
  check bool "actual history retains both submission identities across pages" true
    (List.mem first history.history_verifications && List.mem second history.history_verifications);
  let read_selected () =
    let request=evidence_request state ~next:true in
    let actual_task,verification_id=evidence_coordinates request in
    check string "evidence belongs to exact original Task" task_id actual_task;
    let expected=if verification_id=first then "first captured proof note"
      else if verification_id=second then "second captured proof note" else fail "selected an unobserved submission" in
    launch_evidence results state config request;
    check bool "historical evidence admitted after actual Task archive" true (admit_evidence state (owned_message results));
    check_submitted_note original expected;verification_id in
  let selected=read_selected () in
  check bool "explicit next reads the other observed actual submission" true (read_selected ()<>selected);
  check string "late history/evidence do not rewrite new input" "new input while original proof is read" (Input.contents state.msg_input);
  check bool "proof reads do not populate global rows or hand off work" true (task_domain_values state=[] && state.pending_task_followups=[]);
  original_unconfirmed original
let test_original_proof_failure_reopen_and_scope env () = Eio.Switch.run @@ fun sw ->
  let clock=Eio.Stdenv.clock env and owner="proof-retention-original" in
  with_server ~clock ~sw ~owner @@ fun base config workspace _initial call ->
  with_server ~clock ~sw ~owner:"proof-retention-foreign" @@ fun _other other_config other_workspace _other_task _other_call ->
  Eio_context.with_turn_switch sw @@ fun () ->
  let state=creation_state base workspace in
  let original,task_id=retained_actual_creation state call ~workspace ~request_id:"original-proof-retention" in
  ignore (actual_proof_submissions config ~owner ~task_id);
  check bool "original inspector selected" true (open_task_creation_inspection state ~keeper:"creation-keeper");
  let results=Results.create () in Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  creation_proof state call results;ignore (read_history_prefix results state config original ~earlier:false);
  let request=evidence_request state ~next:true in
  let _,verification_id=evidence_coordinates request in
  launch_evidence results state config request;
  check bool "initial filed proof admitted" true (admit_evidence state (owned_message results));
  let path=Workspace_verification_store.request_path base verification_id in
  let recorded=Fs_compat.load_file path in
  Fs_compat.save_file path "{corrupt actual submitted evidence";
  let failed=evidence_request state ~next:false in launch_evidence results state config failed;
  check bool "evidence refresh failure settles original request" true (admit_evidence state (owned_message results));
  (match Creation_read.evidence_observation original.tdr_inspection with
   | Masc_tui_fetched.Stale (Masc.Tui_decode.Evidence_items _,Creation_read.Read_failed _) -> ()
   | Masc_tui_fetched.Absent | Loading | Ready _ | Failed _ | Stale _ ->
     fail "corrupt persistent proof erased prior evidence or became empty success");
  let wrong_header=match Yojson.Safe.from_string recorded with
    | `Assoc fields -> `Assoc (List.map (fun (name,value) -> if name="id" then name,`String "another-filed-submission" else name,value) fields)
    | _ -> fail "actual persisted submission is not an object" in
  Fs_compat.save_file path (Yojson.Safe.to_string wrong_header);
  let mismatched=evidence_request state ~next:false in launch_evidence results state config mismatched;
  check bool "mismatched durable request identity settles as failure" true (admit_evidence state (owned_message results));
  (match Creation_read.evidence_observation original.tdr_inspection with
   | Masc_tui_fetched.Stale (Masc.Tui_decode.Evidence_items _,Creation_read.Read_failed _) -> ()
   | Masc_tui_fetched.Absent | Loading | Ready _ | Failed _ | Stale _ ->
     fail "another durable request identity borrowed the original proof");
  (match Server_routes_http_routes_verification.For_testing.operator_evidence_json
    ~config ~operator_id:"proof-reader-operator" ~task_id ~verification_id:"../../outside" with
   | Error _ -> () | Ok _ -> fail "non-component verification identity reached evidence lookup");
  Fs_compat.save_file path recorded;
  let old=evidence_request state ~next:false in launch_evidence results state config old;
  let held=owned_message results in close_task_creation_inspection state ~reason:Creation_read.Interrupted;
  check bool "same original inspector reopens" true (open_task_creation_inspection state ~keeper:"creation-keeper");
  creation_proof state call results;ignore (read_history_prefix results state config original ~earlier:false);
  let fresh=evidence_request state ~next:true in launch_evidence results state config fresh;
  check bool "fresh proof admitted after reopen" true (admit_evidence state (owned_message results));
  check bool "held completed proof cannot finish a reopened original" false (admit_evidence state held);
  let wrong=Server_routes_http_routes_verification.For_testing.operator_evidence_json
    ~config ~operator_id:"proof-reader-operator" ~task_id:"task-another-original" ~verification_id in
  (match wrong with
   | Ok json -> (match Masc.Tui_decode.decode_verification_evidence_for_request ~task_id:"task-another-original" ~verification_id
      (`Assoc ["ok",`Bool true;"result",json]) with
     | Ok (Evidence_access_unavailable _) -> () | _ -> fail "another Task borrowed the filed submission")
   | Error detail -> fail detail);
  let history=history_request state ~earlier:false in launch_history results state config history;
  let foreign=owned_message results and other_before=Masc.Workspace.get_tasks_raw other_config in
  suspend_workspace_readings state;state.workspace_authority <- Workspace_authority 1;state.server_identity <- Some other_workspace;
  check bool "completed history cannot borrow a foreign workspace" false (admit_history state foreign);
  check bool "foreign actual Task resources unchanged" true (other_before=Masc.Workspace.get_tasks_raw other_config);
  check string "source inspection did not rewrite stored evidence" recorded (Fs_compat.load_file path);
  original_unconfirmed original

let () = Eio_main.run @@ fun env ->
  let snapshot = Eio_context.snapshot_state () in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp.set_net (Eio.Stdenv.net env);
  Mcp.set_clock (Eio.Stdenv.clock env);
  Fun.protect ~finally:(fun () -> Fs_compat.clear_fs (); Eio_context.restore_state snapshot) (fun () ->
    run "TUI retained Task cancellation resource results"
      ["protocol/resources",[
        test_case "accepted original cancel survives workspace withdrawal and full notifications" `Quick
          (test_accepted_cancel_outlives_workspace_withdrawal env);
        test_case "unstarted, ended-session and actual workspace refusal preserve Tasks" `Quick
          (test_no_switch_closed_owner_and_real_workspace_refusal env);
        test_case "created original Task survives workspace withdrawal and full notifications" `Quick
          (test_created_task_survives_workspace_withdrawal env);
        test_case "actual unknown creation and edited input retain explicit original recovery" `Quick
          (test_unknown_task_and_original_input_recovery env);
        test_case "lost actual creation reply, equal titles, duplicates and deletion retain exact facts" `Quick
          (test_creation_receipt_after_lost_reply_and_duplicate_request env);
        test_case "actual creation refusals and corrupt primary never borrow recovery authority" `Quick
          (test_creation_receipt_refusals_and_corrupt_primary env);
        test_case "original actual creation inspection and refused cross-request reply preserve input" `Quick
          (test_original_inspection_and_refused_actual_reply env);
        test_case "actual receipt inspection survives reopen/history and refuses foreign workspace" `Quick
          (test_inspection_reopen_history_and_workspace_withdrawal env);
        test_case "actual original Task reads bypass unavailable global rows and observe archive" `Quick
          (test_original_task_read_without_global_rows_and_archive env);
        test_case "actual deletion, archive failure and late Task scopes retain original evidence" `Quick
          (test_original_task_delete_failure_and_late_scope env);
        test_case "original paged history and exact historical evidence survive real Task archive" `Quick
          (test_original_history_and_historical_evidence env);
        test_case "corrupt filed proof, reopen and foreign late history retain original evidence" `Quick
          (test_original_proof_failure_reopen_and_scope env)]])
