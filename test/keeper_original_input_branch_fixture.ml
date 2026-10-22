open Masc
module Native=Keeper_direct_native_continuation
module Owner=Keeper_owner
module Registry=Keeper_owner_registry
let require label=function Ok value -> value | Error _ -> Alcotest.fail (label ^ " failed")
let fail=Alcotest.fail

(* Build W through an actual Core input pause, publish independent G from a
   different Owner child, then accept C through the public Owner response API.
   The original runner is no longer ready, so C stays queued for the actual
   continuation runner installed by the native/AgentRun scenario. *)
type invocation = {
  keeper_name:string; session_id:string; runtime_id:string;
  operation_id:Keeper_chat_operation.Operation_id.t;
  source:Yojson.Safe.t; input:Yojson.Safe.t; message:string;
  input_metadata:Agent_core.Types.metadata; system_prompt:string;
  provider_cfg:Llm_provider.Provider_config.t;
}
let expected_global_path workspace=Filename.concat workspace.Workspace.base_path "expected-G.json"
let expected_global_checkpoint_bytes ~workspace=Fs_compat.load_file (expected_global_path workspace)
let prepare ?(response_before_global=false) ~net ~clock ~workspace ~session_dir
    {keeper_name;session_id;runtime_id;operation_id;source;input;message;input_metadata;system_prompt;provider_cfg} =
  let module Store=Keeper_checkpoint_store in
  let root=workspace.Workspace.base_path in
  let trace_id=Keeper_id.Trace_id.of_string session_id |> require "branch trace" in
  Eio.Switch.run (fun setup_sw ->
    let ready=ref true in
    let settled,resolve_settled=Eio.Promise.create () in
    let execute ~sw:turn_sw ~keeper_name:_ ~claim =
      let operation:Keeper_chat_operation.t=claim () |> require "claim initial input" |> Option.get in
      ready:=false;
      let context=Agent_core.Context.create () in
      let frame=Keeper_repetition_snapshot.admit Keeper_repetition_snapshot.empty
        (Keeper_repetition_snapshot.Fresh (Keeper_execution_scope_id.direct_operation operation_id))
        |> require "initial input scope" in
      Keeper_repetition_scope.save context frame;
      Agent_core.Context.set context "before-restart" (`String "retained");
      let request:Agent_core.Hooks.elicitation_request=
        {question="Original branch question?";schema=None;timeout_s=None} in
      let hooks={Agent_core.Hooks.empty with before_turn=Some (fun _ -> Agent_core.Hooks.ElicitInput request)} in
      let checkpoint_sink (snapshot:Agent_core.Agent.checkpoint_snapshot)=
        match Store.save_agent_core_classified ~session_dir ~history_retained:0 snapshot.checkpoint with
        | Ok (Store.Saved _) -> Ok ()
        | Ok (Stale_noop _) -> Error "initial waiting checkpoint was not saved"
        | Error _ as error -> error in
      let config=Runtime_agent.default_config ~name:keeper_name ~provider_cfg
        ~system_prompt ~tools:[] in
      let config={config with context=Some context;hooks=Some hooks;session_id=Some session_id;
        checkpoint_sink=Some checkpoint_sink} in
      let binding:Native.binding={base_path=root;keeper_name;operation_id;session_dir;session_id;
        execution_digest=operation.execution_digest;
        checkpoint_destination=Keeper_checkpoint_destination.canonical ~keeper_name ~session_dir} in
      let agent_ref=ref None in
      let prepared=Native.prepare ~binding ~runtime_id ~config ~agent_core_checkpoint:None
        ~input:(Native.New_input {blocks=[Agent_core.Types.Text message];metadata=input_metadata}) ~agent_ref ()
        |> require "initial input native prepare" in
      let result=Runtime_agent.run_blocks ~sw:turn_sw ~net:net ~config:(Native.config prepared)
        ~agent_ref ~input_metadata [Agent_core.Types.Text message] |> require "actual original input pause" in
      let request=match result.stop_reason with
        | Runtime_agent.InputRequired {request;_} -> request
        | Completed | Yielded_to_operation_queued _ | Yielded_to_durable_stimulus _
        | Yielded_after_repeated_tool_call _ | Yielded_after_repeated_assistant_text _ ->
          fail "original invocation did not wait for input" in
      let owner=Registry.get ~base_path:root ~keeper_name |> require "initial input Owner" in
      Owner.defer_direct_input_wait owner ~operation_id ~request |> require "defer original W" |> ignore;
      Owner.Operation_deferred in
    let runner:Owner.operation_runner={ready=(fun ~keeper_name:_ -> !ready);execute;
      on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~execution ->
        Eio.Promise.resolve resolve_settled execution)} in
    Registry.install_from_store ~sw:setup_sw ~operation_runner:(Some runner) ~on_turn_slot_released:None workspace
      |> require "initial input Owner registry" |> ignore;
    Registry.submit_operation ~base_path:root ~keeper_name ~operation_id
      ~source ~input |> require "submit initial input" |> ignore;
    (match Eio.Time.with_timeout_exn clock Exact_output_fixture.fixture_wait_seconds
        (fun () -> Eio.Promise.await settled) with
     | Owner.Operation_deferred -> ()
     | Operation_failed {detail;_} -> fail detail
     | Operation_succeeded _ -> fail "waiting invocation completed prematurely");
    let owner=Registry.get ~base_path:root ~keeper_name |> require "waiting Owner" in
    let waiting=Owner.direct_input_wait owner ~operation_id |> require "original complete wait" |> Option.get in
    let original=Store.load_retained_exact_snapshot ~session_dir ~reference:waiting.checkpoint
      |> require "actual retained W" |> Store.exact_snapshot_checkpoint in
    let respond ()=match Owner.respond_direct_input_wait owner ~net ~operation_id ~observed:waiting
        ~response:Agent_core.Hooks.Declined with
      | Ok `Accepted -> ()
      | Ok (`Busy _) -> fail "idle original branch response was busy"
      | Error error -> fail (Owner.input_response_error_to_string error) in
    if response_before_global then respond ();
    let original=if response_before_global then
      Store.load_agent_core_exact_snapshot ~session_dir ~session_id
      |> require "publicly accepted canonical C" |> Store.exact_snapshot_checkpoint
      else original in
    (match Owner.run_autonomous_if_idle owner (fun () ->
      let context=Agent_core.Context.copy original.context ~eio:false in
      let scope=Keeper_execution_scope_id.autonomous_admission
        (Uuidm.of_string "00000000-0000-4000-8000-000000000010" |> Option.get) in
      let frame=Keeper_repetition_snapshot.admit Keeper_repetition_snapshot.empty
        (Keeper_repetition_snapshot.Fresh scope) |> require "independent G scope" in
      Keeper_repetition_scope.save context frame;
      Agent_core.Context.set context "independent-G" (`String "preserve across original crash");
      let pending:Agent_core.Agent_input_request.pending={run_id="independent-G-run";
        request={request_id="independent-G-request";participant_name=Some "operator";
          question="Independent G question?";schema=None;timeout_s=None;created_at=2.0}} in
      let newer={original with Agent_core.Checkpoint.context;turn_count=original.turn_count+1;
        messages=original.messages @ [Agent_core.Types.user_msg "Independent G history"];
        pending_input=Some pending;working_context=Some (`Assoc ["independent-G",`Bool true])} in
      let producer=Keeper_input_checkpoint_producer.prepare ~base_path:root ~keeper_name ~session_dir
        ~trace_id ~source:(Some original) |> require "independent Owner Producer" in
      Keeper_input_checkpoint_producer.publish_autonomous producer newer |> require "publish actual G" |> ignore;
      (match Store.save_agent_core_classified ~session_dir ~history_retained:0 newer with
       | Ok (Store.Saved _) -> () | Ok (Stale_noop _) | Error _ -> fail "save independent G");
      let path=Store.agent_core_checkpoint_path ~session_dir ~session_id in
      Fs_compat.save_file (expected_global_path workspace) (Fs_compat.load_file path)) with
     | Ok (`Ran ()) -> () | Ok (`Busy _ | `Interrupted) | Error _ -> fail "independent G child did not run");
    let expected=expected_global_checkpoint_bytes ~workspace in
    let forged={waiting.pending with request={waiting.pending.request with question="Another branch question?"}} in
    let forged=Keeper_semantic_execution.input_wait ~checkpoint:waiting.checkpoint ~pending:forged
      |> require "foreign question proof" in
    (match Owner.respond_direct_input_wait owner ~net ~operation_id ~observed:forged
        ~response:Agent_core.Hooks.Declined with
     | Error (Owner.Response_owner_error (Owner.Operation_rejected (Keeper_chat_operation_store.Invalid_input _))) -> ()
     | Error error -> fail (Owner.input_response_error_to_string error)
     | Ok _ -> fail "foreign original question acquired public branch authority");
    if not response_before_global then respond ();
    Alcotest.check Alcotest.string "public response preserves independent G bytes" expected
      (Fs_compat.load_file (Store.agent_core_checkpoint_path ~session_dir ~session_id));
    let branch=Owner.direct_input_branch owner ~operation_id |> require "public original branch" |> Option.get in
    Alcotest.check Alcotest.bool "public response preserves exact original wait binding" true
      (Keeper_semantic_execution.equal_input_wait branch.origin waiting);
    Alcotest.check Alcotest.bool "public response consumes only the original wait" true
      (Owner.direct_input_wait owner ~operation_id |> require "public wait consumed"=None);
    let duplicate=Owner.respond_direct_input_wait owner ~net ~operation_id ~observed:waiting
      ~response:Agent_core.Hooks.Declined in
    (match duplicate with
     | Error (Owner.Response_owner_error (Owner.Operation_rejected (Keeper_chat_operation_store.Invalid_input _))) -> ()
     | Error error -> fail (Owner.input_response_error_to_string error)
     | Ok _ -> fail "public branch response was accepted twice");
    Owner.begin_stopping owner |> require "close initial Owner")
