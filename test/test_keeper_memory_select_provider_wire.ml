open Alcotest
module Current = Masc.Keeper_memory_os_current
module Queue = Masc.Keeper_memory_admission_queue
module Dispatch = Masc.Keeper_tool_runtime
module Fixture = Exact_output_fixture
module Json = Yojson.Safe.Util
let require = function Ok value -> value | Error detail -> fail detail
let member = Json.member
let jstring name json = member name json |> Json.to_string
let rows name json = member name json |> Json.to_list
let sha bytes = Digestif.SHA256.(digest_string bytes |> to_hex)
let () = Masc.Prompt_defaults.init ()
let restore ~keepers_dir ~keeper_id bundle =
  let stores = ["current_snapshot",Current.path_for_keepers_dir ~keepers_dir ~keeper_id;
    "consumption_and_lookup_receipt",Current.durable_range_receipt_path ~keepers_dir ~keeper_id;
    "memory_journal",Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id;
    "pending_queue",Queue.path ~keepers_dir ~keeper_id] in
  check (list string) "closed four-store bundle" (List.sort String.compare (List.map fst stores))
    (List.sort String.compare (List.map fst (Json.to_assoc bundle)));
  let decoded = List.map (fun (name,path) ->
    let row=member name bundle in
    let present=member "present" row |> Json.to_bool in
    check (list string) "closed stored-byte envelope"
      (if present then ["bytes";"present";"sha256"] else ["present"])
      (List.sort String.compare (List.map fst (Json.to_assoc row)));
    let bytes=if present then let bytes=jstring "bytes" row in
      check string "stored bytes SHA" (jstring "sha256" row) (sha bytes); Some bytes else None in
    name,path,bytes) stores in
  List.iter (fun (_,path,bytes) -> match bytes with None -> () | Some bytes ->
    Fs_compat.mkdir_p (Filename.dirname path);
    Fs_compat.save_file_atomic_strict path bytes |> require) decoded;
  decoded

