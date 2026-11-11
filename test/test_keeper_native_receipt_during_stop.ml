(* A server stop fences the Owner inventory, then stops each Owner, which
   cancels its running child. Core commits the cancelled native call's terminal
   disposition under cancellation protection and hands it to the sink that
   [Keeper_direct_native_continuation.prepare] built. That sink advances the
   receipt to the call's last checkpoint and then records the terminal, both
   through the inventory, and [reconcile_after_dispatch] reads the receipt back
   the same way. This test runs a real Core execution through [prepare], with a
   provider request that never completes, stops the inventory while that
   request is open, and checks the receipt the cancelled child read back, what
   the stopped Owner settled, which new calls it still refuses, and what the
   next process finds. Assertions are on typed states, never on message
   text. *)
open Alcotest
open Masc
module Native = Keeper_direct_native_continuation
module Registry = Keeper_owner_registry
module Agent = Agent_core.Agent
module Identity = Keeper_chat_delivery_identity

let keeper_name = "native-stop-receipt"
let session_id = "native-stop-receipt-session"
let model_id = "native-stop-receipt-model"
let runtime_id = "native-stop-receipt.runtime"
let goal = "Answer once."
let late_call_id = "019a0010-1000-7000-8000-0000000000c2"
let require label = function Ok value -> value | Error _ -> fail (label ^ " failed")
let operation_id = Keeper_chat_operation.Operation_id.of_string "native-stop-receipt-operation"
  |> require "operation ID"

(* What the stopped Owner held once [begin_stopping_all] returned. *)
type stop_observation =
  { child_receipt : (Keeper_native_call.state, Registry.command_error) result option
      (** Read by the cancelled child through the inventory after its dispatch
          ended, before the Owner settled the operation. *)
  ; operation : Keeper_chat_operation.t
  ; native_call : Keeper_native_call.state
  ; registry_bind : (unit, Registry.command_error) result
  ; owner_bind : (unit, Keeper_owner.error) result
  }

(* The recovery decides the settlement. *)
let recovery_label (disposition : Agent.execution_terminal_disposition) =
  match disposition.recovery with
  | Agent.Retire -> "retire"
  | Agent.Operator_repair_required Agent.Effect_outcome_unknown -> "operator repair"

let outcome_label (disposition : Agent.execution_terminal_disposition) =
  match disposition.outcome with
  | Agent.Terminal_succeeded -> "succeeded"
  | Agent.Terminal_failed -> "failed"
  | Agent.Terminal_cancelled -> "cancelled"

