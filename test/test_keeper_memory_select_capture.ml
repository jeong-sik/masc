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

let capture () =
  let fixture=Masc_test_deps.source_path "test/fixtures/memory_resolved_selection_replay/actual.json" in
  let fixture_bytes=Fs_compat.load_file fixture in
  let original=member "capture" (Yojson.Safe.from_string fixture_bytes) in
  let source_queries=rows "queries" original in
  check int "frozen experiment contains seven purposes" 7 (List.length source_queries);
  check int "frozen purposes have seven distinct query identities" 7
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
  let authoritative=Current.read_successor_recall_for_keepers_dir ~keepers_dir ~keeper_id |> require in
  let facts=match authoritative.snapshot with Some snapshot -> snapshot.Current.facts
    | None -> fail "source fixture current snapshot missing" in
  let current_ids=List.map Masc.Keeper_memory_os_types.memory_id facts in
  check int "source scenario contains three current identities" 3 (List.length current_ids);
  let instructions=jstring "keeper_instructions" (member "experiment_provenance" original) in
  let meta=Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String keeper_id;
    "trace_id",`String trace_id;"instructions",`String instructions]) |> require in
  let turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:(member "absolute_turn" original |> Json.to_int) in
  let bodies=ref [] in
  let server=Fixture.start_server ~sw ~net ~clock (Fixture.Reply_with (fun _ body ->
    bodies:=body :: !bodies; `Service_unavailable,"capture only; no model judgment")) in
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
  let exports=List.map (fun query ->
    bodies:=[];
    let args=`Assoc ["purpose",member "query" query] in
    let result=match Dispatch.handle context ~descriptor ~args with
      | Some execution -> Yojson.Safe.from_string execution.raw_output
      | None -> fail "production dispatch did not handle selection" in
    check int "unavailable capture cannot select" 0 (List.length (rows "selected" result));
    check int "unavailable capture cannot omit" 0 (member "not_needed_count" result |> Json.to_int);
    check bool "provider refusal preserves incomplete retrieval" true (member "incomplete" result |> Json.to_bool);
    check int "each assessed current candidate stays deferred" (member "assessed_count" result |> Json.to_int)
      (List.length (rows "deferred" result));
    check bool "unavailable capture does not assert no-match" false (member "no_match" result=`Bool true);
    let requests=List.mapi (fun index body ->
      let decoded=Yojson.Safe.from_string body in
      let state=member "state" decoded and questions=member "questions" decoded in
      let purpose=member "current_purpose" state in
      check string "HTTP purpose preserves requested query" (jstring "query" query) (jstring "current_input" purpose);
      check string "HTTP purpose preserves frozen Keeper instructions" meta.instructions (jstring "keeper_instructions" purpose);
      check bool "HTTP purpose preserves exact turn identity" true
        (member "turn_ref" purpose=Ids.Turn_ref.to_yojson turn_ref);
      let candidates=rows "candidates" state in
      check (list string) "all current identities reach the model once"
        (List.sort String.compare current_ids)
        (List.sort String.compare (List.map (fun row -> jstring "id" (member "candidate" row)) candidates));
      let witnesses=List.fold_left (fun count row ->
        let detail=member "source_detail" row in
        let id=jstring "id" (member "candidate" row) in
        let fact=List.find (fun fact -> Masc.Keeper_memory_os_types.memory_id fact=id) facts in
        check bool "HTTP current fact matches authoritative source" true
          (member "current_fact" detail=Masc.Keeper_memory_os_types.fact_to_json fact);
        let direct=rows "direct_admission_witnesses" detail and successor=rows "successor_witnesses" detail in
        List.iter (fun witness -> check bool "historical source body belongs to authoritative direct binding" true
          (List.exists (fun (binding : Current.admission_recall_binding) ->
            binding.target_memory_id=id && binding.candidate_id.request_id=jstring "request_id" witness
            && Masc.Keeper_memory_os_types.fact_to_json binding.source_fact=member "historical_source" witness)
            authoritative.direct_bindings)) direct;
        List.iter (fun witness -> check bool "full successor witness matches authoritative lineage" true
          (List.exists (fun (candidate : Current.successor_recall_candidate) ->
            Masc.Keeper_memory_os_types.memory_id candidate.target=id &&
            Masc.Keeper_memory_successor_selection.candidate_to_json candidate=witness)
            authoritative.successor_candidates)) successor;
        count+List.length direct+List.length successor) 0 candidates in
      check int "all five authoritative witnesses reach the evaluator" 5 witnesses;
      check string "actual HTTP model" "jev-latest" (jstring "model" decoded);
      `Assoc ["request_index",`Int index;"model",member "model" decoded;
        "request_body",`String body;"request_body_sha256",`String (sha body);
        "state",state;"questions",questions;"state_sha256",`String (sha (Yojson.Safe.to_string state));
        "questions_sha256",`String (sha (Yojson.Safe.to_string questions))]) (List.rev !bodies) in
    check int "one production full-detail request per purpose" 1 (List.length requests);
    List.iter (fun (name,path,bytes) -> check (option string) (name ^ " unchanged by unavailable tool capture")
      bytes (Fs_compat.load_file_opt path)) stores;
    `Assoc ["query_id",member "query_id" query;"query",member "query" query;"tool_args",args;
      "matched_candidate_count",member "assessed_count" result;
      "requests",`List requests;"capture_tool_result",result]) source_queries in
  check int "all purposes reached actual local HTTP" (List.length exports) (Fixture.post_count server);
  Printf.printf "MEMORY_SELECT_TOOL_EXPORT %s\n%!" (Yojson.Safe.to_string (`Assoc
    ["measurement",`String "production_memory_select_descriptor_dispatch_capture";
     "semantic_judgment_performed",`Bool false;"network_scope",`String "local_http_503_capture_only";
     "captured_at",`Float (Time_compat.now ());"keeper_id",`String keeper_id;"trace_id",`String trace_id;
     "absolute_turn",member "absolute_turn" original;"keeper_instructions",`String meta.instructions;
     "source_fixture",`String "memory_resolved_selection_replay/actual.json";
     "source_fixture_sha256",`String (sha fixture_bytes);"source_provenance",member "experiment_provenance" original;
     "state_bundle",bundle;"state_bundle_sha256",`String (sha (Yojson.Safe.to_string bundle));
     "queries",`List exports]))
let () = run "actual memory selection tool request capture"
  ["descriptor dispatch",[test_case "seven purposes capture actual HTTP without semantic decisions" `Quick capture]]
