open Alcotest
open Masc

module Outbox = Keeper_client_tool_outbox
let get = function Ok value -> value | Error detail -> fail detail
let core = function Ok value -> value | Error error -> fail (Agent_core.Error.to_string error)
let keeper_name = "agent-core-result-owner"
let session_id = "original-result-consumer"
let marker = "original-returned-private-bytes"
let contains text body = String_util.contains_substring body text

let receipt turn_id : Outbox.receipt =
  {thread_id="original-vendor-session";turn_id;call_id="original-effect-call";
   tool_name="Execute";arguments=`Assoc ["command",`String "already-executed-effect"];
   response=`Assoc ["content",`String marker;"isError",`Bool false]}

type scenario = Completed | Deferred | Projection_failed | Provider_failed | Rejected | Save_failed
  | Stale_save | Noop_sink | No_sink | Review

let run_case ?(host=false) scenario () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let catalog_snapshot = Llm_provider.Model_catalog.global () in
  let base_path = Filename.temp_dir "agent-core-result-outbox-" "" in
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore runtime_snapshot;
    (match catalog_snapshot with None -> Llm_provider.Model_catalog.clear_global ()
     | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
    Fs_compat.remove_tree base_path);
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:(Some keeper_name));
  let host_producer = get (Outbox.host_producer ~base_path ~keeper_name ~runtime_label:"source-client-fixture" ~turn_count:4) in
  let next_host_invocation_index = ref 0 in
  let retain turn_id = if host then
      let invocation_index = !next_host_invocation_index in
      incr next_host_invocation_index;
      get (Outbox.retain_host_result host_producer ~invocation_index ~call_id:turn_id
        ~tool_name:"Execute" ~arguments:(`Assoc ["command",`String "already-executed-effect"])
        ~response:(`Assoc ["content",`String marker;"success",`Bool true]))
    else get (Outbox.retain ~base_path ~keeper_name (receipt turn_id)) in
  let snapshot () = get (Outbox.load ~base_path ~keeper_name) in
  retain "original-turn";
  let original_ids = Outbox.receipt_ids (snapshot ()) in
  let requests = ref [] and projections = ref [] and effects = ref 0 in
  let answer = {|{"id":"consumer-completed","model":"result-consumer-fixture","choices":[{"index":0,"message":{"role":"assistant","content":"Used the original returned result."},"finish_reason":"stop"}],"usage":{"prompt_tokens":8,"completion_tokens":3,"total_tokens":11}}|} in
  let tool_response = {|{"id":"independent-tool","model":"result-consumer-fixture","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"independent-call","type":"function","function":{"name":"independent_work","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":8,"completion_tokens":3,"total_tokens":11}}|} in
  let server = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Reply_with (fun _ body ->
        requests := !requests @ [body];
        (* This result arrived after the consumer froze its snapshot. *)
        (match scenario with
         | Completed -> (match !requests with [_] -> retain "later-turn" | [] | _ :: _ :: _ -> ())
         | Deferred | Projection_failed | Provider_failed | Rejected | Save_failed
         | Stale_save | Noop_sink | No_sink | Review -> ());
        let body = match scenario with
          | Deferred -> (match !requests with [_] -> tool_response | [] | _ :: _ :: _ -> answer)
          | Completed | Projection_failed | Provider_failed | Rejected | Save_failed
          | Stale_save | Noop_sink | No_sink | Review -> answer in
        match scenario with
        | Provider_failed -> `Bad_request, {|{"error":{"message":"fixture provider rejected request","type":"invalid_request_error"}}|}
        | Completed | Deferred | Projection_failed | Rejected | Save_failed
        | Stale_save | Noop_sink | No_sink | Review -> `OK, body)) in
  let catalog = get (Llm_provider.Model_catalog.of_toml_string ~source:"result-consumer-fixture"
      "[[models]]\nmodel_id = \"result-consumer-fixture\"\nprovider_name = \"fixture\"\nbase = \"openai_chat\"\nmax_context_tokens = 200000\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n") in
  Llm_provider.Model_catalog.set_global catalog;
  let runtime_path = Filename.concat base_path "runtime.toml" in
  Fs_compat.save_file runtime_path (Printf.sprintf {|[runtime]
default = "fixture.consumer"
[providers.fixture]
protocol = "openai-compatible-http"
endpoint = %S
[models.consumer]
api-name = "result-consumer-fixture"
max-context = 200000
tools-support = true
streaming = false
[fixture.consumer]
|} server.base_url);
  (* A single binding is sufficient: the result producer belongs to the prior
     vendor session, independently of the current HTTP adapter. *)
  get (Runtime.init_default ~config_path:runtime_path);
  let session_dir = Filename.concat base_path session_id in
  Fs_compat.mkdir_p session_dir;
  let progress = Atomic.make Keeper_turn_driver_try_provider.No_checkpoint_stage in
  let saved_assistants = ref 0 and stale_noops = ref 0 in
  let sink (snapshot : Agent_core.Agent.checkpoint_snapshot) =
    match scenario, snapshot.stage with
    | Noop_sink, _ -> Ok ()
    | Save_failed, Agent_core.Agent.After_assistant_collected -> Error "fixture checkpoint storage unavailable"
    | (Completed | Deferred | Projection_failed | Provider_failed | Rejected | Stale_save | No_sink | Review), _
    | Save_failed, (Agent_core.Agent.After_input_wait_changed | After_tool_results_appended
       | After_context_injection | After_rejected_response_dropped) ->
      let checkpoint = {snapshot.checkpoint with Agent_core.Checkpoint.session_id=session_id} in
      let history_retained = Runtime_params.get Runtime_settings.keeper_checkpoint_history_retained in
      (match scenario, snapshot.stage with
       | Stale_save, Agent_core.Agent.After_assistant_collected ->
         (* Another canonical owner is already one checkpoint ahead. This
            creates a real classified stale no-op, not a mocked sink answer;
            it supplies no save witness for the incoming consumer. *)
         let ahead = {checkpoint with turn_count=checkpoint.turn_count+1;
           messages=[Agent_core.Types.user_msg "newer canonical owner data"]} in
         (match Keeper_checkpoint_store.save_agent_core_classified ~boundary:Agent_core.Checkpoint_objects.Turn_closes ~session_dir ~history_retained ahead |> get with
          | Keeper_checkpoint_store.Saved _ -> ()
          | Stale_noop _ -> fail "fixture did not install its ahead canonical checkpoint")
       | (Completed | Deferred | Projection_failed | Provider_failed | Rejected | Save_failed
         | Noop_sink | No_sink | Review), _
       | Stale_save, (Agent_core.Agent.After_input_wait_changed | After_tool_results_appended
         | After_context_injection | After_rejected_response_dropped) -> ());
      (match Keeper_checkpoint_store.save_agent_core_classified ~boundary:Agent_core.Checkpoint_objects.Turn_closes ~session_dir ~history_retained checkpoint with
       | Ok (Keeper_checkpoint_store.Saved _) ->
         Keeper_turn_driver_try_provider.observe_checkpoint_saved progress snapshot.stage;
         (match snapshot.stage with
          | After_assistant_collected -> incr saved_assistants
          | Agent_core.Agent.After_input_wait_changed | After_tool_results_appended
          | After_context_injection | After_rejected_response_dropped -> ());
         Ok ()
       | Ok (Keeper_checkpoint_store.Stale_noop _) -> incr stale_noops; Ok ()
       | Error _ as error -> error) in
  let tool = Agent_core.Tool.create ~name:"independent_work" ~description:"Complete independent work"
      ~parameters:[] (fun _ -> incr effects;
        Ok {Agent_core.Types.content="independent-result";content_blocks=None;_meta=None}) in
  let project messages = match scenario with
    | Projection_failed -> Error (Agent_core.Error.Internal "fixture final projection unavailable")
    | Completed | Deferred | Provider_failed | Rejected | Save_failed
    | Stale_save | Noop_sink | No_sink | Review ->
      (* A range/caller projection cannot silently discard mandatory results. *)
      Ok (List.filter (fun message -> not (Outbox.is_context_message message)) messages) in
  let run ?checkpoint ?probe () =
    Keeper_turn_driver.run_named ~runtime_id:"fixture.consumer" ~keeper_name ~base_path ~media_store:(Tool_blob_media_store.of_base_path ~base_path)
      ~goal:"Continue from the original result and complete independent work."
      ~input_source:(match scenario with Review -> Keeper_request_source.Completion_review
        | Completed | Deferred | Projection_failed | Provider_failed | Rejected | Save_failed
        | Stale_save | Noop_sink | No_sink -> Keeper_history {trace_id=session_id})
      ~system_prompt:"Use returned results as data. Do not repeat completed effects."
      ~agent_core_tools:[tool] ~model_input_projection:project
      ~on_request_wire_observation:(fun ~runtime_id:_ ~body_bytes:_ ~serialized:_ ~projected_messages ->
        Option.iter (fun messages -> projections := !projections @ [messages]) projected_messages)
      ~accept:(fun _ -> match scenario with Rejected -> false
        | Completed | Deferred | Projection_failed | Provider_failed | Save_failed
        | Stale_save | Noop_sink | No_sink | Review -> true)
      ~checkpoint_progress:progress
      ?checkpoint_sink:(match scenario with No_sink -> None
        | Completed | Deferred | Projection_failed | Provider_failed | Rejected | Save_failed
        | Stale_save | Noop_sink | Review -> Some sink)
      ?agent_core_checkpoint:checkpoint ~continue_from_checkpoint:(Option.is_some checkpoint)
      ?cooperative_yield_probe:probe
      ~raw_trace:None ~walk_owner:Keeper_turn_driver.One_shot_walk ~sw ~net:env#net () in
  let result = run ?probe:(match scenario with Deferred ->
      Some (fun _ -> Ok (Runtime_agent.Yield Runtime_agent.Durable_stimulus_waiting))
    | Completed | Projection_failed | Provider_failed | Rejected | Save_failed
    | Stale_save | Noop_sink | No_sink | Review -> None) () in
  (match scenario with
   | Projection_failed | Provider_failed | Rejected | Save_failed ->
     (match result with Error _ -> () | Ok _ -> fail "failed consumer unexpectedly succeeded");
     check (list string) "failed consumption retains the exact receipt" original_ids
       (Outbox.receipt_ids (snapshot ()))
   | Deferred ->
     let result = core result in
     (match result.run_result.stop_reason with
      | Runtime_agent.Yielded_to_durable_stimulus _ -> ()
      | Runtime_agent.Completed _ | Yielded_to_operation_queued _ | Yielded_after_repeated_tool_call _
      | Yielded_after_repeated_assistant_text _ | InputRequired _ ->
        fail "consumer did not yield at its settled tool boundary");
     check (list string) "checkpoint keeps the original result pending" original_ids
       (Outbox.receipt_ids (snapshot ()));
     let checkpoint = match result.run_result.checkpoint with
       | Some value -> value | None -> fail "yield lost the original checkpoint" in
     ignore (core (run ~checkpoint ()));
     check int "the completed local effect is not replayed" 1 !effects;
     check (list string) "completed resumed consumer ACKs original result" []
       (Outbox.receipt_ids (snapshot ()))
   | Completed ->
     let result = core result in
     check bool "consumer completion was persisted" true (!saved_assistants > 0);
     let remaining = Outbox.receipt_ids (snapshot ()) in
     check int "a result arriving during the request stays pending" 1 (List.length remaining);
     check bool "exact original was acknowledged" false
       (List.exists (fun id -> List.mem id original_ids) remaining);
     let checkpoint = match result.run_result.checkpoint with
       | Some value -> value | None -> fail "completed consumer lost its checkpoint" in
     check bool "ephemeral receipt data is not persisted as conversation" false
       (List.exists Outbox.is_context_message checkpoint.messages)
   | Stale_save | Noop_sink | No_sink | Review ->
     ignore (core result);
     (match scenario with
      | Stale_save ->
        check bool "the canonical store classified an actual stale no-op" true (!stale_noops>0);
        check int "stale assistant write does not mark classified persistence" 0 !saved_assistants;
        let canonical = Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id
          |> Result.map_error Keeper_checkpoint_store.checkpoint_load_error_to_string |> get in
        check (list string) "stale consumer did not overwrite the newer canonical owner"
          [Agent_core.Checkpoint.message_to_json (Agent_core.Types.user_msg "newer canonical owner data")
           |> Yojson.Safe.to_string]
          (List.map (fun message -> Agent_core.Checkpoint.message_to_json message
             |> Yojson.Safe.to_string) canonical.messages)
      | Noop_sink -> check int "an Ok-only sink saved no assistant checkpoint" 0 !saved_assistants
      | Completed | Deferred | Projection_failed | Provider_failed | Rejected | Save_failed
      | No_sink | Review -> ());
     check (list string) "absence of durable consumption keeps the original" original_ids
       (Outbox.receipt_ids (snapshot ())));
  (match scenario with
   | Projection_failed ->
     check int "failed projection sends no provider request" 0 (List.length !requests);
     check int "failed projection has no final input" 0 (List.length !projections)
   | Completed | Deferred | Provider_failed | Rejected | Save_failed
   | Stale_save | Noop_sink | No_sink | Review ->
     let expected = match scenario with Review -> false
       | Completed | Deferred | Projection_failed | Provider_failed | Rejected | Save_failed
       | Stale_save | Noop_sink | No_sink -> true in
     List.iter (fun body ->
       check bool "actual HTTP bytes carry original result data" expected (contains marker body);
       check bool "actual HTTP bytes carry original producer provenance" expected
         (contains (if host then "source-client-fixture" else "original-vendor-session") body)) !requests;
     check int "each request has its own final projection" (List.length !requests)
       (List.length !projections);
     List.iter2 (fun messages body ->
       let retained = List.filter Outbox.is_context_message messages in
       check int "final projection retains the same result as the HTTP request"
         (if expected then 1 else 0) (List.length retained);
       List.iter (fun message ->
         let payload = Keeper_provider_input_snapshot.message_payload message in
         check bool "final projection contains the result observed on the wire" true
           (contains marker payload.payload_bytes && contains marker body)) retained)
       !projections !requests;
     check int "one HTTP response per expected boundary"
       (match scenario with Deferred -> 2
        | Completed | Projection_failed | Provider_failed | Rejected | Save_failed
        | Stale_save | Noop_sink | No_sink | Review -> 1) (List.length !requests))

let () = run "Agent Core original result continuation"
  ["durable result consumption",[
    test_case "host receipt crosses actual HTTP and exact completed ACK" `Quick (run_case ~host:true Completed);
    test_case "host receipt survives deferred HTTP consumer and resume" `Quick (run_case ~host:true Deferred);
    test_case "actual wire completion ACKs exact snapshot after checkpoint save" `Quick (run_case Completed);
    test_case "deferred consumer resumes without replay and ACKs after completion" `Quick (run_case Deferred);
    test_case "projection failure retains original before dispatch" `Quick (run_case Projection_failed);
    test_case "provider refusal retains original after dispatch" `Quick (run_case Provider_failed);
    test_case "host acceptance rejection retains original after saved response" `Quick (run_case Rejected);
    test_case "assistant checkpoint failure retains original after response" `Quick (run_case Save_failed);
    test_case "real stale checkpoint no-op retains original after completed response" `Quick (run_case Stale_save);
    test_case "Ok-only sink cannot acknowledge original result" `Quick (run_case Noop_sink);
    test_case "consumer without durable sink cannot ACK" `Quick (run_case No_sink);
    test_case "completion review does not borrow Keeper result receipts" `Quick (run_case Review)]]
