(* A server stop fences the Owner inventory, then stops each Owner, which
   cancels its running child. Core commits the cancelled native call's terminal
   disposition under cancellation protection and hands it to the host sink,
   which records it in the Owner through the inventory. This test runs a real
   Core execution whose provider request never completes, stops the inventory
   while that request is open, and checks what the stopped Owner settled and
   what the next process finds. When the fence refused the receipt, the Owner
   left the operation Running with an Active call, the restart requeued it, and
   its next dispatch found a journal that had already ended. Assertions are on
   typed states, never on message text. *)
open Alcotest
open Masc
module Native = Keeper_direct_native_continuation
module Registry = Keeper_owner_registry
module Agent = Agent_core.Agent

let keeper_name = "native-stop-receipt"
let session_id = "native-stop-receipt-session"
let model_id = "native-stop-receipt-model"
let runtime_id = "native-stop-receipt.runtime"
let goal = "Answer once."
let call_id = "019a0010-1000-7000-8000-0000000000c1"
let late_call_id = "019a0010-1000-7000-8000-0000000000c2"
let require label = function Ok value -> value | Error _ -> fail (label ^ " failed")
let operation_id = Keeper_chat_operation.Operation_id.of_string "native-stop-receipt-operation"
  |> require "operation ID"

(* What the host sink saw when Core handed it the terminal disposition. *)
type terminal_sink =
  { disposition : Agent.execution_terminal_disposition
  ; recorded : bool
  }

(* What the stopped Owner held once [begin_stopping_all] returned. *)
type stop_observation =
  { sink : terminal_sink option
  ; operation : Keeper_chat_operation.t
  ; native_call : Keeper_native_call.state
  ; late_bind : (unit, Registry.command_error) result
  }

let cancelled_retired =
  { Agent.outcome = Agent.Terminal_cancelled; recovery = Agent.Retire }

let seed_checkpoint =
  Keeper_checkpoint_ref.create
    ~trace_id:(Keeper_id.Trace_id.of_string session_id |> require "trace id")
    ~turn_count:1 ~canonical_checkpoint_bytes:"stop receipt seed"
  |> require "checkpoint"

let native_call ~call_id ~(operation : Keeper_chat_operation.t) locator =
  Keeper_native_call.create ~call_id ~runtime_id
    ~operation_digest:operation.execution_digest
    ~api:(Keeper_native_call.New_input {seed_message_count=0})
    ~seed_checkpoint ~locator

let failed_kind (operation : Keeper_chat_operation.t) =
  match operation.state with
  | Keeper_chat_operation.Failed {failure; _} -> Some failure.kind
  | Keeper_chat_operation.Queued | Keeper_chat_operation.Running _
  | Keeper_chat_operation.Succeeded _ | Keeper_chat_operation.Cancelled _ -> None

