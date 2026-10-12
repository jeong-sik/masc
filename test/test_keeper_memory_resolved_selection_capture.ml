open Alcotest
module Current = Masc.Keeper_memory_os_current
module Memory = Masc.Keeper_memory_os_types
module Queue = Masc.Keeper_memory_admission_queue
module Selection = Masc.Keeper_workspace_memory_selection
let require = function Ok value -> value | Error detail -> fail detail
let member = Yojson.Safe.Util.member
module Json = Yojson.Safe.Util
let jstring name json = member name json |> Json.to_string
let sha bytes = Digestif.SHA256.(digest_string bytes |> to_hex)
let hash_json json = sha (Yojson.Safe.to_string json)
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

(* Full-detail selection over three resolved current identities. This captures
   an experimental core API, not production tool integration or model-generated
   event genealogy. No lexical shortlist, route-level judge or pre-limit runs. *)
let capture () =
  let fixture_path=Masc_test_deps.source_path "test/fixtures/memory_successor_http_replay/event-branches.json" in
  let fixture_bytes=Fs_compat.load_file fixture_path in
  let envelope=Yojson.Safe.from_string fixture_bytes in
  let original=member "capture" envelope in
  let bundle=member "state_bundle" original in
  check string "original captured state hash" (jstring "state_bundle_sha256" original) (hash_json bundle);
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
  let base_path=Filename.temp_dir "resolved-selection-capture-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some (Filename.concat base_path "config")) @@ fun () ->
  Config_dir_resolver.reset ();
  Fun.protect ~finally:Config_dir_resolver.reset @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled=false;absorb_gate=false} @@ fun () ->
  let keeper_id=jstring "keeper_id" original |> Keeper_id.Keeper_name.of_string |> require |> Keeper_id.Keeper_name.to_string in
  let trace_id=jstring "trace_id" original |> Keeper_id.Trace_id.of_string |> require |> Keeper_id.Trace_id.to_string in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let stores=restore ~keepers_dir ~keeper_id bundle in
  let resolved=Current.read_successor_recall_for_keepers_dir ~keepers_dir ~keeper_id |> require in
  let snapshot=match resolved.snapshot with Some snapshot -> snapshot | None -> fail "resolved snapshot missing" in
  let binding_json (binding : Current.admission_recall_binding) =
    let id=binding.candidate_id in
    `Assoc ["candidate_id",`Assoc ["queue_generation",`String id.queue_generation;
      "request_id",`String id.request_id;"sequence",`Int id.sequence;"input_sha256",`String id.input_sha256];
      "source_fact",Memory.fact_to_json binding.source_fact;"target_memory_id",`String binding.target_memory_id] in
  let grouped=List.map (fun (fact : Memory.fact) ->
    let id=Memory.memory_id fact in
    let direct=List.filter (fun (binding : Current.admission_recall_binding) -> binding.target_memory_id=id)
      resolved.direct_bindings in
    let successor=List.filter (fun (candidate : Current.successor_recall_candidate) -> Memory.memory_id candidate.target=id)
      resolved.successor_candidates in
    let detail=`Assoc ["kind",`String "resolved_current_memory_with_all_lookup_provenance";
      "current_memory_id",`String id;"current_fact",Memory.fact_to_json fact;
      "snapshot_revision",`Int snapshot.revision;
      "direct_admission_witnesses",`List (List.map binding_json direct);
      "successor_witnesses",`List (List.map (fun (candidate : Current.successor_recall_candidate) ->
        `Assoc ["binding",binding_json candidate.binding;
          "lineage",Masc.Keeper_memory_successor_selection.candidate_to_json candidate]) successor);
      "provenance_guidance",`String "Historical observations and paths are lookup provenance, not separate current claims. Assess the current identity once with every supplied witness."] in
    ({Selection.id;summary=fact.claim},detail)) snapshot.facts in
  check int "all three current identities are assessed exactly once" 3 (List.length grouped);
  check int "grouping cannot duplicate a target identity" (List.length grouped)
    (List.length (List.sort_uniq String.compare (List.map (fun ((candidate : Selection.candidate),_) -> candidate.id) grouped)));
  let count field=List.fold_left (fun n (_,detail) -> n + List.length (member field detail |> Json.to_list)) 0 grouped in
  check int "all direct witnesses survive grouping" (List.length resolved.direct_bindings) (count "direct_admission_witnesses");
  check int "all branch and chain witnesses survive grouping" (List.length resolved.successor_candidates) (count "successor_witnesses");
  check int "source fixture has no unresolved lineage gaps" 0 (List.length resolved.unresolved);
  let original_queries=member "queries" original |> Json.to_list |> List.map (jstring "query") in
  let queries=original_queries @ [
    "Compare Event E18 production R-015 release-manager approval with Event E17 production R-015 two-independent-approval policy; keep each event's policy separate.";
    "What approval policy currently applies to Event E99 production R-015? No evidence identifies E99 with E17 or E18."] in
  let keeper_instructions="Select useful memory for the user's current request. Keep current-event evidence distinct from comparison material, and expose uncertainty without inventing missing facts." in
  let request_context="Synthetic memory-selection experiment over authored E17/E18 release-policy history. This context supplies no authority to equate events or environments." in
  let turn_ref=Ids.Turn_ref.make ~trace_id
    ~absolute_turn:(member "absolute_turn" original |> Json.to_int) in
  let exports=List.mapi (fun index query ->
    let purpose=`Assoc ["current_input",`String query;"request_context",`String request_context;
      "keeper_instructions",`String keeper_instructions;"turn_ref",Ids.Turn_ref.to_yojson turn_ref] in
    let requests=ref [] in
    let evaluate ~state ~questions =
      let body=Masc.Typesafeai_types.request_to_yojson ~model:"jev-latest" ~state ~questions |> Yojson.Safe.to_string in
      let questions=`Assoc (List.map (fun (id,question) -> id,Masc.Typesafeai_types.question_to_yojson question) questions) in
      requests:=`Assoc ["request_index",`Int (List.length !requests);"model",`String "jev-latest";
        "request_body",`String body;"request_body_sha256",`String (sha body);
        "state",state;"questions",questions;"state_sha256",`String (hash_json state);
        "questions_sha256",`String (hash_json questions)] :: !requests;
      Error (Selection.Unavailable "capture only; no semantic judgment") in
    let outcomes=Selection.select_resolved_many ~evaluate ~purpose grouped in
    check int "all current identities receive an outcome" (List.length grouped) (List.length outcomes);
    List.iter (function Selection.Deferred _ -> () | Selected _ | Not_needed _ ->
      fail "capture-only unavailability became a semantic decision") outcomes;
    check int "one full-detail batch without prior route judgments" 1 (List.length !requests);
    `Assoc ["query_id",`String (Printf.sprintf "query-%03d" (index+1));"query",`String query;
      "current_purpose",purpose;"matched_candidate_count",`Int (List.length grouped);
      "requests",`List (List.rev !requests)]) queries in
  List.iter (fun (name,path,bytes) -> check (option string) (name ^ " unchanged by selection capture")
    bytes (Fs_compat.load_file_opt path)) stores;
  let provenance=`Assoc ["selection_scope",`String "already_resolved_current_memory_identities";
    "production_tool_integration",`Bool false;"generative_librarian",`Bool false;
    "prior_route_judgment",`Bool false;"lexical_prefilter",`Bool false;"pre_limit",`Bool false;
    "source_detail_scope",`String "Observed current facts and committed admission/revision provenance; no filesystem-bound source claims in this scenario.";
    "keeper_instructions",`String keeper_instructions;"request_context",`String request_context;
    "source_scenario",member "scenario_provenance" original] in
  Printf.printf "MEMORY_RESOLVED_SELECTION_EXPORT %s\n%!" (Yojson.Safe.to_string (`Assoc
    ["measurement",`String "resolved_full_detail_selection_core_capture";"semantic_judgment_performed",`Bool false;
     "captured_at",`Float (Time_compat.now ());"keeper_id",`String keeper_id;"trace_id",`String trace_id;
     "absolute_turn",member "absolute_turn" original;"source_fixture",`String "event-branches.json";
     "source_fixture_sha256",`String (sha fixture_bytes);"source_capture_sha256",`String (hash_json original);
     "experiment_provenance",provenance;"state_bundle",bundle;"state_bundle_sha256",`String (hash_json bundle);
     "queries",`List exports]))
let () = run "resolved full-detail memory selection capture"
  ["current identities",[test_case "capture all current identities and grouped provenance for seven purposes" `Quick capture]]
