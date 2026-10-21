(** Actual in-process MCP Task cancellation and persistent workspaces meet the
    production retained-result producer and finite UI delivery policy. No HTTP
    network, TUI process, screen or provider is exercised. *)
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
let cancel ~call ~task_id ~expected_workspace ~reason =
  call (Wire.request_body ~request_id:"original-cancel" ~tool:"masc_transition"
    ~arguments:(Wire.task_cancel_arguments ~task_id ~reason ~expected_workspace))
  |> tool_result ~request_id:"original-cancel"
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
  with_server ~clock ~sw ~owner:"cancel-owner-a" @@ fun base_a config_a expected_a original_a call_a ->
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
      let result = cancel ~call:call_a ~task_id:original_a.id ~expected_workspace:expected_a ~reason in
      ignore (require_ok result);
      cancelled config_a ~owner:"cancel-owner-a" ~reason;
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
  cancelled config_a ~owner:"cancel-owner-a" ~reason;
  check bool "foreign actual Task resources remain unchanged" true (foreign_before=Masc.Workspace.get_tasks_raw config_b)

let test_no_switch_closed_owner_and_real_workspace_refusal env () =
  let snapshot = Eio_context.snapshot_state () in
  Fun.protect ~finally:(fun () -> Eio_context.restore_state snapshot) @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  with_server ~clock ~sw ~owner:"cancel-owner-original" @@ fun _base config expected original call ->
  with_server ~clock ~sw ~owner:"cancel-owner-foreign" @@ fun _foreign_base foreign_config foreign _other _call ->
  let reason = "original reason retained on refusal" in
  let perform () = cancel ~call ~task_id:original.id ~expected_workspace:expected ~reason in
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
      cancel ~call ~task_id:original.id ~expected_workspace:foreign ~reason));
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
          (test_no_switch_closed_owner_and_real_workspace_refusal env)]])
