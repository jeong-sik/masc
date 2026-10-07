(* Stop with a real Active native receipt, then resume through Owner and the
   adapter. Tools/hooks capture the shared context before Native.prepare, as
   Keeper_run_tools_setup does. Their new state must reach Core's checkpoints. *)
open Alcotest
open Masc
module Native = Keeper_direct_native_continuation
module Owner = Keeper_owner
module Registry = Keeper_owner_registry

let keeper_name = "native-context-proof"
let session_id = "native-context-session"
let model_id = "native-context-model"
let runtime_id = "native-context.runtime"
let goal = "Update the shared context."
let crash_exit = 87
let require label = function Ok value -> value | Error _ -> fail (label ^ " failed")
let operation_id = Keeper_chat_operation.Operation_id.of_string "native-context-operation"
  |> require "operation ID"

let tool_reply =
  {|{"id":"context-tool","model":"native-context-model","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"context-call","type":"function","function":{"name":"update_context","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
let final_reply =
  {|{"id":"context-final","model":"native-context-model","choices":[{"index":0,"message":{"role":"assistant","content":"context saved"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}

let run_phase ~child root =
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
  Llm_provider.Model_catalog.of_toml_string ~source:"native-context-test" catalog
    |> require "model catalog" |> Llm_provider.Model_catalog.set_global;
  let provider_calls = ref 0 and tool_calls = ref 0 and hook_calls = ref 0 in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Reply_with (fun _ _ ->
        incr provider_calls;
        `OK, if child then tool_reply else final_reply)) in
  let provider_cfg = Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture"
      ~model_id ~base_url:server.base_url ~request_path:"/v1/chat/completions" () in
  let workspace = Workspace.default_config root in
  let session_dir = Filename.concat root session_id in
  if child then (
    ignore (Workspace.init workspace ~agent_name:(Some "native-context-test"));
    let meta = Masc_test_deps.meta_of_json_fixture (`Assoc [
      "name", `String keeper_name; "trace_id", `String session_id;
      "activation_mode", `String "manual"]) |> require "meta" in
    Keeper_meta_store.replace_snapshot workspace meta |> require "persist meta";
    Unix.mkdir session_dir 0o700);
  let settled, resolve_settled = Eio.Promise.create () in
  let execute ~sw:turn_sw ~keeper_name:_ ~claim =
    let operation : Keeper_chat_operation.t =
      claim () |> require "claim original operation" |> Option.get in
    check bool "original operation resumes" true
      (Keeper_chat_operation.Operation_id.equal operation_id operation.operation_id);
    let binding : Native.binding =
      {base_path=root; keeper_name; operation_id;
       execution_digest=operation.execution_digest; session_dir; session_id} in
    let admission = Native.load ~binding |> require "load native admission" in
    let context, checkpoint, input = match child, admission with
      | true, Native.No_pending ->
        let context = Agent_core.Context.create () in
        let scope = Keeper_execution_scope_id.direct_operation operation_id in
        let frame = Keeper_repetition_snapshot.admit Keeper_repetition_snapshot.empty
            (Keeper_repetition_snapshot.Fresh scope) |> require "direct scope" in
        Keeper_repetition_scope.save context frame;
        Agent_core.Context.set context "before-restart" (`String "retained");
        context, None, Native.New_input {blocks=[Agent_core.Types.Text goal]; metadata=[]}
      | false, Native.Resume resumed ->
        (* The production restore point precedes all closures below. *)
        Native.restored_context resumed, Some (Native.checkpoint resumed), Native.input resumed
      | true, (Native.Resume _ | Native.Terminal_pending _)
      | false, (Native.No_pending | Native.Terminal_pending _) ->
        fail "expected a fresh child scope and an Active parent continuation" in
    check bool "checkpoint entries restored before tool setup" true
      (Agent_core.Context.get context "before-restart" = Some (`String "retained"));
    Agent_core.Context.set context "setup-receipt"
      (`String (if child then "child-setup" else "restored-before-hooks"));
    let tool = Agent_core.Tool.create ~name:"update_context"
        ~description:"Update captured shared state" ~parameters:[] (fun _ ->
          if child then fail "child reached the tool before its crash boundary";
          incr tool_calls;
          Agent_core.Context.set context "tool-receipt" (`String "resumed-tool");
          Ok {Agent_core.Types.content="context updated"; content_blocks=None; _meta=None}) in
    let hooks = {Agent_core.Hooks.empty with post_tool_use=Some (fun _ ->
      incr hook_calls;
      Agent_core.Context.set context "hook-receipt" (`String "resumed-hook");
      Agent_core.Hooks.Continue)} in
    let context_injector ~tool_name:_ ~input:_ ~output:_ =
      check bool "injector sees the resumed tool mutation" true
        (Agent_core.Context.get context "tool-receipt" = Some (`String "resumed-tool"));
      Some {Agent_core.Hooks.context_updates=["injected-receipt", `String "resumed-injector"];
            extra_messages=[]} in
    let checkpoint_sink (snapshot : Agent_core.Agent.checkpoint_snapshot) =
      if child && snapshot.stage = Agent_core.Agent.After_assistant_collected
      then Unix._exit crash_exit else Ok () in
    let config = Runtime_agent.default_config ~name:keeper_name ~provider_cfg
        ~system_prompt:"Persist the shared context." ~tools:[tool] in
    let config = {config with context=Some context; hooks=Some hooks;
      context_injector=Some context_injector; checkpoint_sink=Some checkpoint_sink} in
    let agent_ref = ref None in
    let prepared = Native.prepare ~binding ~runtime_id ~config
        ~agent_core_checkpoint:checkpoint ~input ~agent_ref () |> require "prepare native call" in
    let config = Native.config prepared in
    let checkpoint = Native.prepared_checkpoint prepared in
    let result = match Native.prepared_input prepared with
      | Native.New_input {blocks; metadata} ->
        Runtime_agent.run_blocks ~sw:turn_sw ~net:env#net ~config ~agent_ref
          ?agent_core_checkpoint:checkpoint ~input_metadata:metadata blocks
      | Native.Continue_from_checkpoint ->
        Runtime_agent.continue_from_checkpoint ~sw:turn_sw ~net:env#net ~config ~agent_ref
          ~checkpoint:(Option.get checkpoint) () in
    let result = match result with
      | Ok result -> result
      | Error error -> fail (Agent_core.Error.to_string error) in
    check string "resumed provider completes" "context saved"
      (Agent_core.Types.text_of_content result.response.content);
    let call = match Registry.direct_native_call ~base_path:root ~keeper_name ~operation_id
        |> require "read terminal native call" with
      | Keeper_native_call.Terminal_unacknowledged (call,
          {Agent_core.Agent.outcome=Terminal_succeeded; recovery=Retire}) -> call
      | Keeper_native_call.No_native_call | Keeper_native_call.Active _
      | Keeper_native_call.Terminal_unacknowledged (_,
          {Agent_core.Agent.outcome=(Terminal_failed | Terminal_cancelled); _})
      | Keeper_native_call.Terminal_unacknowledged (_,
          {Agent_core.Agent.outcome=Terminal_succeeded;
           recovery=Operator_repair_required Effect_outcome_unknown}) ->
        fail "native call did not durably finish" in
    let retained = Keeper_checkpoint_store.load_retained_exact_snapshot
        ~session_dir ~reference:call.checkpoint |> require "retained final checkpoint"
      |> Keeper_checkpoint_store.exact_snapshot_checkpoint in
    List.iter (fun (key, value) ->
      check bool (key ^ " persists in the retained native checkpoint") true
        (Agent_core.Context.get retained.context key = Some (`String value)))
      ["before-restart", "retained"; "setup-receipt", "restored-before-hooks";
       "tool-receipt", "resumed-tool"; "hook-receipt", "resumed-hook";
       "injected-receipt", "resumed-injector"];
    check bool "Core injector updates reach the tool-owned shared object" true
      (Agent_core.Context.get context "injected-receipt" = Some (`String "resumed-injector"));
    Owner.Operation_succeeded {outcome_ref="shared-context-checkpointed"}
  in
  let runner : Owner.operation_runner =
    {ready=(fun ~keeper_name:_ -> true); execute;
     on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~execution ->
       Eio.Promise.resolve resolve_settled execution)} in
  Registry.install_from_store ~sw ~operation_runner:(Some runner)
    ~on_turn_slot_released:None workspace |> require "install Owner" |> ignore;
  if child then (
    let input = Keeper_chat_operation_payload.input_to_json ~message:goal ~user_blocks:[]
        ~turn_instructions:None ~surface_context:None ~attachments:[]
      |> Keeper_chat_operation.canonical_json |> require "canonical input" in
    Registry.submit_operation ~base_path:root ~keeper_name ~operation_id
      ~source:(`Assoc ["kind", `String "fixture"]) ~input |> require "submit operation" |> ignore);
  (match Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
      (fun () -> Eio.Promise.await settled) with
   | Owner.Operation_succeeded _ when not child -> ()
   | Owner.Operation_failed {detail; _} -> fail detail
   | Owner.Operation_succeeded _ | Owner.Operation_deferred ->
     fail "native context continuation did not complete");
  check int "the resumed tool executes once" 1 !tool_calls;
  check int "the resumed observer executes once" 1 !hook_calls;
  check int "only the final provider request follows replay" 1 !provider_calls;
  check bool "Owner acknowledges the completed native call" true
    (Registry.direct_native_call ~base_path:root ~keeper_name ~operation_id
     |> require "read Owner acceptance"
     |> Keeper_native_call.equal_state Keeper_native_call.No_native_call)

let test_active_context_restart () =
  let root = Filename.temp_dir "keeper-native-context-" "" in
  Fun.protect ~finally:(fun () ->
    Eio_main.run (fun env -> Eio.Path.rmtree ~missing_ok:true Eio.Path.(env#fs / root)))
    (fun () ->
      Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
        let process = Eio.Process.spawn ~sw env#process_mgr
            [Sys.executable_name; "--native-context-child"; root] in
        match Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
            (fun () -> Eio.Process.await process) with
        | `Exited code -> check int "interrupted with Active receipt before tool execution" crash_exit code
        | `Signaled signal -> failf "child died from signal %d" signal));
      run_phase ~child:false root)

let () = match Array.to_list Sys.argv with
  | [_; "--native-context-child"; root] -> run_phase ~child:true root
  | _ -> run "native shared context restart"
      ["context ownership", [test_case "resumed tool and hook changes reach durable checkpoint"
        `Quick test_active_context_restart]]
