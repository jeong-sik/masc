(* A native call retains one full checkpoint per Core checkpoint and commits
   its reference to the operation journal. Every journal commit that stops
   naming a retained checkpoint removes its file, so at each step of a real
   Core execution the retained directory holds exactly the files the
   operation's journal names: through tool rounds, a call that replaces a
   retired one, settlement, and a cooperative suspension and its resume. *)
open Alcotest
open Masc
module Native = Keeper_direct_native_continuation
module Owner = Keeper_owner
module Registry = Keeper_owner_registry

let keeper_name = "native-release-proof"
let session_id = "native-release-session"
let model_id = "native-release-model"
let runtime_id = "native-release.runtime"
let goal = "Call the tool, then answer."
let tool_rounds = 3
let require label = function Ok value -> value | Error _ -> fail (label ^ " failed")
let operation_id = Keeper_chat_operation.Operation_id.of_string "native-release-operation"
  |> require "operation ID"

let tool_reply round = Printf.sprintf
  {|{"id":"release-tool-%d","model":"native-release-model","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"release-call-%d","type":"function","function":{"name":"record_round","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
  round round
let final_reply =
  {|{"id":"release-final","model":"native-release-model","choices":[{"index":0,"message":{"role":"assistant","content":"rounds recorded"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}

(* How the operation ends after its first native call. *)
type scenario =
  | Replace_then_settle
      (* A second call replaces the retired one, then the operation succeeds. *)
  | Suspend_then_resume
      (* The operation yields on the first call's latest checkpoint, is claimed
         again and resumes from it, then succeeds. *)
  | Removal_fails
      (* The file of the second checkpoint cannot be removed when the third
         supersedes it; the call goes on and only that entry stays. *)

let retained_files session_dir =
  match Sys.readdir (Filename.concat session_dir Keeper_checkpoint_store.retained_dirname) with
  | names -> Array.to_list names
    |> List.filter_map (Filename.chop_suffix_opt ~suffix:".json")
    |> List.sort String.compare
  | exception Sys_error _ -> []

let sha (reference : Keeper_checkpoint_ref.t) = reference.sha256

let rec mkdir_p path =
  if not (Sys.file_exists path) then (mkdir_p (Filename.dirname path); Unix.mkdir path 0o700)

let run_call ~scenario root =
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
  Llm_provider.Model_catalog.of_toml_string ~source:"native-release-test" catalog
    |> require "model catalog" |> Llm_provider.Model_catalog.set_global;
  let provider_calls = ref 0 in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Reply_with (fun _ _ ->
        incr provider_calls;
        `OK, if !provider_calls <= tool_rounds then tool_reply !provider_calls else final_reply)) in
  let provider_cfg = Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat ~provider_id:"fixture"
      ~model_id ~base_url:server.base_url ~request_path:"/v1/chat/completions" () in
  let workspace = Workspace.default_config root in
  ignore (Workspace.init workspace ~agent_name:(Some "native-release-test"));
  let meta = Masc_test_deps.meta_of_json_fixture (`Assoc [
    "name", `String keeper_name; "trace_id", `String session_id;
    "activation_mode", `String "manual"]) |> require "meta" in
  Keeper_meta_store.replace_snapshot workspace meta |> require "persist meta";
  (* The session lives where the Owner and the startup sweep look. *)
  let runtime_root = Workspace.masc_dir workspace in
  let session_dir = Filename.concat
      (Keeper_fs.session_store_path_for_runtime_root runtime_root) session_id in
  mkdir_p session_dir;
  let read_call () = Registry.direct_native_call ~base_path:root ~keeper_name ~operation_id
    |> require "read native call" in
  (* What the operation's journal names: its native call's references and a
     suspension's checkpoint. *)
  let named () =
    let suspended = match Registry.direct_checkpoint ~base_path:root ~keeper_name ~operation_id
                          |> require "read suspension" with
      | Some (Keeper_semantic_execution.Agent_core reference) -> [reference]
      | Some (Keeper_semantic_execution.Official_client _) | None -> [] in
    Keeper_native_call.checkpoint_references (read_call ()) @ suspended
    |> List.map sha |> List.sort_uniq String.compare in
  let stuck = ref None in
  let check_exact label =
    let expected = named () @ Option.to_list !stuck |> List.sort_uniq String.compare in
    check (list string) label expected (retained_files session_dir) in
  let checkpoints = ref 0 in
  let executions = ref 0 in
  let settled, resolve_settled = Eio.Promise.create () in
  let context_for_operation () =
    let context = Agent_core.Context.create () in
    let frame = Keeper_repetition_snapshot.admit Keeper_repetition_snapshot.empty
        (Keeper_repetition_snapshot.Fresh (Keeper_execution_scope_id.direct_operation operation_id))
      |> require "direct scope" in
    Keeper_repetition_scope.save context frame;
    context in
  let rounds = ref 0 in
  let tool = Agent_core.Tool.create ~name:"record_round"
      ~description:"Record one round" ~parameters:[] (fun _ ->
        incr rounds;
        Ok {Agent_core.Types.content=Printf.sprintf "round %d recorded" !rounds;
            content_blocks=None; _meta=None}) in
  (* The adapter's sink commits each checkpoint, and the Owner removes what
     that commit released, before this one runs. *)
  let checkpoint_sink (_ : Agent_core.Agent.checkpoint_snapshot) =
    incr checkpoints;
    check_exact (Printf.sprintf "after checkpoint %d the retained files are the named ones"
                   !checkpoints);
    (match scenario, !checkpoints with
     | Removal_fails, 2 ->
       (* The file this checkpoint names becomes a directory, which
          [Keeper_checkpoint_store.release_retained] refuses to remove. *)
       (match read_call () with
        | Keeper_native_call.Active call ->
          let path = Filename.concat (Filename.concat session_dir Keeper_checkpoint_store.retained_dirname)
              (sha call.checkpoint ^ ".json") in
          Sys.remove path;
          Unix.mkdir path 0o700;
          stuck := Some (sha call.checkpoint)
        | Keeper_native_call.No_native_call | Keeper_native_call.Terminal_unacknowledged _ ->
          fail "the second checkpoint has no active call")
     | (Replace_then_settle | Suspend_then_resume | Removal_fails), _ -> ());
    Ok () in
  let native_call ~turn_sw ~binding ~checkpoint ~input =
    let config = Runtime_agent.default_config ~name:keeper_name ~provider_cfg
        ~system_prompt:"Record every round." ~tools:[tool] in
    let config = {config with context=Some (match checkpoint with
        | Some (checkpoint : Agent_core.Checkpoint.t) -> Agent_core.Context.copy ~eio:true checkpoint.context
        | None -> context_for_operation ());
      checkpoint_sink=Some checkpoint_sink} in
    let agent_ref = ref None in
    let prepared = Native.prepare ~binding ~runtime_id ~config ~agent_core_checkpoint:checkpoint
        ~input ~agent_ref () |> require "prepare native call" in
    let config = Native.config prepared in
    let result = match Native.prepared_input prepared, Native.prepared_checkpoint prepared with
      | Native.New_input {blocks; metadata}, checkpoint ->
        Runtime_agent.run_blocks ~sw:turn_sw ~net:env#net ~config ~agent_ref
          ?agent_core_checkpoint:checkpoint ~input_metadata:metadata blocks
      | Native.Continue_from_checkpoint, Some checkpoint ->
        Runtime_agent.continue_from_checkpoint ~sw:turn_sw ~net:env#net ~config ~agent_ref
          ~checkpoint ()
      | Native.Continue_from_checkpoint, None -> fail "continuation without a checkpoint" in
    (match result with
     | Ok result ->
       check string "the call completes" "rounds recorded"
         (Agent_core.Types.text_of_content result.response.content)
     | Error error -> fail (Agent_core.Error.to_string error));
    match read_call () with
    | Keeper_native_call.Terminal_unacknowledged (call, _) ->
      check_exact "after the terminal receipt the retained files are the named ones";
      call
    | Keeper_native_call.No_native_call | Keeper_native_call.Active _ ->
      fail "the native call has no terminal receipt" in
  let execute ~sw:turn_sw ~keeper_name:_ ~claim =
    incr executions;
    let operation : Keeper_chat_operation.t =
      claim () |> require "claim operation" |> Option.get in
    let binding : Native.binding =
      {base_path=root; keeper_name; operation_id;
       execution_digest=operation.execution_digest; session_dir; session_id} in
    match scenario, !executions with
    | Suspend_then_resume, 2 ->
      let observed = match Registry.direct_checkpoint ~base_path:root ~keeper_name ~operation_id
                           |> require "read suspension" with
        | Some observed -> observed
        | None -> fail "the claimed operation has no suspension" in
      Registry.resume_direct_checkpoint ~base_path:root ~keeper_name ~operation_id ~observed
        |> require "resume";
      check_exact "resuming releases the checkpoint the suspension named";
      Owner.Operation_succeeded {outcome_ref="resumed"}
    | (Replace_then_settle | Suspend_then_resume | Removal_fails), _ ->
      (match Native.load ~binding |> require "load native admission" with
       | Native.No_pending -> ()
       | Native.Resume _ | Native.Terminal_pending _ -> fail "a fresh operation has a native call");
      let first = native_call ~turn_sw ~binding ~checkpoint:None
          ~input:(Native.New_input {blocks=[Agent_core.Types.Text goal]; metadata=[]}) in
      check int "every tool round ran" tool_rounds !rounds;
      check bool "the call superseded more than one checkpoint" true (!checkpoints > 2);
      (match scenario with
       | Replace_then_settle ->
         let latest = Keeper_checkpoint_store.load_retained_exact_snapshot ~session_dir
             ~reference:first.checkpoint |> require "the latest checkpoint loads"
           |> Keeper_checkpoint_store.exact_snapshot_checkpoint in
         let replacement = native_call ~turn_sw ~binding ~checkpoint:(Some latest)
             ~input:Native.Continue_from_checkpoint in
         check bool "the replacement is another call" true
           (not (String.equal replacement.call_id first.call_id));
         List.iter (fun (label, reference) ->
           check bool label false (List.mem (sha reference) (retained_files session_dir)))
           ["the retired seed is released", first.seed_checkpoint;
            "the retired latest checkpoint is released", first.checkpoint];
         Owner.Operation_succeeded {outcome_ref="replaced"}
       | Suspend_then_resume ->
         ignore (Registry.defer_direct_checkpoint ~base_path:root ~keeper_name ~operation_id
                   ~execution_digest:operation.execution_digest
                   ~checkpoint:(Keeper_semantic_execution.Agent_core first.checkpoint)
                 |> require "suspend" : Keeper_chat_operation.t);
         check (list string) "the suspension keeps only the checkpoint it names"
           [sha first.checkpoint] (retained_files session_dir);
         Owner.Operation_deferred
       | Removal_fails -> Owner.Operation_succeeded {outcome_ref="stuck"})
  in
  let runner : Owner.operation_runner =
    {ready=(fun ~keeper_name:_ -> true); execute;
     on_execution_settled=(fun ~keeper_name:_ ~claimed_operation_id:_ ~execution ->
       match execution with
       | Owner.Operation_deferred -> ()
       | Owner.Operation_succeeded _ | Owner.Operation_failed _ ->
         Eio.Promise.resolve resolve_settled execution)} in
  Registry.install_from_store ~sw ~operation_runner:(Some runner)
    ~on_turn_slot_released:None workspace |> require "install Owner" |> ignore;
  let input = Keeper_chat_operation_payload.input_to_json ~message:goal ~user_blocks:[]
      ~turn_instructions:None ~surface_context:None ~attachments:[]
    |> Keeper_chat_operation.canonical_json |> require "canonical input" in
  Registry.submit_operation ~base_path:root ~keeper_name ~operation_id
    ~source:(`Assoc ["kind", `String "fixture"]) ~input |> require "submit operation" |> ignore;
  (match Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds
      (fun () -> Eio.Promise.await settled) with
   | Owner.Operation_succeeded _ -> ()
   | Owner.Operation_failed {detail; _} -> fail detail
   | Owner.Operation_deferred -> fail "the operation stayed deferred");
  check bool "the Owner acknowledges the retired call" true
    (Keeper_native_call.equal_state Keeper_native_call.No_native_call (read_call ()));
  check (list string) "settlement leaves only what could not be removed"
    (Option.to_list !stuck) (retained_files session_dir);
  match Keeper_retained_checkpoint_sweep.run ~runtime_root with
  | Ok report -> check int "the startup sweep finds no named-nowhere file" 0 report.removed
  | Error error -> fail (Keeper_retained_checkpoint_sweep.error_to_string error)

let with_root scenario () =
  let root = Filename.temp_dir "keeper-native-release-" "" in
  Fun.protect ~finally:(fun () ->
    Eio_main.run (fun env -> Eio.Path.rmtree ~missing_ok:true Eio.Path.(env#fs / root)))
    (fun () -> run_call ~scenario root)

let () =
  run "native checkpoint release"
    ["retained checkpoints", [
       test_case "a replaced and settled call keeps only named checkpoints" `Quick
         (with_root Replace_then_settle);
       test_case "a suspension keeps only the checkpoint it names until resumed" `Quick
         (with_root Suspend_then_resume);
       test_case "a removal that fails is logged and the call goes on" `Quick
         (with_root Removal_fails)]]
