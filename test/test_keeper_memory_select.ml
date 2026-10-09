open Alcotest
module Current = Masc.Keeper_memory_os_current
module Memory = Masc.Keeper_memory_os_types
module Source = Masc.Keeper_memory_source_current
module Queue = Masc.Keeper_memory_admission_queue
module Dispatch = Masc.Keeper_tool_runtime
module Fixture = Exact_output_fixture
module Json = Yojson.Safe.Util
let require = function Ok value -> value | Error detail -> fail detail
let member = Json.member
let rows key json = member key json |> Json.to_list
let text key json = member key json |> Json.to_string
let integer key json = member key json |> Json.to_int
let sha bytes = Digestif.SHA256.(digest_string bytes |> to_hex)
let fixture_capture () =
  Yojson.Safe.from_file (Masc_test_deps.source_path "test/fixtures/memory_resolved_selection_replay/actual.json")
  |> member "capture"
let restore ~keepers_dir ~keeper_id capture =
  let bundle=member "state_bundle" capture in
  List.iter (fun (name,path) ->
    let record=member name bundle in
    if member "present" record=`Bool true then (
      let bytes=text "bytes" record in
      check string "fixture store hash" (text "sha256" record) (sha bytes);
      Fs_compat.mkdir_p (Filename.dirname path);
      Fs_compat.save_file_atomic_strict path bytes |> require))
    ["current_snapshot",Current.path_for_keepers_dir ~keepers_dir ~keeper_id;
     "consumption_and_lookup_receipt",Current.durable_range_receipt_path ~keepers_dir ~keeper_id;
     "memory_journal",Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id;
     "pending_queue",Queue.path ~keepers_dir ~keeper_id]
let answer choice = `Assoc ["type",`String "choice";"choice",`String choice;
  "confidence",`Float 1.;"probabilities",`Assoc (List.map (fun label ->
    label,`Float (if label=choice then 1. else 0.))
      ["current_decision";"comparison";"inspect_source";"not_needed"])]
let response ~choose body =
  let request=Yojson.Safe.from_string body in
  `OK,Yojson.Safe.to_string (`Assoc ["model",`String "fixture";
    "answers",`Assoc (List.map (fun (id,_) -> id,answer (choose id))
      (member "questions" request |> Json.to_assoc))])
let with_fixture ?(enabled=true) ?(excluded=false) test =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let net=Eio.Stdenv.net env and clock=Eio.Stdenv.clock env in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_context.with_test_env ~net ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  let base_path=Filename.temp_dir "memory-select-tool-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some (Filename.concat base_path "config")) @@ fun () ->
  Config_dir_resolver.reset ();
  Fun.protect ~finally:Config_dir_resolver.reset @@ fun () ->
  let capture=fixture_capture () in
  let keeper_id=text "keeper_id" capture in
  let meta=Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String keeper_id;
    "trace_id",`String "selection-tool-fixture"]) |> require in
  let config=Masc.Workspace.default_config base_path in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  restore ~keepers_dir ~keeper_id capture;
  let observed=ref [] in
  let reply=ref (response ~choose:(fun _ -> "not_needed")) in
  let server=Fixture.start_server ~sw ~net ~clock (Fixture.Reply_with (fun _ body ->
    observed:=Yojson.Safe.from_string body :: !observed; !reply body)) in
  let key="MASC_TEST_MEMORY_SELECT_KEY" in
  Masc_test_deps.with_process_env key (Some "synthetic-local-key") @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled=true;workspace_memory_selection_enabled=enabled;
      excluded_keepers=(if excluded then [keeper_id] else []);
      destinations=({Runtime_schema.endpoint=server.base_url;model="fixture";api_key_env=key},[])} @@ fun () ->
  let context : Dispatch.context =
    {config;meta;publication_recovery={provider=Masc.Keeper_publication_recovery_availability.non_runtime_provider;keeper_name=keeper_id};
     ctx_work=Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"test";
     turn_sandbox_factory=None;sw=Some sw;clock=Some clock;proc_mgr=None;net=Some net;
     mcp_session_id=None;continuation_channel=None;gate_context=None;
     turn_ref=Some (Ids.Turn_ref.make ~trace_id:"selection-tool-fixture" ~absolute_turn:1);
     gate_grant=None;tool_use_id=None;trace_id=None;result_projection=None;capability_authority=Compatibility_meta} in
  let dispatch ?limit () =
    let descriptor=match Dispatch.descriptor_for_internal "keeper_memory_select" with
      | Some descriptor -> descriptor | None -> fail "registered selection descriptor missing" in
    check bool "descriptor selects the new typed handler" true
      (descriptor.runtime_handler=Masc.Keeper_tool_descriptor.Tool_memory_select);
    let args=`Assoc (["purpose",`String "Distinguish E17 and E18 approval policy scopes."]
      @ match limit with None -> [] | Some n -> ["limit",`Int n]) in
    match Dispatch.handle context ~descriptor ~args with
    | Some execution -> Yojson.Safe.from_string execution.raw_output
    | None -> fail "descriptor dispatch did not handle memory selection" in
  test ~config ~meta ~keepers_dir ~keeper_id ~observed ~reply ~dispatch
let snapshot ~keepers_dir ~keeper_id =
  match Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require with
  | Some snapshot -> snapshot | None -> fail "current snapshot missing"
let test_grouped_sources_and_compact_results ~limited () =
  with_fixture @@ fun ~config ~meta:_ ~keepers_dir ~keeper_id ~observed ~reply ~dispatch ->
  let before=snapshot ~keepers_dir ~keeper_id in
  let ids=List.map Memory.memory_id before.facts in
  let first,second,third=match ids with [a;b;c] -> a,b,c | _ -> fail "three current fixture identities" in
  reply:=response ~choose:(fun id -> if id=first then "not_needed" else if id=second then "comparison" else "current_decision");
  let output=if limited then dispatch ~limit:1 () else dispatch () in
  check int "all current identities assessed before limit" 3 (integer "assessed_count" output);
  let request=match !observed with [request] -> request | _ -> fail "one grouped HTTP request expected" in
  let candidates=rows "candidates" (member "state" request) in
  check (list string) "each current identity appears once in provider questions" (List.sort String.compare ids)
    (member "questions" request |> Json.to_assoc |> List.map fst |> List.sort String.compare);
  let witnesses=List.fold_left (fun count row -> let detail=member "source_detail" row in
    count+List.length (rows "direct_admission_witnesses" detail)+List.length (rows "successor_witnesses" detail)) 0 candidates in
  check int "all five lineage and direct witnesses reach evaluator" 5 witnesses;
  let selected=rows "selected" output in
  let current_claims=List.map (fun (fact : Memory.fact) -> fact.claim) before.facts in
  let historical_claims=List.concat_map (fun row ->
    let detail=member "source_detail" row in
    let witnesses=rows "direct_admission_witnesses" detail @ rows "successor_witnesses" detail in
    List.map (fun witness -> text "claim" (member "historical_source" witness)) witnesses) candidates in
  List.iter (fun claim -> if not (List.mem claim current_claims) then
    check bool "absorbed source text is not echoed into Keeper output" false
      (String_util.contains_substring (Yojson.Safe.to_string output) (Yojson.Safe.to_string (`String claim)))) historical_claims;
  check (list string) "limit applies after the earlier candidate was omitted"
    (if limited then [second] else [second;third]) (List.map (text "id") selected);
  check (list string) "retrieval roles remain explicit" (if limited then ["comparison"] else ["comparison";"current_decision"])
    (List.map (text "use") selected);
  check int "omission is distinct from truncation" 1 (integer "not_needed_count" output);
  check int "truncation count" (if limited then 1 else 0) (integer "truncated_count" output);
  Printf.printf "MEMORY_SELECT_TOOL_COMPACT %s\n%!" (Yojson.Safe.to_string (`Assoc
    ["limited",`Bool limited;"assessed_current_identities",`Int (List.length candidates);
     "evaluated_witnesses",`Int witnesses;"delivered_current_identities",`Int (List.length selected);
     "tool_output_bytes",`Int (String.length (Yojson.Safe.to_string output));
     "evaluator_source_detail_bytes",`Int (List.fold_left (fun total row ->
       total+String.length (Yojson.Safe.to_string (member "source_detail" row))) 0 candidates)]));
  List.iter (fun selected ->
    let detail=member "current" selected in
    check bool "full historical evidence is not duplicated into tool output" true
      (member "successor_witnesses" detail=`Null && member "direct_admission_witnesses" detail=`Null);
    check bool "current identity has a complete scoped claim" true (member "current_fact" detail<>`Null)) selected;
  let journal=Filename.concat (Filename.concat (Masc.Workspace.keepers_runtime_dir config) keeper_id) "memory-selection-evaluations.jsonl" in
  let logs=Fs_compat.load_file journal |> String.split_on_char '\n' |> List.filter ((<>) "") |> List.map Yojson.Safe.from_string in
  check bool "full evidence retained before evaluation" true
    (List.exists (fun row -> member "status" row=`String "started" && member "state" row=member "state" request) logs);
  check bool "final projection retained" true (List.exists (fun row -> member "status" row=`String "selection_completed") logs);
  let events=match Masc.Keeper_memory_os_events.read ~keepers_dir ~keeper_id with Ok rows -> rows | Error _ -> fail "events unreadable" in
  let retrieved=List.filter_map (function _,Ok event -> (match event.Masc.Keeper_memory_os_events.kind with
    | Retrieved _ -> Some event.memory_id | Retracted | Revised _ -> None) | _,Error _ -> fail "invalid event") events in
  check (list string) "only delivered ordinary identities get Retrieved events"
    (if limited then [second] else [second;third]) retrieved