let late_call (operation : Keeper_chat_operation.t) =
  let seed_checkpoint =
    Keeper_checkpoint_ref.of_persisted
      ~trace_id:(Keeper_id.Trace_id.of_string session_id |> require "trace id")
      ~turn_count:1 ~sha256:(Keeper_checkpoint_ref.sha256_of_canonical_bytes "late bind seed")
    |> require "late checkpoint" in
  let locator = Agent.execution_locator_of_yojson
      (`Assoc ["version", `Int 1; "run_id", `String "execution-run-late-bind"])
    |> require "late locator" in
  Keeper_native_call.create ~call_id:late_call_id ~runtime_id
    ~operation_digest:operation.execution_digest
    ~api:(Keeper_native_call.New_input {seed_message_count=0})
    ~seed_checkpoint ~locator
  |> require "late call"

let failed_kind (operation : Keeper_chat_operation.t) =
  match operation.state with
  | Keeper_chat_operation.Failed {failure; _} -> Some failure.kind
  | Keeper_chat_operation.Queued | Keeper_chat_operation.Running _
  | Keeper_chat_operation.Succeeded _ | Keeper_chat_operation.Cancelled _ -> None

let rec mkdir_p path =
  if not (Sys.file_exists path) then (mkdir_p (Filename.dirname path); Unix.mkdir path 0o700)

let install_fixture_catalog ~sw =
  let previous_catalog = Llm_provider.Catalog_snapshot.current () in
  Eio.Switch.on_release sw (fun () -> Llm_provider.Catalog_snapshot.publish previous_catalog);
  let catalog = Printf.sprintf
      "[[models]]\nmodel_id = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n" model_id in
  Llm_provider.Model_catalog.of_toml_string ~source:"native-stop-receipt-test" catalog
    |> require "model catalog" |> (fun models -> Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Some models) ~providers:(None)))

(* The repetition frame a direct operation's native checkpoints must carry. *)
let context_for_operation () =
  let context = Agent_core.Context.create () in
  let frame = Keeper_repetition_snapshot.admit Keeper_repetition_snapshot.empty
      (Keeper_repetition_snapshot.Fresh (Keeper_execution_scope_id.direct_operation operation_id))
    |> require "direct scope" in
  Keeper_repetition_scope.save context frame;
  context

(* Runs the operation through [prepare] until its provider request is open,
   then stops the inventory the way the server shutdown hook does. *)
let stop_while_dispatching env ~root ~workspace ~session_dir ~cancel_hook ~settled_tools =
  Eio.Switch.run @@ fun sw ->
  let tool_calls = Atomic.make 0 in
  let second_request, resolve_second_request = Eio.Promise.create () in
  let tool_reply =
    {|{"id":"stop-tools","model":"native-stop-receipt-model","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"stop-effect-1","type":"function","function":{"name":"record_effect","arguments":"{}"}},{"id":"stop-effect-2","type":"function","function":{"name":"record_effect","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
  in
  let behavior =
    if settled_tools then Exact_output_fixture.Reply_with (fun index _ ->
      if index = 0 then `OK, tool_reply
      else (
        Eio.Promise.resolve resolve_second_request ();
        Eio.Fiber.await_cancel ()))
    else Exact_output_fixture.Incomplete_reply "{" in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      behavior in
  let provider_cfg = Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture"
      ~model_id ~base_url:server.base_url ~request_path:"/v1/chat/completions" () in
  let child_receipt = ref None in
  let execute ~sw:turn_sw ~keeper_name:_ ~claim =
    let operation : Keeper_chat_operation.t =
      claim () |> require "claim operation" |> Option.get in
    let binding : Native.binding =
      {base_path=root; keeper_name; operation_id;
       execution_digest=operation.execution_digest; session_dir; session_id} in
    (match Native.load ~binding |> require "load native admission" with
     | Native.No_pending -> ()
     | Native.Resume _ | Native.Terminal_pending _ -> fail "a fresh operation has a native call");
    let tools = if not settled_tools then [] else
      [Agent_core.Tool.create ~name:"record_effect" ~description:"Record one fixture effect"
         ~parameters:[] (fun _ ->
           let ordinal = Atomic.fetch_and_add tool_calls 1 + 1 in
           Ok {Agent_core.Types.content=Printf.sprintf "original effect %d" ordinal;
               content_blocks=None; _meta=None})] in
    let config = Runtime_agent.default_config ~media_store:(Agent_core.History.Memory_store.create ()) ~name:keeper_name ~provider_cfg
        ~system_prompt:"Answer once." ~tools in
    let config = {config with context=Some (context_for_operation ())} in
    let agent_ref = ref None in
    let input = [Agent_core.Types.Text goal] in
    let prepared = Native.prepare ~binding ~runtime_id ~config ~agent_core_checkpoint:None
        ~input:(Native.New_input {blocks=input; metadata=[]}) ~agent_ref ()
      |> require "prepare native call" in
    let config = Native.config prepared in
    (* The child is cancelled here, so the read runs protected, as the one in
       [reconcile_after_dispatch] does. *)
    let read_back () = Eio.Cancel.protect (fun () ->
      child_receipt := Some
          (Registry.direct_native_call ~base_path:root ~keeper_name ~operation_id);
      if settled_tools then (
        let call = match !child_receipt with
          | Some (Ok (Keeper_native_call.Terminal_unacknowledged (call, _))) -> call
          | Some (Ok (No_native_call | Active _)) | Some (Error _) | None ->
            fail "cancelled child lost its original native receipt" in
        let checkpoint = Keeper_checkpoint_store.load_retained_exact_snapshot
            ~session_dir ~reference:call.checkpoint |> require "retained terminal checkpoint"
          |> Keeper_checkpoint_store.exact_snapshot_checkpoint in
        let results = checkpoint.messages
          |> List.concat_map (fun (message : Agent_core.Types.message) -> message.content)
          |> List.filter_map (function
            | Agent_core.Types.ToolResult {tool_use_id; content; _} -> Some (tool_use_id, content)
            | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
            | Image _ | Document _ | Audio _ -> None) in
        check (list (pair string string)) "Owner's final checkpoint preserves both original results"
          ["stop-effect-1", "original effect 1"; "stop-effect-2", "original effect 2"] results)) in
    match
      Native.reconcile_after_dispatch binding (fun () ->
        Runtime_agent.run_blocks ~sw:turn_sw ~net:env#net ~config ~agent_ref
          ~input_metadata:[] input)
    with
    | Ok _ -> fail "the provider request that never completes answered"
    | Error _ ->
      read_back ();
      Keeper_owner.Operation_failed
        {kind=Keeper_chat_operation.Turn_exception; detail="dispatch failed"; outcome_ref=None}
    | exception exn ->
      read_back ();
      raise exn
  in
  let runner : Keeper_owner.operation_runner =
    {ready=(fun ~keeper_name:_ -> true); execute;
     on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~operations:_ ~execution:_ -> ())} in
  Registry.install_from_store ~sw ~operation_runner:(Some runner)
    ~on_turn_slot_released:None workspace |> require "install Owner" |> ignore;
  Keeper_direct_native_continuation.complete_restart_settlements
    ~runtime:(Runtime_agent_execution_runtime.get () |> Option.get) ~base_path:root
    |> require "complete startup native journal settlement" |> ignore;
  let owner = Registry.get ~base_path:root ~keeper_name |> require "Owner handle" in
  let input = Keeper_chat_operation_payload.input_to_json ~message:goal ~user_blocks:[]
      ~turn_instructions:None ~surface_context:None ~attachments:[]
    |> Keeper_chat_operation.canonical_json |> require "canonical input" in
  let thread_id = "keeper:" ^ keeper_name in
  let channel = Keeper_continuation_channel.dashboard ~thread_id
    |> require "continuation channel" in
  let source = Keeper_chat_operation_payload.source_to_json ~submitted_by:"operator"
      ~thread_id ~continuation_channel:channel
      ~surface:(Surface_ref.Dashboard {session_id=None})
      ~channel:"" ~channel_user_id:"" ~channel_user_name:"" ~channel_workspace_id:""
      ~conversation_id:None ~external_message_id:None ~workspace_id:None ~extra_mentions:[]
      ~sender_keeper:None ~user_row_origin:Keeper_chat_store.Needs_append
    |> require "operation source" in
  Registry.submit_operation ~base_path:root ~keeper_name ~operation_id
    ~source ~input |> require "submit operation" |> ignore;
  Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
    (fun () -> Eio.Promise.await
      (if settled_tools then second_request else server.first_request_arrived));
  let stop () =
    match Registry.begin_stopping_all ~base_path:root with
    | Ok results -> List.iter (require "Owner stop") results
    | Error _ -> fail "the inventory did not stop" in
  if not cancel_hook then
    Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds stop
  else (
    let call = match Keeper_owner.direct_native_call owner ~operation_id
        |> require "read original native call" with
      | Keeper_native_call.Active call -> call
      | No_native_call | Terminal_unacknowledged _ -> fail "original call is not active" in
    let runtime = Runtime_agent_execution_runtime.get () |> Option.get in
    let dir = Eio.Path.(env#fs / session_dir / "native-executions" / call.call_id) in
    let hook_context, resolve_hook_context = Eio.Promise.create () in
    let hook_done, resolve_hook_done = Eio.Promise.create () in
    let hook_returned = ref false in
    let owner_stop_completed = ref false in
    (* Core can publish its terminal while its final checkpoint waits on this
       real store lock. Cancel only the shutdown hook at that boundary, as the
       server's cleanup timeout does; the Owner itself is still alive. *)
    Keeper_checkpoint_store.with_session_lock ~session_dir (fun _ ->
      Shutdown_hooks.register_keeper_shutdown (fun () ->
        stop ();
        owner_stop_completed := true);
      Eio.Fiber.fork ~sw (fun () ->
        let previous_base = Sys.getenv_opt "MASC_BASE_PATH" in
        Fun.protect ~finally:(fun () ->
          (match previous_base with
           | Some value -> Unix.putenv "MASC_BASE_PATH" value
           | None -> Unix.unsetenv "MASC_BASE_PATH");
          Shutdown_hooks.register_keeper_shutdown (fun () -> ())) (fun () ->
          Unix.putenv "MASC_BASE_PATH" root;
          let cancelled =
            try
              Eio.Cancel.sub (fun context ->
                Eio.Promise.resolve resolve_hook_context context;
                Shutdown_hooks.run_all ();
                Eio.Fiber.check ());
              false
            with Eio.Cancel.Cancelled Eio.Time.Timeout -> true in
          hook_returned := true;
          Eio.Promise.resolve resolve_hook_done (cancelled, !owner_stop_completed)));
      let context = Eio.Promise.await hook_context in
      let rec terminal () =
        let projection = Agent.open_execution_projection ~runtime ~dir call.locator
          |> require "open canonical native journal" in
        match Agent.read_execution_terminal projection |> require "read canonical terminal" with
        | Some terminal -> terminal
        | None -> Eio.Fiber.yield (); terminal () in
      let terminal = Eio.Time.with_timeout_exn env#clock
          Exact_output_fixture.fixture_wait_seconds terminal in
      check bool "Core cancelled the exact original before the hook deadline" true
        (terminal.disposition.outcome = Agent.Terminal_cancelled);
      check int "canonical journal retains every original settled result"
        (if settled_tools then 2 else 0) (List.length terminal.settled_tool_results);
      check bool "the Owner receipt still waits on its final checkpoint" true
        (match Keeper_owner.direct_native_call owner ~operation_id
           |> require "read blocked receipt" with
         | Keeper_native_call.Active current -> current.call_id = call.call_id
         | No_native_call | Terminal_unacknowledged _ -> false);
      Eio.Cancel.cancel context Eio.Time.Timeout;
      Eio.Fiber.yield ();
      check bool "hook cancellation cannot abandon the original Owner settlement"
        false !hook_returned)
    |> require "hold the final checkpoint boundary";
    let cancelled, owner_stop_completed =
      Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
        (fun () -> Eio.Promise.await hook_done) in
    check bool "the original hook cancellation remains observable" true cancelled;
    check bool "the Owner stop completed before the hook returned" true
      owner_stop_completed);
  check int "shutdown does not dispatch another provider request"
    (if settled_tools then 2 else 1) (Exact_output_fixture.post_count server);
  check int "shutdown does not repeat any settled tool effect"
    (if settled_tools then 2 else 0) (Atomic.get tool_calls);
  let operation = Keeper_owner.exact_operation owner operation_id
    |> require "read stopped operation" |> Option.get in
  let native_call = Keeper_owner.direct_native_call owner ~operation_id
    |> require "read stopped native call" in
  let call = late_call operation in
  let registry_bind = Registry.bind_direct_native_call ~base_path:root ~keeper_name
      ~operation_id ~execution_digest:operation.execution_digest ~observed:native_call ~call in
  let owner_bind = Keeper_owner.bind_direct_native_call owner ~operation_id
      ~execution_digest:operation.execution_digest ~observed:native_call ~call in
  {child_receipt = !child_receipt; operation; native_call; registry_bind; owner_bind}

(* The next process installs the inventory again; its Owner settles whatever
   the stopped one left Running. No runner, so nothing claims a requeued row. *)
let after_restart ~root ~workspace =
  Eio.Switch.run @@ fun sw ->
  Registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None
    workspace |> require "reinstall Owner" |> ignore;
  Keeper_direct_native_continuation.complete_restart_settlements
    ~runtime:(Runtime_agent_execution_runtime.get () |> Option.get) ~base_path:root
    |> require "complete startup native journal settlement" |> ignore;
  Registry.exact_operation ~base_path:root ~keeper_name operation_id
  |> require "read restarted operation" |> Option.get

let check_failure_projection ~root =
  let request_id = Keeper_chat_operation.Operation_id.to_string operation_id
    |> Identity.Request_id.of_string |> require "failure request ID" in
  let key = Identity.Operation request_id in
  let rows = Keeper_chat_store.load_result ~base_dir:root ~keeper_name
    |> require "load failure transcript"
    |> List.filter (fun (row : Keeper_chat_store.chat_message) ->
      match row.delivery_provenance with
      | Some provenance -> Identity.delivery_key_equal provenance.delivery_key key
          && Identity.transcript_slot_equal provenance.transcript_slot Identity.Settled_failure
      | None -> false) in
  match rows with
  | [row] ->
    check bool "the operation has a failure transcript" true
      (Keeper_chat_store.Role.equal row.role Keeper_chat_store.Role.Request_failure);
    check bool "the failure retains its dashboard route" true
      (Option.fold ~none:false
         ~some:(Surface_ref.equal (Surface_ref.Dashboard {session_id=None})) row.surface)
  | [] | _::_::_ -> fail "failure transcript is missing or duplicated"

let run_case ?(cancel_hook=false) ?(settled_tools=false) root =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  ignore (Server_startup_state.mark_state_ready ());
  Runtime_agent_execution_runtime.initialize ~sw ~domain_mgr:env#domain_mgr ~domain_count:1
    |> require "native execution runtime";
  install_fixture_catalog ~sw;
  let workspace = Workspace.default_config root in
  ignore (Workspace.init workspace ~agent_name:(Some "native-stop-receipt-test"));
  let meta = Masc_test_deps.meta_of_json_fixture (`Assoc [
    "name", `String keeper_name; "trace_id", `String session_id;
    "activation_mode", `String "manual"]) |> require "meta" in
  Keeper_meta_store.replace_snapshot workspace meta |> require "persist meta";
  (* The session lives where the Owner and the startup sweep look. *)
  let session_dir = Filename.concat
      (Keeper_fs.session_store_path_for_runtime_root (Workspace.masc_dir workspace))
      session_id in
  mkdir_p session_dir;
  let stopped = stop_while_dispatching env ~root ~workspace ~session_dir
      ~cancel_hook ~settled_tools in
  let restarted = after_restart ~root ~workspace in
  check_failure_projection ~root;
  stopped, restarted

let with_root f =
  let root = Filename.temp_dir "keeper-native-stop-receipt-" "" in
  Fun.protect ~finally:(fun () ->
    Eio_main.run (fun env -> Eio.Path.rmtree ~missing_ok:true Eio.Path.(env#fs / root)))
    (fun () -> f root)

let test_hook_cancellation_waits_for_callback () =
  with_root (fun root ->
    let previous_base = Sys.getenv_opt "MASC_BASE_PATH" in
    Fun.protect ~finally:(fun () ->
      (match previous_base with
       | Some value -> Unix.putenv "MASC_BASE_PATH" value
       | None -> Unix.unsetenv "MASC_BASE_PATH");
      Shutdown_hooks.register_keeper_shutdown (fun () -> ())) (fun () ->
      Unix.putenv "MASC_BASE_PATH" root;
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let entered, resolve_entered = Eio.Promise.create () in
      let release, resolve_release = Eio.Promise.create () in
      let hook_context, resolve_hook_context = Eio.Promise.create () in
      let hook_done, resolve_hook_done = Eio.Promise.create () in
      let completed = ref false in
      let release_pending = ref true in
      let release_callback () =
        if !release_pending then (
          release_pending := false;
          Eio.Promise.resolve resolve_release ()) in
      Fun.protect ~finally:release_callback (fun () ->
        Shutdown_hooks.register_keeper_shutdown (fun () ->
          Eio.Promise.resolve resolve_entered ();
          Eio.Promise.await release;
          completed := true);
        Eio.Fiber.fork ~sw (fun () ->
          let cancelled =
            try
              Eio.Cancel.sub (fun context ->
                Eio.Promise.resolve resolve_hook_context context;
                Shutdown_hooks.run_all ();
                Eio.Fiber.check ());
              false
            with Eio.Cancel.Cancelled Eio.Time.Timeout -> true in
          Eio.Promise.resolve resolve_hook_done cancelled);
        let context = Eio.Time.with_timeout_exn env#clock
            Exact_output_fixture.fixture_wait_seconds (fun () ->
              let context = Eio.Promise.await hook_context in
              Eio.Promise.await entered;
              context) in
        (* Resolving [entered] does not yield: when the parent resumes, the
           callback has suspended on [release] in its cancellation context. *)
        Eio.Cancel.cancel context Eio.Time.Timeout;
        release_callback ();
        let cancelled = Eio.Time.with_timeout_exn env#clock
            Exact_output_fixture.fixture_wait_seconds
            (fun () -> Eio.Promise.await hook_done) in
        check bool "the callback finished after cancellation" true !completed;
        check bool "the hook cancellation remains observable" true cancelled)))

let test_stop_records_the_cancelled_terminal ?(cancel_hook=false) ?(settled_tools=false) () =
  with_root (fun root ->
    let stopped, restarted = run_case ~cancel_hook ~settled_tools root in
    let receipt = match stopped.child_receipt with
      | Some (Ok (Keeper_native_call.Terminal_unacknowledged (call, disposition))) ->
        Some (call, disposition)
      | Some (Ok (Keeper_native_call.No_native_call | Keeper_native_call.Active _))
      | Some (Error _) | None -> None in
    check bool "the cancelled child read back a terminal receipt during the stop" true
      (Option.is_some receipt);
    check (option string) "the stop ended the provider call as cancelled"
      (Some "cancelled")
      (Option.map (fun (_, disposition) -> outcome_label disposition) receipt);
    check (option string) "the receipt retires the call with no unsettled tool"
      (Some "retire")
      (Option.map (fun (_, disposition) -> recovery_label disposition) receipt);
    check bool "the receipt advanced to the terminal checkpoint past the seed" true
      (match receipt with
       | Some (call, _) ->
         not (Keeper_checkpoint_ref.equal call.Keeper_native_call.checkpoint call.seed_checkpoint)
       | None -> false);
    check bool "the stopped operation failed as interrupted by restart instead of staying Running" true
      (failed_kind stopped.operation = Some Keeper_chat_operation.Interrupted_by_restart);
    check bool "its settlement acknowledged the retired call" true
      (Keeper_native_call.equal_state Keeper_native_call.No_native_call stopped.native_call);
    check bool "the inventory refuses a new native call behind the stop fence" true
      (match stopped.registry_bind with
       | Error (Registry.Command_lookup_failed Registry.Inventory_stopping) -> true
       | Ok () | Error (Registry.Command_lookup_failed
           ( Registry.Inventory_not_installed _ | Registry.Owner_not_found _
           | Registry.Owner_unavailable _ | Registry.Owner_initialization_failed _ ))
       | Error (Registry.Command_lifecycle_reserved _ | Registry.Command_rejected _) -> false);
    check bool "the stopping Owner itself refuses to bind a native call" true
      (match stopped.owner_bind with
       | Error Keeper_owner.Owner_stopping -> true
       | Ok ()
       | Error (Keeper_owner.Reducer_rejected _ | Keeper_owner.Operation_rejected _
               | Keeper_owner.Store_unavailable _ | Keeper_owner.Owner_closed) -> false);
    check bool "the next process finds it settled, not requeued for a dead journal" true
      (failed_kind restarted = Some Keeper_chat_operation.Interrupted_by_restart))

let () =
  run "native receipt during stop"
    ["owner stop", [
       test_case "a stop records the cancelled call's terminal" `Quick
         (fun () -> test_stop_records_the_cancelled_terminal ());
       test_case "hook cancellation waits for the original native terminal" `Quick
         (fun () -> test_stop_records_the_cancelled_terminal ~cancel_hook:true ());
       test_case "hook cancellation preserves two settled effects without replay" `Quick
         (fun () -> test_stop_records_the_cancelled_terminal
           ~cancel_hook:true ~settled_tools:true ());
       test_case "hook cancellation waits for a suspended callback" `Quick
         test_hook_cancellation_waits_for_callback]]
