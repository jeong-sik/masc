open Alcotest
module Current = Masc.Keeper_memory_os_current
module Queue = Masc.Keeper_memory_admission_queue
module Types = Masc.Typesafeai_types
module Selection = Masc.Keeper_workspace_memory_selection
module Io = Masc.Keeper_workspace_memory_selection_io
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

(* Old recorded responses are replayed against their exact historical question
   contract. Assert the current generator differs by only the adopted spans. *)
let captured_questions request =
  member "questions" request |> Json.to_assoc |> List.map (fun (id,row) ->
    id,Types.Choice {instructions=jstring "instructions" row;
      criteria=member "criteria" row |> Json.to_assoc |> List.map (fun (label,value) ->
        label,(match value with `String text -> Some text | `Null -> None | _ -> fail "invalid criterion"))})
let adopted_questions spans questions =
  let description=List.nth spans 0 and instruction=List.nth spans 1 in
  List.map (fun (id,question) -> match question with
    | Types.Choice {instructions;criteria} ->
      let instructions=match Astring.String.cuts ~sep:(jstring "before" instruction) instructions with
        | [before;after] -> before ^ jstring "after" instruction ^ after
        | _ -> fail "historical instruction span must occur once" in
      let criteria=List.map (fun (label,value) ->
        if label<>"comparison" then label,value else (
          check (option string) "historical comparison span" (Some (jstring "before" description)) value;
          label,Some (jstring "after" description))) criteria in
      id,Types.Choice {instructions;criteria}
    | Types.Score _ | Types.Noul _ -> fail "expected choice question") questions