let test_negative_or_readded_evidence_changes ~readd () =
  with_fixture @@ fun ~config:_ ~meta:_ ~keepers_dir ~keeper_id ~observed:_ ~reply ~dispatch ->
  let before=snapshot ~keepers_dir ~keeper_id in
  let mutation=ref (Ok ()) in
  reply:=(fun body ->
    let result=Current.replace ~keepers_dir ~keeper_id ~expected_revision:(Some before.revision)
      ~now:(before.updated_at+.1.) ~source:{Current.kind=Explicit_write;trace_id="during-selection"} ~facts:[] () in
    mutation:=(match result with Error detail -> Error detail | Ok removed ->
      if not readd then Ok () else Current.replace ~keepers_dir ~keeper_id
        ~expected_revision:(Some removed.revision) ~now:(before.updated_at+.2.)
        ~source:{Current.kind=Explicit_write;trace_id="readd"} ~facts:before.facts () |> Result.map (fun _ -> ()));
    response ~choose:(fun _ -> if readd then "current_decision" else "not_needed") body);
  let output=dispatch () in
  require !mutation;
  check int "stale positive or negative verdict not published" 0 (integer "selected_count" output);
  check int "changed negative is not reported as not needed" 0 (integer "not_needed_count" output);
  check int "all old witnesses remain unresolved" 3 (List.length (rows "deferred" output));
  check bool "changed evidence is explicit" true (member "incomplete" output=`Bool true)
let test_unavailable ~enabled ~excluded () =
  with_fixture ~enabled ~excluded @@ fun ~config:_ ~meta:_ ~keepers_dir:_ ~keeper_id:_ ~observed ~reply:_ ~dispatch ->
  let output=dispatch () in
  check string "policy unavailable, not empty relevance result" "unavailable" (text "status" output);
  check bool "absence not established" true (member "incomplete" output=`Bool true);
  check int "no content sent" 0 (List.length !observed)
