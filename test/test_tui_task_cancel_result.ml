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
          (test_creation_receipt_refusals_and_corrupt_primary env)]])