let replay ~provider_wire () =
  let fixture=Masc_test_deps.source_path "test/fixtures/event_genealogy_replay/actual.json" in
  let fixture_bytes=Fs_compat.load_file fixture in
  let envelope=Yojson.Safe.from_string fixture_bytes in
  let original=member "capture" envelope in
  let source_queries=rows "queries" original |> List.map (function
    | `Assoc fields -> `Assoc (("requests",List.assoc "experimental_requests" fields)::List.remove_assoc "requests" fields)
    | _ -> fail "captured query object required") in
  let recorded=List.filter (fun row -> member "arm" row=`String "experimental"
    && member "repetition" row=`Int 1) (rows "cases" envelope) in
  check int "exactly eleven adopted first-repetition responses" 11 (List.length recorded);
  check (list string) "responses cover every captured purpose once"
    (List.map (jstring "query_id") source_queries |> List.sort String.compare)
    (List.map (jstring "purpose_id") recorded |> List.sort String.compare);
  let answers=Hashtbl.create 11 in
  List.iter (fun row ->
    let query=List.find (fun query -> member "query_id" query=member "purpose_id" row) source_queries in
    let request=match rows "requests" query with [request] -> request | _ -> fail "one adopted request required" in
    let body=jstring "request_body" request and response=jstring "response_raw" row in
    check string "recorded actual request digest" (jstring "request_sha256" row) (sha body);
    check string "recorded actual response digest" (jstring "response_sha256" row) (sha response);
    check bool "actual response request identity is unique" false (Hashtbl.mem answers (sha body));
    Hashtbl.add answers (sha body) (body,member "status" row |> Json.to_int,response)) recorded;
  check int "eleven actual response identities are recorded" 11 (Hashtbl.length answers);
  check int "frozen experiment contains eleven purposes" 11 (List.length source_queries);
  check int "frozen purposes have eleven distinct query identities" 11
    (List.length (List.sort_uniq String.compare (List.map (jstring "query_id") source_queries)));
  let bundle=member "state_bundle" original in
  check string "source bundle hash" (jstring "state_bundle_sha256" original) (sha (Yojson.Safe.to_string bundle));
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let net=Eio.Stdenv.net env and clock=Eio.Stdenv.clock env in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_context.with_test_env ~net ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  let base_path=Filename.temp_dir "memory-select-capture-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some (Filename.concat base_path "config")) @@ fun () ->
  Config_dir_resolver.reset ();
  Fun.protect ~finally:Config_dir_resolver.reset @@ fun () ->
  let keeper_id=jstring "keeper_id" original |> Keeper_id.Keeper_name.of_string |> require |> Keeper_id.Keeper_name.to_string in
  let trace_id=jstring "trace_id" original |> Keeper_id.Trace_id.of_string |> require |> Keeper_id.Trace_id.to_string in
  let config=Masc.Workspace.default_config base_path in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let stores=restore ~keepers_dir ~keeper_id bundle in
  let instructions=jstring "keeper_instructions" original in
  let meta=Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String keeper_id;
    "trace_id",`String trace_id;"instructions",`String instructions]) |> require in
  let turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:(member "absolute_turn" original |> Json.to_int) in
  let bodies=ref [] and errors=ref [] in
  let server=Fixture.start_server ~sw ~net ~clock (Fixture.Reply_with (fun _ body ->
    bodies:=body :: !bodies;
    match Hashtbl.find_opt answers (sha body) with
    | Some (expected,status,response) when expected=body -> Cohttp.Code.status_of_code status,response
    | _ -> errors:=sha body :: !errors; `Bad_request,"uncaptured request")) in
  let key="MASC_TEST_SELECT_CAPTURE_KEY" in
  Masc_test_deps.with_process_env key (Some "synthetic-local-key") @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled=true;workspace_memory_selection_enabled=true;
     excluded_keepers=[];destinations=({Runtime_schema.endpoint=server.base_url;model="jev-latest";api_key_env=key},[])} @@ fun () ->
  let context : Dispatch.context =
    {config;meta;publication_recovery={provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper_id};
     ctx_work=Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"";
     turn_sandbox_factory=None;sw=Some sw;clock=Some clock;proc_mgr=None;net=Some net;
     mcp_session_id=None;continuation_channel=None;gate_context=None;turn_ref=Some turn_ref;
     gate_grant=None;tool_use_id=None;trace_id=None;result_projection=None;capability_authority=Compatibility_meta} in
  let descriptor=match Dispatch.descriptor_for_internal "keeper_memory_select" with
    | Some descriptor -> descriptor | None -> fail "selection descriptor missing" in
  check bool "actual registered selection handler" true
    (descriptor.runtime_handler=Masc.Keeper_tool_descriptor.Tool_memory_select);
  let verify query output =
    check (list string) "no request was rewritten or unmatched" [] (List.rev !errors);
    let expected=List.map (jstring "request_body_sha256") (rows "requests" query) in
    check (list string) "actual tool replays exact captured Jev requests" expected (List.map sha (List.rev !bodies));
    check bool "recorded complete judgment returns complete selection" false (member "incomplete" output |> Json.to_bool);
    let request=List.hd (rows "requests" query) in
    let _,_,raw=Hashtbl.find answers (jstring "request_body_sha256" request) in
    let judgments=member "answers" (Yojson.Safe.from_string raw) |> Json.to_assoc in
    let chosen=List.filter (fun (_,answer) -> match jstring "choice" answer with
      | "current_decision" | "comparison" -> true | _ -> false) judgments in
    check (list string) "all actual selected identities reach compact result"
      (List.map fst chosen |> List.sort String.compare)
      (rows "selected" output |> List.map (jstring "id") |> List.sort String.compare);
    List.iter (fun selected -> check string "compact result retains exact use label"
      (jstring "choice" (List.assoc (jstring "id" selected) judgments)) (jstring "use" selected)) (rows "selected" output);
    let current_claims=rows "candidates" (member "state" (List.hd (rows "requests" query)))
      |> List.map (fun row -> jstring "claim" (member "current_fact" (member "source_detail" row))) in
    let historical=rows "candidates" (member "state" (List.hd (rows "requests" query)))
      |> List.concat_map (fun row -> let detail=member "source_detail" row in
        rows "direct_admission_witnesses" detail @ rows "successor_witnesses" detail)
      |> List.map (fun row -> jstring "claim" (member "historical_source" row))
      |> List.filter (fun claim -> not (List.mem claim current_claims)) in
    let output_bytes=Yojson.Safe.to_string output in
    List.iter (fun claim -> check bool "absorbed historical bodies are not reinjected" false
      (Astring.String.is_infix ~affix:claim output_bytes)) historical;
    List.iter (fun (_,path,bytes) -> check (option string) "memory stores remain unchanged" bytes
      (Fs_compat.load_file_opt path)) stores;
    output in
  let measurements=if not provider_wire then List.map (fun query ->
    bodies:=[];
    let result=match Dispatch.handle context ~descriptor ~args:(member "tool_args" query) with
      | Some execution -> Yojson.Safe.from_string execution.raw_output | None -> fail "dispatch unavailable" in
    `Assoc ["query_id",member "query_id" query;"response",verify query result]) source_queries
  else (
    let query=List.hd source_queries in
    let turn_cell=Masc.Keeper_tool_call_log.create_turn_ctx_cell () in
    Masc.Keeper_tool_call_log.set_turn_context ~cell:turn_cell ~trace_id
      ~keeper_turn_id:(member "absolute_turn" original |> Json.to_int) ();
    let bundle=Masc.Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
      ~config ~meta ~publication_recovery:context.publication_recovery ~ctx_snapshot:context.ctx_work
      ~turn_ctx_cell:turn_cell () in
    Fun.protect ~finally:bundle.cleanup @@ fun () ->
    let provider_bodies=ref [] in
    let answer message finish=Yojson.Safe.to_string (`Assoc ["id",`String "selection-wire";"model",`String "fixture";
      "choices",`List [`Assoc ["index",`Int 0;"message",message;"finish_reason",`String finish]];
      "usage",`Assoc ["prompt_tokens",`Int 1;"completion_tokens",`Int 1;"total_tokens",`Int 2]]) in
    let initial=answer (`Assoc ["role",`String "assistant";"content",`Null;
      "tool_calls",`List [`Assoc ["id",`String "select-memory";"type",`String "function";
        "function",`Assoc ["name",`String "keeper_memory_select";
          "arguments",`String (Yojson.Safe.to_string (member "tool_args" query))]]]]) "tool_calls" in
    let finished=answer (`Assoc ["role",`String "assistant";"content",`String "Selection inspected."]) "stop" in
    let provider=Fixture.start_server ~sw ~net ~clock (Fixture.Reply_with (fun index body ->
      provider_bodies:=body :: !provider_bodies;
      if index=0 then `OK,initial else if index=1 then `OK,finished else `Bad_request,"unexpected extra provider request")) in
    let provider_cfg=Llm_provider.Provider_config.make ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"fixture" ~base_url:provider.base_url ~api_key:"synthetic-local-key"
      ~request_path:"/chat/completions" ~tool_stream:false () in
    let runtime_config=Runtime_agent.default_config ~name:"selection-wire" ~provider_cfg
      ~system_prompt:meta.instructions ~tools:bundle.tools in
    (match Runtime_agent.run_blocks ~sw ~net ~config:runtime_config
      [Agent_core.Types.Text (jstring "query" query)] with
     | Ok {Runtime_agent.stop_reason=Runtime_agent.Completed;response;_} ->
       check bool "runtime consumes the expected final provider answer" true
         (List.exists (function Agent_core.Types.Text text -> text="Selection inspected." | _ -> false) response.content)
     | Ok _ -> fail "provider wire run did not complete normally"
     | Error error -> failf "provider wire run failed: %s" (Agent_core.Error.to_string error));
    check (list string) "exact captured Jev input through real Keeper bundle" [] (List.rev !errors);
    let first,second=match List.rev !provider_bodies with [first;second] ->
      Yojson.Safe.from_string first,Yojson.Safe.from_string second
      | _ -> fail "expected initial provider tool call and one followup provider request" in
    check bool "first provider request actually offers selection capability" true
      (List.exists (fun tool -> member "name" (member "function" tool)=`String "keeper_memory_select") (rows "tools" first));
    let tool_messages=rows "messages" second |> List.filter (fun message -> member "role" message=`String "tool") in
    let content=match tool_messages with [message] -> jstring "content" message
      | _ -> fail "second provider request must carry one tool result" in
    let output=Yojson.Safe.from_string content |> verify query in
    let journal=Filename.concat (Filename.concat (Masc.Workspace.keepers_runtime_dir config) keeper_id)
      "memory-selection-evaluations.jsonl" in
    let retained=Fs_compat.load_file journal |> String.split_on_char '\n'
      |> List.filter (fun line -> String.trim line<>"") |> List.map Yojson.Safe.from_string
      |> List.filter (fun row -> member "status" row=`String "selection_completed"
          && member "selection_id" row=member "selection_id" output) in
    (match retained with
     | [row] -> check bool "provider tool message equals the durably retained final projection" true
         (member "result" (member "outcome" row)=output)
     | _ -> fail "wire selection has no unique retained projection receipt");
    let request=List.hd (rows "requests" query) in
    let _,_,raw=Hashtbl.find answers (jstring "request_body_sha256" request) in
    let judgments=member "answers" (Yojson.Safe.from_string raw) in
    List.iter (fun selected ->
      let id=jstring "id" selected in
      check string "provider sees exact model-selected semantic role"
        (jstring "choice" (member id judgments)) (jstring "use" selected);
      let fact=member "current_fact" (member "current" selected) in
      let restored=match Masc.Keeper_memory_os_types.fact_of_json fact with
        | Ok fact -> fact | Error _ -> fail "provider current fact shape invalid" in
      check string "provider current identity belongs to delivered claim" id (Masc.Keeper_memory_os_types.memory_id restored))
      (rows "selected" output);
    [`Assoc ["query_id",member "query_id" query;"provider_followup_request",second;"response",output]]) in
  Printf.printf "MEMORY_SELECT_TOOL_REPLAY %s\n%!" (Yojson.Safe.to_string (`Assoc
    ["boundary",`String "adopted_genealogy_actual_tool_and_provider_wire";
     "response_repetition",`Int 1;"provider_wire",`Bool provider_wire;"network_scope",`String "local_recorded_http_only";
     "results",`List measurements]))
let () = run "memory selection tool and provider wire replay"
  ["actual recorded responses",[
    test_case "eleven adopted purposes traverse real descriptor dispatch" `Quick (replay ~provider_wire:false);
    test_case "real Keeper bundle preserves compact roles in next provider request" `Quick (replay ~provider_wire:true)]]
