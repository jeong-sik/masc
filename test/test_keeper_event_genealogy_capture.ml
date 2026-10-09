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
module Memory = Masc.Keeper_memory_os_types
let () = Masc.Prompt_defaults.init ()
let replace_field key value = function
  | `Assoc fields -> `Assoc (List.map (fun (name,old) -> name,if name=key then value else old) fields)
  | _ -> fail "object required"
let replace_once ~before ~after text =
  let n=String.length before in
  let rec find i =
    if i+n>String.length text then None
    else if String.sub text i n=before then Some i else find (i+1) in
  match find 0 with
  | None -> fail "declared experimental prompt span missing"
  | Some i ->
    check bool "declared span occurs exactly once" true (find (i+n)=None);
    String.sub text 0 i ^ after ^ String.sub text (i+n) (String.length text-i-n)
let experimental_request scenario request =
  let body=Yojson.Safe.from_string (jstring "request_body" request) in
  let spans=rows "experimental_spans" scenario in
  check int "only two declared prompt spans" 2 (List.length spans);
  let description=List.nth spans 0 and instruction=List.nth spans 1 in
  let questions=member "questions" body |> Json.to_assoc |> List.map (fun (id,question) ->
    let criteria=member "criteria" question in
    let current=jstring "comparison" criteria in
    check string "comparison description matches frozen baseline" (jstring "before" description) current;
    let question=replace_field "criteria"
      (replace_field "comparison" (member "after" description) criteria) question in
    id,replace_field "instructions" (`String (replace_once
      ~before:(jstring "before" instruction) ~after:(jstring "after" instruction)
      (jstring "instructions" question))) question) |> fun fields -> `Assoc fields in
  let body=replace_field "questions" questions body in
  let raw=Yojson.Safe.to_string body in
  request |> replace_field "request_body" (`String raw)
    |> replace_field "request_body_sha256" (`String (sha raw))
    |> replace_field "questions" questions
    |> replace_field "questions_sha256" (`String (sha (Yojson.Safe.to_string questions)))

let author ~scenario ~config ~meta ~keepers_dir ~keeper_id ~trace_id =
  let now=Time_compat.now () in
  let fact claim=Memory.observed ~claim ~category:Memory.Fact ~now ~origin:{kind=Memory.Authored;trace_id} in
  let authored=rows "facts" scenario in
  check (list string) "six frozen aliases" ["A";"B";"C";"D";"E";"F"] (List.map (jstring "alias") authored);
  let final=List.map (fun row -> fact (jstring "claim" row)) authored in
  let old=fact (jstring "old_a" scenario) and renamed=fact (jstring "renamed_a" scenario) in
  let initial=old :: List.tl final in
  List.iter (fun (target:Memory.fact) ->
    let result=Masc.Keeper_tool_memory_runtime.keeper_memory_write_with_outcome
      ~config ~meta ~args:(`Assoc ["content",`String target.claim]) in
    check string "real producer queues admission" "persisted_pending_admission"
      (jstring "outcome" (Yojson.Safe.from_string result.raw_output))) initial;
  let batch=match Queue.read_pending ~keepers_dir ~keeper_id |> require with
    | Some batch -> batch | None -> fail "pending input missing" in
  let ids=Queue.candidate_ids batch and candidates=Queue.candidates batch in
  check (list string) "queue preserves authored source claims"
    (List.map (fun (fact:Memory.fact) -> fact.claim) initial)
    (List.map (fun (candidate:Queue.candidate) -> candidate.fact.claim) candidates);
  let bindings=List.map2 (fun (candidate,candidate_id) target ->
    {Current.candidate_id;source_fact=candidate.Queue.fact;target_memory_id=Memory.memory_id target})
    (List.combine candidates ids) initial in
  let source={Current.kind=Current.Librarian;trace_id} in
  ignore(Current.apply_disposition ~keepers_dir ~keeper_id ~now ~source
    ~explicit_candidate_ids:ids
    ~admission_recall:{Current.decided_at_revision=None; bindings}
    ~absorbed:[] ~revisions:[] ~new_claims:initial () |> require : Current.disposition);
  Queue.acknowledge_committed ~keepers_dir ~keeper_id |> require;
  let revise old target reason =
    ignore(Current.apply_disposition ~keepers_dir ~keeper_id ~now:(Time_compat.now ()) ~source
      ~dropped_statements:[{Memory.memory_id=Memory.memory_id old;reason}]
      ~absorbed:[] ~revisions:[{Memory.superseded=Memory.memory_id old;superseded_by=Memory.memory_id target}]
      ~new_claims:[target] () |> require : Current.disposition) in
  revise old renamed "Authored evidence: W31 renamed NORTH-REPAIR, same event and unchanged production rule.";
  revise renamed (List.hd final) "Authored evidence: Mina replaces only W31 production restart condition; test branch and notification remain separate current facts.";
  check bool "all authored observations acknowledged" true ((Queue.read_pending ~keepers_dir ~keeper_id |> require)=None);
  final

let capture () =
  let fixture=Masc_test_deps.source_path "test/fixtures/event_genealogy_selection/scenario.json" in
  let fixture_bytes=Fs_compat.load_file fixture in
  let original=Yojson.Safe.from_string fixture_bytes in
  let source_queries=rows "queries" original in
  check int "frozen experiment contains eleven purposes" 11 (List.length source_queries);
  check int "frozen purposes have eleven distinct query identities" 11
    (List.length (List.sort_uniq String.compare (List.map (jstring "query_id") source_queries)));
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
  let instructions=jstring "keeper_instructions" original in
  let meta=Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String keeper_id;
    "trace_id",`String trace_id;"instructions",`String instructions]) |> require in
  let expected=Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled=false;absorb_gate=false}
    (fun () -> author ~scenario:original ~config ~meta ~keepers_dir ~keeper_id ~trace_id) in
  let stores=List.map (fun (name,path) -> name,path,Fs_compat.load_file_opt path)
    ["current_snapshot",Current.path_for_keepers_dir ~keepers_dir ~keeper_id;
     "consumption_and_lookup_receipt",Current.durable_range_receipt_path ~keepers_dir ~keeper_id;
     "memory_journal",Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id;
     "pending_queue",Queue.path ~keepers_dir ~keeper_id] in
  let bundle=`Assoc (List.map (fun (name,_,bytes) -> name,match bytes with
    | None -> `Assoc ["present",`Bool false]
    | Some bytes -> `Assoc ["present",`Bool true;"bytes",`String bytes;"sha256",`String (sha bytes)]) stores) in
  let authoritative=Current.read_successor_recall_for_keepers_dir ~keepers_dir ~keeper_id |> require in
  let facts=match authoritative.snapshot with Some snapshot -> snapshot.Current.facts
    | None -> fail "authored snapshot missing" in
  let current_ids=List.map Memory.memory_id facts in
  List.iter (fun (fact:Memory.fact) -> check bool "historical alias absent from all current facts" false
    (String_util.contains_substring fact.claim "OLD-P4-STOP")) facts;
  check (list string) "exactly six authored current identities, no retired candidates"
    (List.map Memory.memory_id expected |> List.sort String.compare) (List.sort String.compare current_ids);
  check int "five unrelated-to-replacement bindings remain direct" 5 (List.length authoritative.direct_bindings);
  check int "only A carries retired history" 1 (List.length authoritative.successor_candidates);
  check int "no missing lineage" 0 (List.length authoritative.unresolved);
  List.iter (fun (candidate:Current.successor_recall_candidate) ->
    check string "only A receives successor witness" (Memory.memory_id (List.hd expected)) (Memory.memory_id candidate.target);
    check int "rename then replacement are two transitions" 2 (List.length candidate.path);
    check string "historical alias source preserved exactly" (jstring "old_a" original) candidate.binding.source_fact.claim;
    check bool "original source carries historical-only alias" true
      (String_util.contains_substring candidate.binding.source_fact.claim "OLD-P4-STOP"))
    authoritative.successor_candidates;
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
      check (list string) "question identities match all current candidates"
        (List.sort String.compare current_ids)
        (Json.to_assoc questions |> List.map fst |> List.sort String.compare);
      List.iter (fun row -> check bool "historical alias absent from current candidate summary" false
        (String_util.contains_substring (jstring "summary" (member "candidate" row)) "OLD-P4-STOP")) candidates;
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
      check int "all six authoritative witnesses reach the evaluator" 6 witnesses;
      check string "actual HTTP model" "jev-latest" (jstring "model" decoded);
      `Assoc ["request_index",`Int index;"model",member "model" decoded;
        "request_body",`String body;"request_body_sha256",`String (sha body);
        "state",state;"questions",questions;"state_sha256",`String (sha (Yojson.Safe.to_string state));
        "questions_sha256",`String (sha (Yojson.Safe.to_string questions))]) (List.rev !bodies) in
    check int "one production full-detail request per purpose" 1 (List.length requests);
    List.iter (fun (name,path,bytes) -> check (option string) (name ^ " unchanged by unavailable tool capture")
      bytes (Fs_compat.load_file_opt path)) stores;
    let experimental=List.map (experimental_request original) requests in
    `Assoc ["experimental_requests",`List experimental;"query_id",member "query_id" query;"query",member "query" query;"tool_args",args;
      "matched_candidate_count",member "assessed_count" result;
      "requests",`List requests;"capture_tool_result",result]) source_queries in
  check int "all purposes reached actual local HTTP" (List.length exports) (Fixture.post_count server);
  Printf.printf "MEMORY_EVENT_GENEALOGY_EXPORT %s\n%!" (Yojson.Safe.to_string (`Assoc
    ["measurement",`String "production_event_genealogy_descriptor_dispatch_capture";
     "semantic_judgment_performed",`Bool false;"network_scope",`String "local_http_503_capture_only";
     "captured_at",`Float (Time_compat.now ());"keeper_id",`String keeper_id;"trace_id",`String trace_id;
     "absolute_turn",member "absolute_turn" original;"keeper_instructions",`String meta.instructions;
     "source_fixture",`String "event_genealogy_selection/scenario.json";
     "source_fixture_sha256",`String (sha fixture_bytes);"source_provenance",member "experiment_provenance" original;
     "state_bundle",bundle;"state_bundle_sha256",`String (sha (Yojson.Safe.to_string bundle));
     "queries",`List exports]))
let () = run "actual memory selection tool request capture"
  ["descriptor dispatch",[test_case "eleven new event purposes capture actual HTTP without semantic decisions" `Quick capture]]
