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

let run_phase ?(operation_branch=false) ~child root =
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
  let provider_calls = ref 0 and tool_calls = ref 0 and hook_calls = ref 0 and injector_calls = ref 0 in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Reply_with (fun _ _ ->
        incr provider_calls;
        `OK, if child then tool_reply else final_reply)) in
  let provider_cfg = Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture"
      ~model_id ~base_url:server.base_url ~request_path:"/v1/chat/completions" () in
  let workspace = Workspace.default_config root in
  let session_dir = if operation_branch then Keeper_fs.keeper_session_dir workspace session_id
    else Filename.concat root session_id in
  if child then (
    ignore (Workspace.init workspace ~agent_name:(Some "native-context-test"));
    let meta = Masc_test_deps.meta_of_json_fixture (`Assoc [
      "name", `String keeper_name; "trace_id", `String session_id;
      "activation_mode", `String "manual"]) |> require "meta" in
    Keeper_meta_store.replace_snapshot workspace meta |> require "persist meta";
    Fs_compat.mkdir_p session_dir);
  if child && operation_branch then (
    let input=Keeper_chat_operation_payload.input_to_json ~message:goal ~user_blocks:[]
      ~turn_instructions:None ~surface_context:None ~attachments:[]
      |> Keeper_chat_operation.canonical_json |> require "initial operation input" in
    Keeper_original_input_branch_fixture.prepare ~net:env#net ~clock:env#clock ~workspace ~session_dir
      {keeper_name;session_id;runtime_id;operation_id;provider_cfg;input;message=goal;
       source=`Assoc ["kind",`String "branch-crash-fixture"];input_metadata=[];
       system_prompt="Persist the shared context."};
    check int "original Core input pause needed no provider request" 0 !provider_calls);
  let expected_g=if operation_branch then Some (Keeper_original_input_branch_fixture.expected_global_checkpoint_bytes ~workspace) else None in
  let check_g ()=match expected_g with
    | None -> ()
    | Some bytes ->
      check string "actual original crash/replay preserves canonical G" bytes
        (Fs_compat.load_file (Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id));
      let trace_id=Keeper_id.Trace_id.of_string session_id |> require "G trace" in
      let expected=Keeper_checkpoint_store.exact_snapshot_of_canonical_bytes ~expected_session_id:trace_id bytes
        |> require "frozen G identity" |> Keeper_checkpoint_store.exact_snapshot_reference in
      check bool "actual original crash/replay preserves global input G reference" true
        (Registry.input_checkpoint ~base_path:root ~keeper_name ~trace_id |> require "global G observation"
          =Keeper_chat_operation_store.Input_observed expected) in
  let settled, resolve_settled = Eio.Promise.create () in
  let execute ~sw:turn_sw ~keeper_name:_ ~claim =
    let operation : Keeper_chat_operation.t =
      claim () |> require "claim original operation" |> Option.get in
    check bool "original operation resumes" true
      (Keeper_chat_operation.Operation_id.equal operation_id operation.operation_id);
    check_g ();
    if child && operation_branch then (
      let admission=Keeper_direct_checkpoint_continuation.load ~base_path:root ~keeper_name ~operation_id
        ~session_dir ~session_id |> require "load exact consumed cooperative branch" |> Option.get in
      Keeper_direct_checkpoint_continuation.consume ~base_path:root ~keeper_name ~operation_id admission
        |> require "resume consumed cooperative branch");
    let trace_id=Keeper_id.Trace_id.of_string session_id |> require "dispatch trace" in
    let destination=if operation_branch then
      Keeper_checkpoint_destination.capture_direct ~base_path:root ~keeper_name ~session_dir ~trace_id ~operation_id
      |> require "capture original branch after actual restart"
      else Keeper_checkpoint_destination.canonical ~keeper_name ~session_dir in
    let binding : Native.binding =
      {base_path=root; keeper_name; operation_id;
       execution_digest=operation.execution_digest; session_dir; session_id;checkpoint_destination=destination} in
    let admission = Native.load ~binding |> require "load native admission" in
    let context, checkpoint, input = match child, admission with
      | true, Native.No_pending when operation_branch ->
        let checkpoint=Keeper_checkpoint_destination.current_checkpoint destination
          |> require "original consumed C" |> Option.get in
        check bool "branch seed consumed its original pending request" true (checkpoint.pending_input=None);
        Agent_core.Context.copy checkpoint.context ~eio:true,Some checkpoint,Native.Continue_from_checkpoint
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
      incr injector_calls;
      check bool "injector sees the resumed tool mutation" true
        (Agent_core.Context.get context "tool-receipt" = Some (`String "resumed-tool"));
      Some {Agent_core.Hooks.context_updates=["injected-receipt", `String "resumed-injector"];
            extra_messages=[]} in
    let checkpoint_sink (snapshot : Agent_core.Agent.checkpoint_snapshot) =
      check_g ();
      if child && snapshot.stage = Agent_core.Agent.After_assistant_collected then (
        check int "original branch tool has not executed at process crash" 0 !tool_calls;
        Unix._exit crash_exit)
      else if operation_branch then
        Keeper_checkpoint_destination.save destination snapshot.checkpoint |> Result.map (fun _ -> ())
      else Ok () in
    let config = Runtime_agent.default_config ~name:keeper_name ~provider_cfg
        ~system_prompt:"Persist the shared context." ~tools:[tool] in
    let config = {config with context=Some context; hooks=Some hooks;
      context_injector=Some context_injector; checkpoint_sink=Some checkpoint_sink;
      session_id=(if operation_branch then Some session_id else config.session_id)} in
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
    if operation_branch then (
      let branch=Registry.direct_input_branch ~base_path:root ~keeper_name ~operation_id
        |> require "resumed original branch" |> Option.get in
      check bool "resumed native receipt and original branch name the same final payload" true
        (Keeper_checkpoint_ref.equal branch.checkpoint call.checkpoint);
      check bool "resumed branch contains no independent G context" true
        (Agent_core.Context.get retained.context "independent-G"=None);
      List.iter (fun body ->
        let messages=Yojson.Safe.from_string body |> Yojson.Safe.Util.member "messages" |> Yojson.Safe.Util.to_list in
        check bool "provider after actual restart sees original explicit decline" true
          (List.exists (fun row -> Yojson.Safe.Util.member "role" row=`String "user"
            && Yojson.Safe.Util.member "content" row=`String "[Input declined] Original branch question?") messages);
        check bool "provider never borrows independent G history" false
          (List.exists (fun row -> Yojson.Safe.Util.member "content" row=`String "Independent G history") messages))
        (Exact_output_fixture.request_bodies server);
      check_g ());
    Owner.Operation_succeeded {outcome_ref="shared-context-checkpointed"}
  in
  let runner : Owner.operation_runner =
    {ready=(fun ~keeper_name:_ -> true); execute;
     on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~execution ->
       Eio.Promise.resolve resolve_settled execution)} in
  Registry.install_from_store ~sw ~operation_runner:(Some runner)
    ~on_turn_slot_released:None workspace |> require "install Owner" |> ignore;
  if child && not operation_branch then (
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
  check int "the resumed context injector executes once" 1 !injector_calls;
  check int "only the final provider request follows replay" 1 !provider_calls;
  check bool "Owner acknowledges the completed native call" true
    (Registry.direct_native_call ~base_path:root ~keeper_name ~operation_id
     |> require "read Owner acceptance"
     |> Keeper_native_call.equal_state Keeper_native_call.No_native_call);
  check_g ();
  if operation_branch then check bool "original branch retires only after Owner accepts completion" true
    (Registry.direct_input_branch ~base_path:root ~keeper_name ~operation_id
      |> require "settled original branch"=None)

let test_active_context_restart ?(operation_branch=false) () =
  let root = Filename.temp_dir "keeper-native-context-" "" in
  Fun.protect ~finally:(fun () ->
    Eio_main.run (fun env -> Eio.Path.rmtree ~missing_ok:true Eio.Path.(env#fs / root)))
    (fun () ->
      Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
        let process = Eio.Process.spawn ~sw env#process_mgr
            [Sys.executable_name;
             (if operation_branch then "--native-branch-context-child" else "--native-context-child");root] in
        match Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
            (fun () -> Eio.Process.await process) with
        | `Exited code -> check int "interrupted with Active receipt before tool execution" crash_exit code
        | `Signaled signal -> failf "child died from signal %d" signal));
      run_phase ~operation_branch ~child:false root)

let test_native_input_checkpoint_order ?(fail_before_canonical=false) ~uncertain_consume () =
  let root = Filename.temp_dir "keeper-native-input-" "" in
  Fun.protect ~finally:(fun () ->
    Eio_main.run (fun env -> Eio.Path.rmtree ~missing_ok:true Eio.Path.(env#fs / root)))
  @@ fun () ->
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
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
  Llm_provider.Model_catalog.of_toml_string ~source:"native-input-test" catalog
  |> require "model catalog" |> Llm_provider.Model_catalog.set_global;
  let workspace = Workspace.default_config root in
  ignore (Workspace.init workspace ~agent_name:(Some "native-input-test"));
  let meta = Masc_test_deps.meta_of_json_fixture (`Assoc [
    "name", `String keeper_name; "trace_id", `String session_id;
    "activation_mode", `String "manual"]) |> require "meta" in
  Keeper_meta_store.replace_snapshot workspace meta |> require "persist meta";
  let session_dir = Filename.concat root session_id in
  Unix.mkdir session_dir 0o700;
  let settled, resolve_settled = Eio.Promise.create () in
  let provider_calls = ref 0 in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Reply_with (fun _ _ -> incr provider_calls; `OK, final_reply)) in
  let provider_cfg = Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture"
      ~model_id ~base_url:server.base_url ~request_path:"/v1/chat/completions" () in
  let execute ~sw:turn_sw ~keeper_name:_ ~claim =
    let operation : Keeper_chat_operation.t = claim () |> require "claim operation" |> Option.get in
    let binding : Native.binding = {base_path=root;keeper_name;operation_id;
      execution_digest=operation.execution_digest;session_dir;session_id; checkpoint_destination=Keeper_checkpoint_destination.canonical ~keeper_name ~session_dir} in
    let context = Agent_core.Context.create () in
    let scope = Keeper_execution_scope_id.direct_operation operation_id in
    let frame = Keeper_repetition_snapshot.admit Keeper_repetition_snapshot.empty
        (Keeper_repetition_snapshot.Fresh scope) |> require "direct scope" in
    Keeper_repetition_scope.save context frame;
    let resume = ref false in
    let request : Agent_core.Hooks.elicitation_request =
      {question="Which environment?";schema=None;timeout_s=None} in
    let hooks = {Agent_core.Hooks.empty with before_turn=Some (fun _ ->
      if !resume then Agent_core.Hooks.Continue else Agent_core.Hooks.ElicitInput request)} in
    let sink (snapshot : Agent_core.Agent.checkpoint_snapshot) =
      if !resume && fail_before_canonical then Error "canonical write refused before installation" else
      let saved = Keeper_checkpoint_store.save_agent_core_classified
          ~history_retained:0 ~session_dir snapshot.checkpoint in
      match saved with
      | Error detail -> Error detail
      | Ok (Keeper_checkpoint_store.Stale_noop _) -> Error "fixture source changed"
      | Ok (Keeper_checkpoint_store.Saved _) ->
        if !resume then Error "canonical write committed; acknowledgement uncertain" else Ok () in
    let config = Runtime_agent.default_config ~name:keeper_name ~provider_cfg
        ~system_prompt:"Ask before proceeding." ~tools:[] in
    let config = {config with context=Some context;hooks=Some hooks;checkpoint_sink=Some sink;
      session_id=Some session_id} in
    let dispatch checkpoint blocks =
      let agent_ref = ref None in
      let prepared = Native.prepare ~binding ~runtime_id ~config
          ~agent_core_checkpoint:checkpoint ~input:(Native.New_input {blocks;metadata=[]})
          ~agent_ref () |> (function Ok prepared -> prepared
            | Error detail -> failf "prepare owned input call failed: %s" detail) in
      Runtime_agent.run_blocks ~sw:turn_sw ~net:env#net ~config:(Native.config prepared)
        ~agent_ref ?agent_core_checkpoint:(Native.prepared_checkpoint prepared) blocks in
    let first = dispatch None [Agent_core.Types.Text goal] |> require "first input pause" in
    let checkpoint = Option.get first.checkpoint in
    let pending = Option.get checkpoint.pending_input in
    check bool "first BeforeTurn pause preserves its typed request" true
      (match first.stop_reason with
       | Runtime_agent.InputRequired {request;_} -> request.request_id = pending.request.request_id
       | Completed | Yielded_to_operation_queued _ | Yielded_to_durable_stimulus _
       | Yielded_after_repeated_tool_call _ | Yielded_after_repeated_assistant_text _ -> false);
    let retained_pending () =
      let call = match Registry.direct_native_call ~base_path:root ~keeper_name ~operation_id
          |> require "read native terminal" with
        | Keeper_native_call.Terminal_unacknowledged (call, _) -> call
        | No_native_call | Active _ -> fail "native input call omitted its terminal receipt" in
      Keeper_checkpoint_store.load_retained_exact_snapshot ~session_dir ~reference:call.checkpoint
      |> require "read retained input checkpoint" |> Keeper_checkpoint_store.exact_snapshot_checkpoint in
    check bool "terminal retains newly installed input rather than its seed" true
      ((retained_pending ()).pending_input = Some pending);
    if uncertain_consume then (
      resume := true;
      check bool "uncertain consumed write is a failure" true
        (Result.is_error (dispatch (Some checkpoint) [Agent_core.Types.Text "continue"]));
      check bool "terminal cannot resurrect the old pending request" true
        ((retained_pending ()).pending_input = None));
    let input_owner = Registry.input_checkpoint ~base_path:root ~keeper_name ~trace_id:meta.runtime.trace_id
        |> require "read durable input owner" |> (function
          | Keeper_chat_operation_store.Input_observed reference -> reference
          | Input_unobserved | Prior_input_unavailable -> fail "input owner was not observed") in
    let input_snapshot = Keeper_checkpoint_store.load_retained_exact_snapshot ~session_dir ~reference:input_owner
        |> (function Ok snapshot -> snapshot | Error _ -> fail "input owner artifact unavailable") in
    let owned_input = Keeper_checkpoint_store.exact_snapshot_checkpoint input_snapshot in
    check bool "durable input owner agrees with native receipt" true
      (owned_input.pending_input = (retained_pending ()).pending_input);
    if uncertain_consume then (
      let stale = Native.prepare ~binding ~runtime_id ~config
          ~agent_core_checkpoint:(Some checkpoint)
          ~input:(Native.New_input {blocks=[Agent_core.Types.Text "stale retry"];metadata=[]})
          ~agent_ref:(ref None) () in
      check bool "stale original wait cannot dispatch after consumed owner" true (Result.is_error stale));
    let canonical = Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id
        |> require "read canonical input checkpoint" in
    if fail_before_canonical then
      check bool "canonical remains stale while durable input owner records consumption" true
        (canonical.pending_input <> owned_input.pending_input)
    else check bool "canonical and retained input observations agree" true
      (canonical.pending_input = owned_input.pending_input);
    check int "no provider dispatch is needed for either input boundary" 0 !provider_calls;
    Owner.Operation_succeeded {outcome_ref="input-checkpoint-observed"} in
  let runner : Owner.operation_runner =
    {ready=(fun ~keeper_name:_ -> true);execute;
     on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~execution ->
       Eio.Promise.resolve resolve_settled execution)} in
  Registry.install_from_store ~sw ~operation_runner:(Some runner)
    ~on_turn_slot_released:None workspace |> require "install Owner" |> ignore;
  let input = Keeper_chat_operation_payload.input_to_json ~message:goal ~user_blocks:[]
      ~turn_instructions:None ~surface_context:None ~attachments:[]
    |> Keeper_chat_operation.canonical_json |> require "canonical input" in
  Registry.submit_operation ~base_path:root ~keeper_name ~operation_id
    ~source:(`Assoc ["kind", `String "fixture"]) ~input |> require "submit operation" |> ignore;
  match Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
      (fun () -> Eio.Promise.await settled) with
  | Owner.Operation_succeeded _ -> ()
  | Owner.Operation_failed {detail;_} -> fail detail
  | Owner.Operation_deferred -> fail "input checkpoint observation deferred"

let test_retired_input_history_cut () =
  let root=Filename.temp_dir "keeper-native-cut-" "" in
  Fun.protect ~finally:(fun () -> Eio_main.run (fun env ->
    Eio.Path.rmtree ~missing_ok:true Eio.Path.(env#fs / root))) @@ fun () ->
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  ignore (Server_startup_state.mark_state_ready ());
  Runtime_agent_execution_runtime.initialize ~sw ~domain_mgr:env#domain_mgr ~domain_count:1
    |> require "native runtime";
  let previous_catalog=Llm_provider.Model_catalog.global () in
  Eio.Switch.on_release sw (fun () -> match previous_catalog with
    | None -> Llm_provider.Model_catalog.clear_global ()
    | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
  let catalog=Printf.sprintf
      "[[models]]\nid_prefix = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n" model_id in
  Llm_provider.Model_catalog.of_toml_string ~source:"native-cut-test" catalog
    |> require "model catalog" |> Llm_provider.Model_catalog.set_global;
  let workspace=Workspace.default_config root in
  ignore (Workspace.init workspace ~agent_name:(Some "native-cut-test"));
  let meta=Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String keeper_name;
      "trace_id",`String session_id;"activation_mode",`String "manual"]) |> require "meta" in
  Keeper_meta_store.replace_snapshot workspace meta |> require "persist meta";
  let session_dir=Filename.concat (Keeper_fs.session_store_path workspace) session_id in
  Fs_compat.mkdir_p session_dir;
  let provider_calls=ref 0 in
  let server=Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Reply_with (fun _ _ -> incr provider_calls; `OK,final_reply)) in
  let provider_cfg=Llm_provider.Provider_config.make ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~provider_id:"fixture" ~model_id ~base_url:server.base_url ~request_path:"/v1/chat/completions" () in
  let settled,resolve_settled=Eio.Promise.create () in
  let execute ~sw:turn_sw ~keeper_name:_ ~claim =
    let operation:Keeper_chat_operation.t=claim () |> require "claim" |> Option.get in
    let binding:Native.binding={base_path=root;keeper_name;operation_id;session_id;session_dir;
                               execution_digest=operation.execution_digest; checkpoint_destination=Keeper_checkpoint_destination.canonical ~keeper_name ~session_dir} in
    let context=Agent_core.Context.create () in
    let frame=Keeper_repetition_snapshot.admit Keeper_repetition_snapshot.empty
        (Keeper_repetition_snapshot.Fresh (Keeper_execution_scope_id.direct_operation operation_id))
      |> require "scope" in
    Keeper_repetition_scope.save context frame;
    let publish_input=ref true in
    let sink (snapshot:Agent_core.Agent.checkpoint_snapshot)=
      if !publish_input && snapshot.stage=Agent_core.Agent.After_assistant_collected then (
        let checkpoint={snapshot.checkpoint with Agent_core.Checkpoint.session_id=session_id} in
        let call=match Registry.direct_native_call ~base_path:root ~keeper_name ~operation_id
            |> require "active native call" with
          | Keeper_native_call.Active call -> call
          | No_native_call | Terminal_unacknowledged _ -> fail "publication requires Active call" in
        let producer=Keeper_input_checkpoint_producer.prepare ~base_path:root ~keeper_name
            ~session_dir ~trace_id:meta.runtime.trace_id ~source:(Some checkpoint)
          |> require "input producer" in
        Keeper_input_checkpoint_producer.publish_direct producer ~operation_id
          ~execution_digest:operation.execution_digest ~call_id:call.call_id ~observed:call.checkpoint checkpoint
          |> require "publish observed input history" |> ignore);
      Ok () in
    let config=Runtime_agent.default_config ~name:keeper_name ~provider_cfg
        ~system_prompt:"Complete the response." ~tools:[] in
    let config={config with context=Some context;session_id=Some session_id;checkpoint_sink=Some sink} in
    let agent_ref=ref None in
    let prepared=Native.prepare ~binding ~runtime_id ~config ~agent_core_checkpoint:None
        ~input:(Native.New_input {blocks=[Agent_core.Types.Text goal];metadata=[]}) ~agent_ref ()
      |> require "first native preparation" in
    Runtime_agent.run_blocks ~sw:turn_sw ~net:env#net ~config:(Native.config prepared)
      ~agent_ref [Agent_core.Types.Text goal] |> require "first provider dispatch" |> ignore;
    publish_input:=false;
    let previous=match Registry.direct_native_call ~base_path:root ~keeper_name ~operation_id
        |> require "retired native state" with
      | Keeper_native_call.Terminal_unacknowledged (call,{Agent_core.Agent.recovery=Retire;_}) -> call
      | No_native_call | Active _
      | Terminal_unacknowledged (_, {Agent_core.Agent.recovery=Operator_repair_required Effect_outcome_unknown;_}) ->
        fail "first call did not retire" in
    let source=Keeper_checkpoint_store.load_retained_exact_snapshot ~session_dir ~reference:previous.checkpoint
      |> require "retired source" in
    let original=Keeper_checkpoint_store.exact_snapshot_checkpoint source in
    let cut={original with messages=List.take (List.length original.messages-1) original.messages} in
    let config={config with context=Some cut.context} in
    let prepare ?retired_history_cut candidate=Native.prepare ~binding ~runtime_id ~config
        ~agent_core_checkpoint:(Some candidate) ~input:Native.Continue_from_checkpoint
        ~agent_ref:(ref None) ?retired_history_cut () in
    check bool "ordinary input owner refuses unproven history cut" true (Result.is_error (prepare cut));
    check bool "cut cannot replace earlier messages" true
      (Result.is_error (Native.authorize_incomplete_response_cut ~binding
         ~checkpoint:{cut with messages=[]} ()));
    let proof=Native.authorize_incomplete_response_cut ~binding ~checkpoint:cut ()
      |> require "authorize exact response cut" in
    check bool "authorized proof cannot be reused for edited candidate" true
      (Result.is_error (prepare ~retired_history_cut:proof {cut with model="changed-model"}));
    let expected=Keeper_checkpoint_store.exact_snapshot_of_value ~expected_session_id:meta.runtime.trace_id cut
      |> require "cut reference" |> Keeper_checkpoint_store.exact_snapshot_reference in
    let agent_ref=ref None in
    let prepared=Native.prepare ~binding ~runtime_id ~config ~agent_core_checkpoint:(Some cut)
        ~input:Native.Continue_from_checkpoint ~agent_ref ~retired_history_cut:proof ()
      |> require "verified cut preparation" in
    Runtime_agent.continue_from_checkpoint ~sw:turn_sw ~net:env#net ~config:(Native.config prepared)
      ~agent_ref ~checkpoint:(Option.get (Native.prepared_checkpoint prepared)) ()
      |> require "dispatch after exact cut" |> ignore;
    let owned=Registry.input_checkpoint ~base_path:root ~keeper_name ~trace_id:meta.runtime.trace_id
      |> require "cut input owner" in
    check bool "durable input owner advances to the exact cut" true
      (match owned with Keeper_chat_operation_store.Input_observed reference ->
         Keeper_checkpoint_ref.equal reference expected
       | Input_unobserved | Prior_input_unavailable -> false);
    check int "only the two intended provider calls execute" 2 !provider_calls;
    Owner.Operation_succeeded {outcome_ref="retired-input-cut-verified"} in
  let runner:Owner.operation_runner={ready=(fun ~keeper_name:_ -> true);execute;
    on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~execution ->
      Eio.Promise.resolve resolve_settled execution)} in
  Registry.install_from_store ~sw ~operation_runner:(Some runner) ~on_turn_slot_released:None workspace
    |> require "install Owner" |> ignore;
  let input=Keeper_chat_operation_payload.input_to_json ~message:goal ~user_blocks:[]
      ~turn_instructions:None ~surface_context:None ~attachments:[]
    |> Keeper_chat_operation.canonical_json |> require "input" in
  Registry.submit_operation ~base_path:root ~keeper_name ~operation_id
    ~source:(`Assoc ["kind",`String "fixture"]) ~input |> require "submit" |> ignore;
  match Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
      (fun () -> Eio.Promise.await settled) with
  | Owner.Operation_succeeded _ -> ()
  | Operation_failed {detail;_} -> fail detail
  | Operation_deferred -> fail "cut dispatch deferred"

let () = match Array.to_list Sys.argv with
  | [_; "--native-context-child"; root] -> run_phase ~child:true root
  | [_; "--native-branch-context-child"; root] -> run_phase ~operation_branch:true ~child:true root
  | _ -> run "native shared context restart"
      ["context ownership", [test_case "exact retired response cut advances input authority" `Quick test_retired_input_history_cut;
       test_case "resumed tool and hook changes reach durable checkpoint"
        `Quick (test_active_context_restart ~operation_branch:false);
       test_case "original branch survives actual native process crash while preserving independent G"
         `Quick (test_active_context_restart ~operation_branch:true);
       test_case "first input checkpoint precedes native terminal settlement"
         `Quick (test_native_input_checkpoint_order ~uncertain_consume:false);
       test_case "uncertain input consumption never rolls retained state back"
         `Quick (test_native_input_checkpoint_order ~uncertain_consume:true);
       test_case "canonical refusal preserves consumed ownership and rejects stale source"
         `Quick (test_native_input_checkpoint_order ~fail_before_canonical:true ~uncertain_consume:true)]]