let test_undurable_selection_never_dispatches () =
  with_fixture @@ fun ~config ~meta:_ ~keepers_dir:_ ~keeper_id ~observed ~reply:_ ~dispatch ->
  let journal=Filename.concat (Filename.concat (Masc.Workspace.keepers_runtime_dir config) keeper_id)
    "memory-selection-evaluations.jsonl" in
  Fs_compat.mkdir_p journal;
  let output=dispatch () in
  check int "failed durable request blocks provider" 0 (List.length !observed);
  check string "unretained projection remains unavailable" "unavailable" (text "status" output);
  check bool "no current evidence delivered" true (rows "selected" output=[]);
  check bool "failure does not establish absence" true (member "incomplete" output=`Bool true)
let test_malformed_answer () =
  with_fixture @@ fun ~config:_ ~meta:_ ~keepers_dir:_ ~keeper_id:_ ~observed ~reply ~dispatch ->
  reply:=(fun _ -> `OK,"{\"model\":\"fixture\",\"answers\":{}}");
  let output=dispatch () in
  check int "one actual HTTP request" 1 (List.length !observed);
  check int "missing answers are not successful absence" 3 (List.length (rows "deferred" output));
  check int "no irrelevant verdict invented" 0 (integer "not_needed_count" output);
  check bool "explicit incomplete" true (member "incomplete" output=`Bool true)
type source_mutation = Unchanged | Bytes_changed | Claim_replaced
let test_source_freshness mode () =
  with_fixture @@ fun ~config ~meta ~keepers_dir ~keeper_id ~observed ~reply ~dispatch ->
  let root=Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Fs_compat.mkdir_p root;
  let host_path=Filename.concat root "approval.txt" in
  Fs_compat.save_file_atomic_strict host_path "original source bytes" |> require;
  let write claim =
    match Source.upsert_file_fact
      ~ordinary_facts:(fun () -> Ok (snapshot ~keepers_dir ~keeper_id).facts)
      ~config ~meta ~keepers_dir ~now:(Time_compat.now ()) ~claim ~source_path:"approval.txt" () with
    | Ok _ -> Ok ()
    | Error (Source.Source_read_failed failure) -> Error (Source.source_read_failure_to_string failure)
    | Error (Store_write_failed detail) -> Error detail in
  write "Original file-bound approval statement" |> require;
  let mutation=ref (Ok ()) in
  reply:=(fun body ->
    mutation:=(match mode with
      | Unchanged -> Ok ()
      | Bytes_changed -> Fs_compat.save_file_atomic_strict host_path "changed bytes"
      | Claim_replaced -> write "Replacement claim over exactly the same bytes");
    response ~choose:(fun _ -> "current_decision") body);
  let output=dispatch () in
  require !mutation;
  let request=match !observed with [request] -> request | _ -> fail "one request expected" in
  check int "source and ordinary identities are all judged" 4
    (List.length (rows "candidates" (member "state" request)));
  let source_selected=List.filter (fun row -> text "store" (member "current" row)="source_bound_current_memory") (rows "selected" output) in
  match mode with
  | Unchanged ->
    check int "verified source is delivered separately from ordinary identity" 1 (List.length source_selected);
    let fact=member "current_fact" (member "current" (List.hd source_selected)) in
    check string "exact verified source checksum" ("sha256:" ^ sha "original source bytes") (text "source_sha256" fact);
    check string "current source claim preserved" "Original file-bound approval statement" (text "claim" fact);
    check bool "verified selection complete" true (member "incomplete" output=`Bool false);
    let events=match Masc.Keeper_memory_os_events.read ~keepers_dir ~keeper_id with
      | Ok rows -> rows | Error _ -> fail "events unreadable" in
    check int "source-bound result does not manufacture ordinary Retrieved identity" 3 (List.length events)
  | Bytes_changed | Claim_replaced ->
    check int "changed source claim cannot be delivered from old decision" 0 (List.length source_selected);
    check bool "changed file or same-byte claim is unresolved" true (member "incomplete" output=`Bool true);
    check bool "old selected source witness becomes deferred" true
      (List.exists (fun row -> text "kind" row="evidence_changed") (rows "deferred" output))
let test_source_read_failure () =
  if Unix.geteuid ()=0 then skip ();
  with_fixture @@ fun ~config ~meta ~keepers_dir ~keeper_id ~observed ~reply:_ ~dispatch ->
  let root=Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta in
  Fs_compat.mkdir_p root;
  let host_path=Filename.concat root "unreadable.txt" in
  Fs_compat.save_file_atomic_strict host_path "private fixture bytes" |> require;
  (match Source.upsert_file_fact
    ~ordinary_facts:(fun () -> Ok (snapshot ~keepers_dir ~keeper_id).facts)
    ~config ~meta ~keepers_dir ~now:(Time_compat.now ()) ~claim:"UNVERIFIABLE_SOURCE_CLAIM"
    ~source_path:"unreadable.txt" () with
   | Ok _ -> () | Error (Source.Source_read_failed failure) -> fail (Source.source_read_failure_to_string failure)
   | Error (Store_write_failed detail) -> fail detail);
  Unix.chmod host_path 0o000;
  let output=Fun.protect ~finally:(fun () -> Unix.chmod host_path 0o600) (fun () -> dispatch ()) in
  check bool "unavailable source is not an empty successful search" true (member "incomplete" output=`Bool true);
  check bool "source failure explicitly retained" true (rows "unavailable" output<>[]);
  List.iter (fun request -> check bool "unverified source body never enters evaluator" false
    (String_util.contains_substring (Yojson.Safe.to_string request) "UNVERIFIABLE_SOURCE_CLAIM")) !observed