let install_fixture_catalog ~sw =
  let previous_catalog = Llm_provider.Model_catalog.global () in
  Eio.Switch.on_release sw (fun () -> match previous_catalog with
    | None -> Llm_provider.Model_catalog.clear_global ()
    | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
  let catalog = Printf.sprintf
      "[[models]]\nid_prefix = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n" model_id in
  Llm_provider.Model_catalog.of_toml_string ~source:"native-stop-receipt-test" catalog
    |> require "model catalog" |> Llm_provider.Model_catalog.set_global

(* Runs the operation until its provider request is open, then stops the
   inventory the way the server shutdown hook does. *)
let stop_while_dispatching env ~root ~workspace =
  Eio.Switch.run @@ fun sw ->
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Incomplete_reply "{") in
  let provider_cfg = Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture"
      ~model_id ~base_url:server.base_url ~request_path:"/v1/chat/completions" () in
  let session_dir = Filename.concat root session_id in
  let sink = ref None in
  let execute ~sw:turn_sw ~keeper_name:_ ~claim =
    let operation : Keeper_chat_operation.t =
      claim () |> require "claim operation" |> Option.get in
    let binding : Native.binding =
      {base_path=root; keeper_name; operation_id;
       execution_digest=operation.execution_digest; session_dir; session_id} in
    let runtime = Runtime_agent_execution_runtime.get () |> Option.get in
    let dir = Eio.Path.(env#fs / session_dir / "native-executions" / call_id) in
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
    (* The same Owner writes the native dispatch makes: bind before any
       provider effect, then record the terminal Core hands over. *)
    let on_scope_ready locator =
      let call = native_call ~call_id ~operation locator |> require "native call" in
      Registry.bind_direct_native_call ~base_path:root ~keeper_name ~operation_id
        ~execution_digest:operation.execution_digest
        ~observed:Keeper_native_call.No_native_call ~call
      |> Result.map_error Registry.command_error_to_string in
    let on_terminal_disposition disposition =
      let recorded =
        Registry.terminal_direct_native_call ~base_path:root ~keeper_name ~operation_id
          ~execution_digest:operation.execution_digest ~call_id ~disposition in
      sink := Some {disposition; recorded = Result.is_ok recorded};
      Result.map_error Registry.command_error_to_string recorded in
    let execution_store = Agent.execution_store ~runtime ~dir
        ~on_scope_ready ~on_terminal_disposition () in
    let config = Runtime_agent.default_config ~name:keeper_name ~provider_cfg
        ~system_prompt:"Answer once." ~tools:[] in
    let config = {config with execution_store=Some execution_store} in
    Native.reconcile_after_dispatch binding (fun () ->
      match Runtime_agent.run ~sw:turn_sw ~net:env#net ~config goal with
      | Ok _ -> fail "the provider request that never completes answered"
      | Error _ ->
        Keeper_owner.Operation_failed
          {kind=Keeper_chat_operation.Turn_exception; detail="dispatch failed";
           outcome_ref=None})
  in
  let runner : Keeper_owner.operation_runner =
    {ready=(fun ~keeper_name:_ -> true); execute;
     on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~execution:_ -> ())} in
  Registry.install_from_store ~sw ~operation_runner:(Some runner)
    ~on_turn_slot_released:None workspace |> require "install Owner" |> ignore;
  let owner = Registry.get ~base_path:root ~keeper_name |> require "Owner handle" in
  let input = Keeper_chat_operation_payload.input_to_json ~message:goal ~user_blocks:[]
      ~turn_instructions:None ~surface_context:None ~attachments:[]
    |> Keeper_chat_operation.canonical_json |> require "canonical input" in
  Registry.submit_operation ~base_path:root ~keeper_name ~operation_id
    ~source:(`Assoc ["kind", `String "fixture"]) ~input |> require "submit operation" |> ignore;
  Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
    (fun () -> Eio.Promise.await server.first_request_arrived);
  (match Registry.begin_stopping_all ~base_path:root with
   | Ok results -> List.iter (require "Owner stop") results
   | Error _ -> fail "the inventory did not stop");
  let operation = Keeper_owner.exact_operation owner operation_id
    |> require "read stopped operation" |> Option.get in
  let native_call_state = Keeper_owner.direct_native_call owner ~operation_id
    |> require "read stopped native call" in
  let late_bind =
    let locator = Agent.execution_locator_of_yojson
        (`Assoc ["version", `Int 1; "run_id", `String "execution-run-late-bind"])
      |> require "late locator" in
    let call = native_call ~call_id:late_call_id ~operation locator |> require "late call" in
    Registry.bind_direct_native_call ~base_path:root ~keeper_name ~operation_id
      ~execution_digest:operation.execution_digest ~observed:native_call_state ~call in
  {sink = !sink; operation; native_call = native_call_state; late_bind}

(* The next process installs the inventory again; its Owner settles whatever
   the stopped one left Running. No runner, so nothing claims a requeued row. *)
let after_restart ~root ~workspace =
  Eio.Switch.run @@ fun sw ->
  Registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None
    workspace |> require "reinstall Owner" |> ignore;
  Registry.exact_operation ~base_path:root ~keeper_name operation_id
  |> require "read restarted operation" |> Option.get

let run_case root =
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
  Unix.mkdir (Filename.concat root session_id) 0o700;
  let stopped = stop_while_dispatching env ~root ~workspace in
  let restarted = after_restart ~root ~workspace in
  stopped, restarted

let with_root f =
  let root = Filename.temp_dir "keeper-native-stop-receipt-" "" in
  Fun.protect ~finally:(fun () ->
    Eio_main.run (fun env -> Eio.Path.rmtree ~missing_ok:true Eio.Path.(env#fs / root)))
    (fun () -> f root)

let test_stop_records_the_cancelled_terminal () =
  with_root (fun root ->
    let stopped, restarted = run_case root in
    check bool "Core handed the stop's cancelled, retired terminal to the host" true
      (match stopped.sink with
       | Some {disposition; _} -> disposition = cancelled_retired
       | None -> false);
    check bool "the Owner recorded that terminal while it stopped" true
      (match stopped.sink with Some {recorded; _} -> recorded | None -> false);
    check bool "the stopped operation failed as cancelled instead of staying Running" true
      (failed_kind stopped.operation = Some Keeper_chat_operation.Turn_cancelled);
    check bool "its settlement acknowledged the retired call" true
      (Keeper_native_call.equal_state Keeper_native_call.No_native_call stopped.native_call);
    check bool "a new native call is still refused behind the stop fence" true
      (match stopped.late_bind with
       | Error (Registry.Command_lookup_failed Registry.Inventory_stopping) -> true
       | Ok () | Error (Registry.Command_lookup_failed
           ( Registry.Inventory_not_installed _ | Registry.Owner_not_found _
           | Registry.Owner_unavailable _ | Registry.Owner_initialization_failed _ ))
       | Error (Registry.Command_lifecycle_reserved _ | Registry.Command_rejected _) -> false);
    check bool "the next process finds it settled, not requeued for a dead journal" true
      (failed_kind restarted = Some Keeper_chat_operation.Turn_cancelled))

let () =
  run "native receipt during stop"
    ["owner stop", [
       test_case "a stop records the cancelled call's terminal" `Quick
         test_stop_records_the_cancelled_terminal]]
