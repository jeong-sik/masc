(* #52341: the server dies while a Keeper's provider call is in flight. The
   call's journal keeps its turn and provider attempt open, and the Owner's
   checkpoint precedes the request, so the same run cannot continue that turn:
   resuming it failed with "restored checkpoint turn counter differs from the
   owning durable turn". The claim that takes the requeued operation now
   closes that run and opens a new call from the retained checkpoint (RFC
   uncollected-provider-turn-is-not-resumed 4.2, RFC
   restart-resumes-running-chat-operations 4.4). *)
open Alcotest
open Masc
module Native = Keeper_direct_native_continuation
module Owner = Keeper_owner
module Registry = Keeper_owner_registry

let keeper_name = "native-uncollected-proof"
let session_id = "native-uncollected-session"
let model_id = "native-uncollected-model"
let runtime_id = "native-uncollected.runtime"
let goal = "Answer once the server is back."
let answer = "answered after the restart"
let crash_exit = 88
let child_flag = "--native-uncollected-child"
let require label = function Ok value -> value | Error _ -> fail (label ^ " failed")
let operation_id = Keeper_chat_operation.Operation_id.of_string "native-uncollected-operation"
  |> require "operation ID"

let final_reply =
  {|{"id":"uncollected-final","model":"native-uncollected-model","choices":[{"index":0,"message":{"role":"assistant","content":"answered after the restart"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}

let retained_messages ~session_dir reference =
  (Keeper_checkpoint_store.load_retained_exact_snapshot ~session_dir ~reference
   |> require "retained checkpoint"
   |> Keeper_checkpoint_store.exact_snapshot_checkpoint).Agent_core.Checkpoint.messages

let run_phase ~child root =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  ignore (Server_startup_state.mark_state_ready ());
  Runtime_agent_execution_runtime.initialize ~sw ~domain_mgr:env#domain_mgr ~domain_count:1
    |> require "native execution runtime";
  let runtime = Runtime_agent_execution_runtime.get () |> Option.get in
  let previous_catalog = Llm_provider.Catalog_snapshot.current () in
  Eio.Switch.on_release sw (fun () -> Llm_provider.Catalog_snapshot.publish previous_catalog);
  let catalog = Printf.sprintf
      "[[models]]\nmodel_id = %S\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 8192\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n" model_id in
  Llm_provider.Model_catalog.of_toml_string ~source:"native-uncollected-test" catalog
    |> require "model catalog" |> (fun models -> Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Some models) ~providers:(None)));
  let provider_calls = ref 0 in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Reply_with (fun _ _ ->
        (* The request reached the provider and no response comes back: the
           child dies with its provider attempt open. *)
        if child then Unix._exit crash_exit;
        incr provider_calls;
        `OK, final_reply)) in
  let provider_cfg = Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture"
      ~model_id ~base_url:server.base_url ~request_path:"/v1/chat/completions" () in
  let workspace = Workspace.default_config root in
  (* Where production keeps the session, so restart settlement reads the
     call's journal (keeper_turn.ml). *)
  let session_dir = Filename.concat (Keeper_fs.session_store_path workspace) session_id in
  if child then (
    ignore (Workspace.init workspace ~agent_name:(Some "native-uncollected-test"));
    let meta = Masc_test_deps.meta_of_json_fixture (`Assoc [
      "name", `String keeper_name; "trace_id", `String session_id;
      "activation_mode", `String "manual"]) |> require "meta" in
    Keeper_meta_store.replace_snapshot workspace meta |> require "persist meta";
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 Eio.Path.(env#fs / session_dir));
  let settled, resolve_settled = Eio.Promise.create () in
  let execute ~sw:turn_sw ~keeper_name:_ ~claim =
    let operation : Keeper_chat_operation.t =
      claim () |> require "claim operation" |> Option.get in
    check bool "the original operation is claimed" true
      (Keeper_chat_operation.Operation_id.equal operation_id operation.operation_id);
    let binding : Native.binding =
      {base_path=root; keeper_name; operation_id;
       execution_digest=operation.execution_digest; session_dir; session_id} in
    let read_call () = Registry.direct_native_call ~base_path:root ~keeper_name ~operation_id
      |> require "read the Owner's native call" in
    let admission = Native.load ~binding |> require "load native admission" in
    let context, checkpoint, input, cut = match child, admission with
      | true, Native.No_pending ->
        let context = Agent_core.Context.create () in
        let scope = Keeper_execution_scope_id.direct_operation operation_id in
        let frame = Keeper_repetition_snapshot.admit Keeper_repetition_snapshot.empty
            (Keeper_repetition_snapshot.Fresh scope) |> require "direct scope" in
        Keeper_repetition_scope.save context frame;
        context, None, Native.New_input {blocks=[Agent_core.Types.Text goal]; metadata=[]}, None
      | false, Native.Resume resumed ->
        let cut = match read_call () with
          | Keeper_native_call.Active call -> call
          | Keeper_native_call.No_native_call | Keeper_native_call.Terminal_unacknowledged _ ->
            fail "the requeued operation holds no Active native call" in
        Native.restored_context resumed, Some (Native.checkpoint resumed),
        Native.input resumed, Some cut
      | true, (Native.Resume _ | Native.Terminal_pending _)
      | false, (Native.No_pending | Native.Terminal_pending _) ->
        fail "expected a fresh child call and an Active call after the restart" in
    let config = Runtime_agent.default_config
        ~media_store:(Agent_core.History.Memory_store.create ()) ~name:keeper_name ~provider_cfg
        ~system_prompt:"Answer the operator." ~tools:[] in
    let config = {config with context=Some context} in
    let agent_ref = ref None in
    let prepared = Native.prepare ~binding ~runtime_id ~config
        ~agent_core_checkpoint:checkpoint ~input ~agent_ref () |> require "prepare native call" in
    let config = Native.config prepared in
    let checkpoint = Native.prepared_checkpoint prepared in
    let result = match Native.prepared_input prepared with
      | Native.New_input {blocks; metadata} ->
        Runtime_agent.run_blocks ~sw:turn_sw ~net:env#net ~config ~agent_ref
          ?agent_core_checkpoint:checkpoint ~input_metadata:metadata
          ~execution_capture:(Runtime_agent.execution_capture config) blocks
      | Native.Continue_from_checkpoint ->
        Runtime_agent.continue_from_checkpoint ~sw:turn_sw ~net:env#net ~config ~agent_ref
          ~checkpoint:(Option.get checkpoint)
          ~execution_capture:(Runtime_agent.execution_capture config) () in
    (* Before the fix the cut call was reopened here and this failed with the
       turn counter error. The child never reaches this point. *)
    let result = match Result.map_error Runtime_agent.run_failure_error result with
      | Ok result -> result
      | Error error -> fail (Agent_core.Error.to_string error) in
    let cut = match cut with
      | Some cut -> cut
      | None -> fail "the child answered before its crash boundary" in
    check string "the new call answers the cut turn" answer
      (Llm_provider.Types.text_of_content result.response.content);
    let call = match read_call () with
      | Keeper_native_call.Terminal_unacknowledged (call,
          {Agent_core.Agent.outcome=Terminal_succeeded; recovery=Retire}) -> call
      | Keeper_native_call.No_native_call | Keeper_native_call.Active _
      | Keeper_native_call.Terminal_unacknowledged (_,
          {Agent_core.Agent.outcome=(Terminal_failed | Terminal_cancelled); _})
      | Keeper_native_call.Terminal_unacknowledged (_,
          {Agent_core.Agent.outcome=Terminal_succeeded;
           recovery=Operator_repair_required Effect_outcome_unknown}) ->
        fail "the new native call did not durably finish" in
    check bool "a new call replaced the cut call" false (String.equal call.call_id cut.call_id);
    check string "the new call keeps the cut call's runtime" cut.runtime_id call.runtime_id;
    (match call.api with
     | Keeper_native_call.Continue_from_checkpoint -> ()
     | Keeper_native_call.New_input _ ->
       fail "the new call took new input instead of the retained checkpoint");
    (* Bind checks history only when the cut call admitted a Tool attempt. *)
    check bool "the new seed is the cut call's retained checkpoint, unchanged" true
      (retained_messages ~session_dir call.seed_checkpoint
       = retained_messages ~session_dir cut.checkpoint);
    let cut_dir = Eio.Path.(env#fs / session_dir / "native-executions" / cut.call_id) in
    let projection = Agent_core.Agent.open_execution_projection ~runtime ~dir:cut_dir cut.locator
      |> require "open the cut call's journal" in
    (match Agent_core.Agent.read_execution_terminal projection
           |> require "read the cut call's terminal" with
     | Some {Agent_core.Agent.disposition={outcome=Terminal_cancelled; recovery=Retire}; _} -> ()
     | Some _ | None -> fail "the cut call's journal is not closed Cancelled with Retire");
    Owner.Operation_succeeded {outcome_ref="cut-turn-answered"}
  in
  let runner : Owner.operation_runner =
    {ready=(fun ~keeper_name:_ -> true); execute;
     on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~operations:_ ~execution ->
       Eio.Promise.resolve resolve_settled execution)} in
  Registry.install_from_store ~sw ~operation_runner:(Some runner)
    ~on_turn_slot_released:None workspace |> require "install Owner" |> ignore;
  Native.complete_restart_settlements ~runtime ~base_path:root
    |> require "complete startup native journal settlement" |> ignore;
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
     fail "the cut operation did not complete after the restart");
  check int "the restart sends the cut turn's provider request once" 1 !provider_calls;
  check bool "Owner acknowledges the new call" true
    (Registry.direct_native_call ~base_path:root ~keeper_name ~operation_id
     |> require "read Owner acceptance"
     |> Keeper_native_call.equal_state Keeper_native_call.No_native_call)

let test_cut_provider_turn_continues_after_restart () =
  let root = Filename.temp_dir "keeper-native-uncollected-" "" in
  Fun.protect ~finally:(fun () ->
    Eio_main.run (fun env -> Eio.Path.rmtree ~missing_ok:true Eio.Path.(env#fs / root)))
    (fun () ->
      Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
        let process = Eio.Process.spawn ~sw env#process_mgr
            [Sys.executable_name; child_flag; root] in
        match Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
            (fun () -> Eio.Process.await process) with
        | `Exited code -> check int "the child dies during its provider call" crash_exit code
        | `Signaled signal -> failf "child died from signal %d" signal));
      run_phase ~child:false root)

let () = match Array.to_list Sys.argv with
  | [_; flag; root] when String.equal flag child_flag -> run_phase ~child:true root
  | _ -> run "native uncollected turn restart"
      ["restart", [test_case "a turn cut during its provider call continues from the retained checkpoint"
        `Quick test_cut_provider_turn_continues_after_restart]]