let test_policy_revoked_during_judgment () =
  with_fixture @@ fun ~config:_ ~meta:_ ~keepers_dir:_ ~keeper_id:_ ~observed ~reply ~dispatch ->
  reply:=(fun body ->
    let policy=Runtime_typesafeai_policy.current () in
    Runtime_typesafeai_policy.publish {policy with workspace_memory_selection_enabled=false};
    response ~choose:(fun _ -> "current_decision") body);
  let output=dispatch () in
  check int "one judgment before revocation" 1 (List.length !observed);
  check int "revoked selection does not publish facts" 0 (integer "selected_count" output);
  check int "all choices are deferred after policy revocation" 3 (List.length (rows "deferred" output));
  check bool "policy change is explicit" true
    (List.for_all (fun row -> text "kind" row="selection_policy_changed") (rows "deferred" output))

let () = run "personal memory select descriptor HTTP"
  ["selection",[
    test_case "full grouped witnesses produce compact current roles" `Quick (test_grouped_sources_and_compact_results ~limited:false);
    test_case "result limit follows semantic selection" `Quick (test_grouped_sources_and_compact_results ~limited:true);
    test_case "negative verdict invalidated by current retirement" `Quick (test_negative_or_readded_evidence_changes ~readd:false);
    test_case "identical readd cannot reuse selected incarnation" `Quick (test_negative_or_readded_evidence_changes ~readd:true);
    test_case "selection opt-in off never dispatches" `Quick (test_unavailable ~enabled:false ~excluded:false);
    test_case "Keeper exclusion never dispatches" `Quick (test_unavailable ~enabled:true ~excluded:true);
    test_case "verified file-bound claim preserves its source identity" `Quick (test_source_freshness Unchanged);
    test_case "source bytes changed during HTTP cannot publish" `Quick (test_source_freshness Bytes_changed);
    test_case "same-byte claim replacement cannot publish old decision" `Quick (test_source_freshness Claim_replaced);
    test_case "unreadable source is withheld and remains unresolved" `Quick test_source_read_failure;
    test_case "policy revoked during HTTP prevents publication" `Quick test_policy_revoked_during_judgment;
    test_case "undurable request cannot dispatch or publish" `Quick test_undurable_selection_never_dispatches;
    test_case "malformed provider answer remains unresolved" `Quick test_malformed_answer]]
