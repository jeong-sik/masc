open Alcotest
module Current = Masc.Keeper_memory_os_current
module Memory = Masc.Keeper_memory_os_types
module Queue = Masc.Keeper_memory_admission_queue
module Fixture = Exact_output_fixture
module Json = Yojson.Safe.Util
let require = function Ok value -> value | Error detail -> fail detail
let member = Json.member
let jstring name json = member name json |> Json.to_string
let rows name json = member name json |> Json.to_list
let sha bytes = Digestif.SHA256.(digest_string bytes |> to_hex)
let fixture_path = "test/fixtures/memory_successor_http_replay/actual.json"
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

let replay ~enabled () =
  let envelope=Yojson.Safe.from_file (Masc_test_deps.source_path fixture_path) in
  let capture=member "capture" envelope in
  check string "captured state bundle SHA" (jstring "state_bundle_sha256" capture)
    (sha (Yojson.Safe.to_string (member "state_bundle" capture)));
  let queries=rows "queries" capture in
  let expected=Hashtbl.create 32 in
  List.iter (fun query -> List.iter (fun request ->
    let body=jstring "request_body" request and hash=jstring "request_body_sha256" request in
    check string "captured request SHA" hash (sha body);
    let decoded=Yojson.Safe.from_string body in
    List.iter (fun key -> check bool ("request body preserves captured " ^ key) true
      (Yojson.Safe.equal (member key decoded) (member key request))) ["state";"questions"];
    check string "captured requested model" (jstring "model" request) (jstring "model" decoded);
    match Hashtbl.find_opt expected hash with
    | None -> Hashtbl.add expected hash body
    | Some prior -> check string "same request digest preserves bytes" prior body) (rows "requests" query)) queries;
  let responses=Hashtbl.create 32 in
  List.iter (fun row ->
    let hash=jstring "request_sha256" row and body=jstring "request_body" row in
    check string "response belongs to exact captured request" hash (sha body);
    (match Hashtbl.find_opt expected hash with
     | Some expected_body -> check string "response request bytes" expected_body body
     | None -> fail "response for an uncaptured request");
    check bool "one recorded response per unique request" false (Hashtbl.mem responses hash);
    (match member "metadata" row with `Assoc (_::_) -> () | _ -> fail "actual response metadata required");
    let status=member "status" row |> Json.to_int in
    let response=jstring "response_raw" row in
    check string "actual response bytes SHA" (jstring "response_sha256" row) (sha response);
    Hashtbl.add responses hash (body,status,response)) (rows "model_responses" envelope);
  check int "every unique capture has an actual response" (Hashtbl.length expected) (Hashtbl.length responses);
  if Hashtbl.length responses=0 then fail "no actual successor responses";
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let net=Eio.Stdenv.net env and clock=Eio.Stdenv.clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  let base_path=Filename.temp_dir "successor-http-replay-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some (Filename.concat base_path "config")) @@ fun () ->
  Config_dir_resolver.reset ();
  Fun.protect ~finally:Config_dir_resolver.reset @@ fun () ->
  let keeper_id=jstring "keeper_id" capture |> Keeper_id.Keeper_name.of_string |> require |> Keeper_id.Keeper_name.to_string in
  let trace_id=jstring "trace_id" capture |> Keeper_id.Trace_id.of_string |> require |> Keeper_id.Trace_id.to_string in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let stores=restore ~keepers_dir ~keeper_id (member "state_bundle" capture) in
  let state=Current.read_successor_recall_for_keepers_dir ~keepers_dir ~keeper_id |> require in
  let current_ids=match state.snapshot with None -> [] | Some snapshot -> List.map Memory.memory_id snapshot.facts in
  let errors=ref [] and observed=ref [] in
  let server=Fixture.start_server ~sw ~net ~clock (Fixture.Reply_with (fun _ body ->
    let hash=sha body in
    observed:=hash :: !observed;
    match Hashtbl.find_opt responses hash with
    | Some (expected_body,status,response) when expected_body=body -> Cohttp.Code.status_of_code status,response
    | Some _ | None -> errors:=("unexpected request " ^ hash)::!errors;
      `Bad_request,"unrecorded successor request")) in
  let config=Masc.Workspace.default_config base_path in
  let meta=Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String keeper_id;"trace_id",`String trace_id]) |> require in
  let key="MASC_TEST_SUCCESSOR_REPLAY_KEY" in
  Masc_test_deps.with_process_env key (Some "synthetic-local-replay-key") @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled=enabled;absorb_gate=false;excluded_keepers=[];
     destinations=({Runtime_schema.endpoint=server.base_url;model="jev-latest";api_key_env=key},[])} @@ fun () ->
  let results=List.concat_map (fun query -> List.map (fun source ->
    observed:=[];
    let query_text=jstring "query" query in
    let output=Masc.Keeper_tool_memory_runtime.keeper_memory_search_json ~config ~meta
      ~ctx_work:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"")
      ~args:(`Assoc ["query",`String query_text;"source",`String source]) |> Yojson.Safe.from_string in
    check (list string) "HTTP fixture had no unmatched request" [] (List.rev !errors);
    let expected_hashes=if enabled then List.map (jstring "request_body_sha256") (rows "requests" query) else [] in
    if expected_hashes <> List.rev !observed then
      Printf.eprintf "SUCCESSOR_HTTP_REQUEST_MISMATCH query=%s source=%s response=%s\n%!"
        query_text source (Yojson.Safe.to_string output);
    check (list string) "tool sends exact captured pairs in order" expected_hashes (List.rev !observed);
    if not enabled && rows "requests" query<>[] then (
      check string "disabled lane reports incomplete successor retrieval" "incomplete"
        (jstring "status" (member "successor_recall" output));
      check bool "unresolved retrieval is not authoritative absence" false
        (member "no_match" output = `Bool true));
    List.iter (fun result -> if member "successor_lookup_evidence" result<>`Null then
      check bool "judged successor identity is current" true
        (List.mem (jstring "memory_id" result) current_ids)) (rows "matches" output);
    `Assoc ["query_id",member "query_id" query;"query",`String query_text;"source",`String source;
      "request_sha256",`List (List.map (fun hash -> `String hash) (List.rev !observed));"response",output]) ["current";"all"]) queries in
  List.iter (fun (name,path,bytes) -> check (option string) (name ^ " unchanged by actual tool replay")
    bytes (Fs_compat.load_file_opt path)) stores;
  let journal=Filename.concat (Filename.concat (Masc.Workspace.keepers_runtime_dir config) keeper_id)
    "memory-selection-evaluations.jsonl" in
  let logs=match Fs_compat.load_file_opt journal with None -> [] | Some text ->
    String.split_on_char '\n' text |> List.filter (fun line -> String.trim line<>"") |> List.map Yojson.Safe.from_string in
  let count status=List.length (List.filter (fun row -> member "status" row=`String status) logs) in
  let posts=Fixture.post_count server in
  check int "each actual POST has durable started evidence" posts (count "started");
  check int "each actual POST has durable terminal response evidence" posts (count "response_received" + count "provider_failed");
  let expected_selections=if enabled then 2 * List.length
    (List.filter (fun query -> rows "requests" query<>[]) queries) else 0 in
  check int "each evaluated tool query retains a final selection" expected_selections (count "selection_completed");
  if enabled then check bool "enabled replay performed actual local HTTP calls" true (posts>0)
  else check int "disabled lane sends no HTTP" 0 posts;
  Printf.printf "MEMORY_SUCCESSOR_HTTP_REPLAY %s\n%!" (Yojson.Safe.to_string (`Assoc
    ["lane_enabled",`Bool enabled;"measurement",`String "recorded_actual_response_through_production_tool";
     "network_scope",`String "local_fixture_only";"http_requests",`Int posts;"results",`List results]))
let () = run "successor production HTTP replay"
  ["captured responses",[test_case "disabled lane keeps unresolved retrieval explicit" `Quick (replay ~enabled:false);
    test_case "actual answers traverse HTTP selector and current/all search" `Quick (replay ~enabled:true)]]
