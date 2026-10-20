(* Core commits the terminal disposition to its journal before it tells the
   host. When the host's receipt write fails, the journal holds the terminal
   while the Owner call stays Active. [reconcile_after_dispatch] copies the
   journal terminal into the Owner receipt when the dispatch ends, whether it
   returns or raises. These tests run a real Core execution whose host sink
   fails, then end the dispatch both ways. *)
open Alcotest
open Masc
module Native = Keeper_direct_native_continuation
module Registry = Keeper_owner_registry
module Agent = Agent_core.Agent

let keeper_name = "native-reconcile-proof"
let session_id = "native-reconcile-session"
let model_id = "native-reconcile-model"
let runtime_id = "native-reconcile.runtime"
let goal = "Answer once."
let call_id = "019a0010-1000-7000-8000-0000000000b1"
let require label = function Ok value -> value | Error _ -> fail (label ^ " failed")
let operation_id = Keeper_chat_operation.Operation_id.of_string "native-reconcile-operation"
  |> require "operation ID"

let final_reply =
  {|{"id":"reconcile-final","model":"native-reconcile-model","choices":[{"index":0,"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}

exception Dispatch_aborted

type dispatch_end =
  | Returns
  | Raises

(* What the Owner call held when the dispatch ended. *)
type observation =
  { call_before : Keeper_native_call.state
  ; call_after : Keeper_native_call.state
  ; raised_dispatch_aborted : bool
  }

let succeeded_retired =
  { Agent.outcome = Agent.Terminal_succeeded; recovery = Agent.Retire }

let is_active = function
  | Keeper_native_call.Active _ -> true
  | Keeper_native_call.No_native_call | Keeper_native_call.Terminal_unacknowledged _ -> false

let run_case ~how root =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  ignore (Server_startup_state.mark_state_ready ());
  Runtime_agent_execution_runtime.initialize ~sw ~domain_mgr:env#domain_mgr ~domain_count:1
    |> require "native execution runtime";
  let previous_catalog = Llm_provider.Model_catalog.global () in
  Eio.Switch.on_release sw (fun () -> match previous_catalog with
    | None -> Llm_provider.Model_catalog.clear_global ()
    | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
  let catalog = Printf.sprintf
      "[[models]]\nid_prefix = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n" model_id in
  Llm_provider.Model_catalog.of_toml_string ~source:"native-reconcile-test" catalog
    |> require "model catalog" |> Llm_provider.Model_catalog.set_global;
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Reply_with (fun _ _ -> `OK, final_reply)) in
  let provider_cfg = Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture"
      ~model_id ~base_url:server.base_url ~request_path:"/v1/chat/completions" () in
  let workspace = Workspace.default_config root in
  let session_dir = Filename.concat root session_id in
  ignore (Workspace.init workspace ~agent_name:(Some "native-reconcile-test"));
  let meta = Masc_test_deps.meta_of_json_fixture (`Assoc [
    "name", `String keeper_name; "trace_id", `String session_id;
    "activation_mode", `String "manual"]) |> require "meta" in
  Keeper_meta_store.replace_snapshot workspace meta |> require "persist meta";
  Unix.mkdir session_dir 0o700;
  let observed, resolve_observed = Eio.Promise.create () in
  let execute ~sw:turn_sw ~keeper_name:_ ~claim =
    let operation : Keeper_chat_operation.t =
      claim () |> require "claim operation" |> Option.get in
    let binding : Native.binding =
      {base_path=root; keeper_name; operation_id;
       execution_digest=operation.execution_digest; session_dir; session_id} in
    (* A real Core execution. Its host sink fails after the journal commits the
       terminal, which is the state left when the Owner receipt write fails. *)
    let runtime = Runtime_agent_execution_runtime.get () |> Option.get in
    let dir = Eio.Path.(env#fs / session_dir / "native-executions" / call_id) in
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
    let locator = ref None in
    let execution_store = Agent.execution_store ~runtime ~dir
        ~on_scope_ready:(fun published -> locator := Some published; Ok ())
        ~on_terminal_disposition:(fun _ -> Error "host receipt sink unavailable") () in
    let config = Runtime_agent.default_config ~name:keeper_name ~provider_cfg
        ~system_prompt:"Answer once." ~tools:[] in
    let config = {config with execution_store=Some execution_store} in
    (match Runtime_agent.run ~sw:turn_sw ~net:env#net ~config goal with
     | Error _ -> ()
     | Ok _ -> fail "the failing host sink did not fail the Core call");
    let checkpoint = Keeper_checkpoint_ref.create
        ~trace_id:(Keeper_id.Trace_id.of_string session_id |> require "trace id")
        ~turn_count:1 ~canonical_checkpoint_bytes:"reconcile seed"
      |> require "checkpoint" in
    let call = Keeper_native_call.create ~call_id ~runtime_id
        ~operation_digest:operation.execution_digest
        ~api:(Keeper_native_call.New_input {seed_message_count=0})
        ~seed_checkpoint:checkpoint ~locator:(Option.get !locator)
      |> require "native call" in
    check int "a first bind releases no checkpoint" 0
      (List.length (Registry.bind_direct_native_call ~base_path:root ~keeper_name ~operation_id
        ~execution_digest:operation.execution_digest
        ~observed:Keeper_native_call.No_native_call ~call |> require "bind native call"));
    let read () = Registry.direct_native_call ~base_path:root ~keeper_name ~operation_id
      |> require "read native call" in
    let call_before = read () in
    let raised_dispatch_aborted =
      match how with
      | Returns ->
        Native.reconcile_after_dispatch binding (fun () -> ()); false
      | Raises ->
        (match Native.reconcile_after_dispatch binding (fun () -> raise Dispatch_aborted) with
         | () -> false
         | exception Dispatch_aborted -> true) in
    Eio.Promise.resolve resolve_observed
      {call_before; call_after=read (); raised_dispatch_aborted};
    Keeper_owner.Operation_failed
      {kind=Keeper_chat_operation.Turn_cancelled; detail="fixture finished"; outcome_ref=None}
  in
  let runner : Keeper_owner.operation_runner =
    {ready=(fun ~keeper_name:_ -> true); execute;
     on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~execution:_ -> ())} in
  Registry.install_from_store ~sw ~operation_runner:(Some runner)
    ~on_turn_slot_released:None workspace |> require "install Owner" |> ignore;
  let input = Keeper_chat_operation_payload.input_to_json ~message:goal ~user_blocks:[]
      ~turn_instructions:None ~surface_context:None ~attachments:[]
    |> Keeper_chat_operation.canonical_json |> require "canonical input" in
  Registry.submit_operation ~base_path:root ~keeper_name ~operation_id
    ~source:(`Assoc ["kind", `String "fixture"]) ~input |> require "submit operation" |> ignore;
  Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
    (fun () -> Eio.Promise.await observed)

let with_root f =
  let root = Filename.temp_dir "keeper-native-reconcile-" "" in
  Fun.protect ~finally:(fun () ->
    Eio_main.run (fun env -> Eio.Path.rmtree ~missing_ok:true Eio.Path.(env#fs / root)))
    (fun () -> f root)

let check_reconciled observation =
  check bool "the Owner call was Active before reconciliation" true
    (is_active observation.call_before);
  check bool "the journal terminal reached the Owner receipt" true
    (match observation.call_after with
     | Keeper_native_call.Terminal_unacknowledged (_, disposition) ->
       disposition = succeeded_retired
     | Keeper_native_call.No_native_call | Keeper_native_call.Active _ -> false)

let test_returned_dispatch () =
  with_root (fun root ->
    let observation = run_case ~how:Returns root in
    check_reconciled observation;
    check bool "a normal return raises nothing" false observation.raised_dispatch_aborted)

let test_raising_dispatch () =
  with_root (fun root ->
    let observation = run_case ~how:Raises root in
    check_reconciled observation;
    check bool "the original exception continues" true observation.raised_dispatch_aborted)

let () =
  run "native reconcile after dispatch"
    ["journal terminal", [
       test_case "returned dispatch copies the terminal" `Quick test_returned_dispatch;
       test_case "raising dispatch copies the terminal and re-raises" `Quick test_raising_dispatch]]