let replay ~enabled () =
  let envelope=Yojson.Safe.from_file (Masc_test_deps.source_path "test/fixtures/memory_resolved_selection_replay/actual.json") in
  let capture=member "capture" envelope in
  let spans=Yojson.Safe.from_file (Masc_test_deps.source_path "test/fixtures/event_genealogy_selection/scenario.json")
    |> rows "experimental_spans" in
  check int "only the frozen two-span bundle is adopted" 2 (List.length spans);
  let responses=Hashtbl.create 8 in
  List.iter (fun row ->
    let body=jstring "request_body" row and response=jstring "response_raw" row in
    let hash=jstring "request_sha256" row in
    check string "request digest" hash (sha body);
    check string "actual response digest" (jstring "response_sha256" row) (sha response);
    check bool "unique request record" false (Hashtbl.mem responses hash);
    Hashtbl.add responses hash (body,member "status" row |> Json.to_int,response)) (rows "model_responses" envelope);
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let net=Eio.Stdenv.net env and clock=Eio.Stdenv.clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  let base_path=Filename.temp_dir "resolved-selection-http-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some (Filename.concat base_path "config")) @@ fun () ->
  Config_dir_resolver.reset ();
  Fun.protect ~finally:Config_dir_resolver.reset @@ fun () ->
  let keeper_id=jstring "keeper_id" capture |> Keeper_id.Keeper_name.of_string |> require |> Keeper_id.Keeper_name.to_string in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let bundle=member "state_bundle" capture in
  check string "state bundle digest" (jstring "state_bundle_sha256" capture) (sha (Yojson.Safe.to_string bundle));
  let stores=restore ~keepers_dir ~keeper_id bundle in
  let snapshot=Current.read_successor_recall_for_keepers_dir ~keepers_dir ~keeper_id |> require in
  let facts=match snapshot.snapshot with Some snapshot -> snapshot.Current.facts | None -> fail "current snapshot missing" in
  let errors=ref [] and observed=ref [] in
  let server=Fixture.start_server ~sw ~net ~clock (Fixture.Reply_with (fun _ body ->
    let hash=sha body in observed:=hash :: !observed;
    match Hashtbl.find_opt responses hash with
    | Some (expected,status,response) when expected=body -> Cohttp.Code.status_of_code status,response
    | _ -> errors:=hash :: !errors; `Bad_request,"unexpected request bytes")) in
  let config=Masc.Workspace.default_config base_path and key="MASC_TEST_RESOLVED_REPLAY_KEY" in
  Masc_test_deps.with_process_env key (Some "synthetic-local-key") @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled=enabled;excluded_keepers=[];workspace_memory_selection_enabled=true;
     destinations=({Runtime_schema.endpoint=server.base_url;model="jev-latest";api_key_env=key},[])} @@ fun () ->
  let measurements=List.map (fun query ->
    let request=match rows "requests" query with [request] -> request | _ -> fail "expected one full-detail request" in
    let body=jstring "request_body" request in
    check string "capture request digest" (jstring "request_body_sha256" request) (sha body);
    let decoded=Yojson.Safe.from_string body in
    List.iter (fun key -> check bool "captured request fields agree" true
      (Yojson.Safe.equal (member key decoded) (member key request))) ["state";"questions"];
    let state=member "state" request in
    let candidates=List.map (fun row ->
      let json=member "candidate" row in
      let candidate : Selection.candidate={id=jstring "id" json;summary=jstring "summary" json} in
      let detail=member "source_detail" row in
      check bool "captured current fact exists exactly in restored snapshot" true
        (List.exists (fun fact -> Masc.Keeper_memory_os_types.memory_id fact=candidate.id
          && Masc.Keeper_memory_os_types.fact_to_json fact=member "current_fact" detail) facts);
      candidate,detail) (rows "candidates" state) in
    check int "all current identities represented without duplicates" (List.length facts)
      (List.length (List.sort_uniq String.compare (List.map (fun ((c : Selection.candidate),_) -> c.id) candidates)));
    let io=match Masc.Typesafeai_config.workspace_memory_selection_destinations ~keeper_id with
      | Error reason -> Error (Masc.Typesafeai_config.unavailable_reason_to_string reason)
      | Ok destinations -> Ok (Io.create ~config ~keeper_id ~destinations) in
    let historical=captured_questions request in
    let evaluate ~state:actual_state ~questions =
      check bool "current state equals historical source state" true (actual_state=state);
      check bool "current questions differ only by the frozen adopted spans" true
        (questions=adopted_questions spans historical);
      match io with
      | Ok io -> Io.evaluate io ~state:actual_state ~questions:historical
      | Error detail -> Error (Selection.Unavailable detail) in
    observed:=[];
    let outcomes=Selection.select_resolved_many ~evaluate ~purpose:(member "current_purpose" query) candidates in
    check (list string) "local server saw no unmatched requests" [] (List.rev !errors);
    check (list string) "exact captured request reaches HTTP when lane enabled"
      (if enabled then [sha body] else []) (List.rev !observed);
    let projected=List.map (function
      | Selection.Selected {candidate;use;source_detail} ->
        check bool "selected detail retains exact scoped provenance" true
          (List.exists (fun ((c : Selection.candidate),detail) -> c=candidate && detail=source_detail) candidates);
        `Assoc ["memory_id",`String candidate.id;"use",`String (match use with
          | Selection.For_current_decision -> "current_decision" | For_comparison -> "comparison");
          "source_detail",source_detail]
      | Selection.Not_needed candidate -> `Assoc ["memory_id",`String candidate.id;"use",`String "not_needed"]
      | Selection.Deferred {candidate;_} -> `Assoc ["memory_id",`String candidate.id;"use",`String "deferred"]) outcomes in
    if enabled then (
      let _,_,raw=Hashtbl.find responses (sha body) in
      let answers=member "answers" (Yojson.Safe.from_string raw) in
      List.iter (fun result ->
        let expected=jstring "choice" (member (jstring "memory_id" result) answers) in
        let expected=if expected="inspect_source" then "deferred" else expected in
        check string "production decoder preserves actual recorded use label"
          expected (jstring "use" result)) projected);
    if not enabled then List.iter (function Selection.Deferred _ -> () | _ -> fail "disabled lane manufactured selection") outcomes;
    (match io with
     | Error _ -> ()
     | Ok io -> Io.retain_result io ~purpose:(member "current_purpose" query)
         (Ok (`List projected)) |> require);
    `Assoc ["query_id",member "query_id" query;"query",member "query" query;"outcomes",`List projected]) (rows "queries" capture) in
  List.iter (fun (name,path,bytes) -> check (option string) (name ^ " unchanged") bytes (Fs_compat.load_file_opt path)) stores;
  let journal=Filename.concat (Filename.concat (Masc.Workspace.keepers_runtime_dir config) keeper_id) "memory-selection-evaluations.jsonl" in
  let logs=match Fs_compat.load_file_opt journal with None -> [] | Some data ->
    String.split_on_char '\n' data |> List.filter (fun line -> line<>"") |> List.map Yojson.Safe.from_string in
  let count status=List.length (List.filter (fun row -> member "status" row=`String status) logs) in
  check int "each POST has persisted input" (Fixture.post_count server) (count "started");
  check int "each POST has persisted response" (Fixture.post_count server) (count "response_received");
  check int "each enabled query retains its final projection"
    (if enabled then List.length (rows "queries" capture) else 0) (count "selection_completed");
  let outcomes=List.concat_map (rows "outcomes") measurements in
  let occurrences use=List.length (List.filter (fun row -> member "use" row=`String use) outcomes) in
  let counts=`Assoc ["unit",`String "candidate_occurrences_across_query_purposes";
    "total",`Int (List.length outcomes);"current_decision",`Int (occurrences "current_decision");
    "comparison",`Int (occurrences "comparison");"not_needed",`Int (occurrences "not_needed");
    "deferred",`Int (occurrences "deferred");
    "selected",`Int (occurrences "current_decision" + occurrences "comparison")] in
  Printf.printf "MEMORY_RESOLVED_SELECTION_REPLAY %s\n%!" (Yojson.Safe.to_string (`Assoc
    ["measurement",`String "historical_recorded_response_through_explicit_frozen_question_adapter";
     "production_tool_integration",`Bool false;"lane_enabled",`Bool enabled;
     "http_requests",`Int (Fixture.post_count server);"occurrence_counts",counts;"queries",`List measurements]))
let () = run "resolved selection HTTP replay"
  ["recorded responses",[test_case "disabled lane preserves unresolved candidates" `Quick (replay ~enabled:false);
    test_case "historical seven responses retain typed selection uses" `Quick (replay ~enabled:true)]]
