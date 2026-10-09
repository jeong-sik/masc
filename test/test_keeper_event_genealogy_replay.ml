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

module Selection = Masc.Keeper_workspace_memory_selection
module Types = Masc.Typesafeai_types
module Client = Masc.Typesafeai_client

let questions request =
  member "questions" request |> Json.to_assoc |> List.map (fun (id,row) ->
    id,Types.Choice {instructions=jstring "instructions" row;
      criteria=member "criteria" row |> Json.to_assoc |> List.map (fun (label,value) ->
        label,(match value with `String text -> Some text | `Null -> None | _ -> fail "invalid captured criterion"))})

let replay_case envelope case =
  let original=member "capture" envelope in
  let query=List.find (fun query -> member "query_id" query=member "purpose_id" case) (rows "queries" original) in
  let baseline=List.hd (rows "requests" query) in
  let experimental=jstring "arm" case="experimental" in
  let request=if experimental then List.hd (rows "experimental_requests" query) else baseline in
  let request_body=jstring "request_body" request in
  let response=jstring "response_raw" case in
  check string "case points to its exact frozen request" (jstring "request_sha256" case) (sha request_body);
  check string "untouched actual response SHA" (jstring "response_sha256" case) (sha response);
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
  let bodies=ref [] in
  let server=Fixture.start_server ~sw ~net ~clock (Fixture.Reply_with (fun _ body ->
    bodies:=body :: !bodies;
    if body=request_body then Cohttp.Code.status_of_code (member "status" case |> Json.to_int),response
    else `Bad_request,"request differs from frozen case")) in
  let key="MASC_TEST_GENEALOGY_REPLAY_KEY" in
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
  let aliases=member "aliases" envelope |> Json.to_assoc in
  let alias id=List.assoc id aliases |> Json.to_string in
  let expected=member "expected_states" case |> Json.to_assoc in
  let state_table selected deferred omitted =
    let states=selected @ deferred @ omitted in
    check int "all six candidates remain accounted for" 6 (List.length states);
    let states=List.map (fun (id,state) -> alias id,`String state) states in
    check bool "production results agree with frozen audited raw decoding" true
      (Yojson.Safe.sort (`Assoc states)=Yojson.Safe.sort (`Assoc expected));
    `Assoc states in
  let measurement=if experimental then (
    let state=member "state" baseline in
    let input=rows "candidates" state |> List.map (fun row ->
      let candidate=member "candidate" row in
      ({Selection.id=jstring "id" candidate;summary=jstring "summary" candidate},member "source_detail" row)) in
    let observed=ref [] in
    let evaluate ~state ~questions:generated =
      observed := (state,generated) :: !observed;
      (* This is an explicit experimental adapter, not the production tool.
         Its captured questions alone replace the baseline question contract. *)
      let destinations=({Client.endpoint=server.base_url;model="jev-latest";
        api_key="synthetic-local-key"},[]) in
      match Client.evaluate ~clock ~destinations ~state
          ~questions:(questions request) () with
      | Ok evaluated -> Ok evaluated.response
      | Error failure -> Error (Selection.Unavailable (Client.failure_to_string failure)) in
    let outcomes=Selection.select_resolved_many ~evaluate ~purpose:(member "current_purpose" state) input in
    (match !observed with
     | [(actual_state,actual_questions)] ->
       check bool "core sees exact frozen source state" true (actual_state=state);
       check bool "core first generates unchanged production questions" true (actual_questions=questions baseline)
     | _ -> fail "core replay must evaluate exactly once");
    let selected,deferred,omitted=List.fold_left (fun (selected,deferred,omitted) -> function
      | Selection.Selected {candidate;use;_} ->
        let role=match use with For_current_decision -> "current_decision" | For_comparison -> "comparison" in
        (candidate.id,role)::selected,deferred,omitted
      | Not_needed candidate -> selected,deferred,(candidate.id,"not_needed")::omitted
      | Deferred {candidate;reason} ->
        let label=match reason with Applicability_unresolved -> "inspect_source" | _ -> "invalid" in
        selected,(candidate.id,label)::deferred,omitted) ([],[],[]) outcomes in
    `Assoc ["boundary",`String "experimental_core_only";
      "states",state_table selected deferred omitted;
      "incomplete",`Bool (deferred<>[]);
      "tool_output_bytes",`Null;
      "limitation",`String "No experimental tool publication, freshness revalidation or matched tool-byte comparison."])
  else (
    let execution=match Dispatch.handle context ~descriptor ~args:(member "tool_args" query) with
      | Some result -> result | None -> fail "actual descriptor dispatch unavailable" in
    let output=Yojson.Safe.from_string execution.raw_output in
    let selected=rows "selected" output |> List.map (fun row -> jstring "id" row,jstring "use" row) in
    let deferred=rows "deferred" output |> List.map (fun row ->
      let kind=jstring "kind" row in
      jstring "id" row,(if kind="applicability_unresolved" then "inspect_source" else "invalid")) in
    let omitted=List.filter_map (fun (id,_) ->
      if List.mem_assoc id selected || List.mem_assoc id deferred then None else Some (id,"not_needed")) aliases in
    check int "all candidates assessed before publication" 6 (member "assessed_count" output |> Json.to_int);
    check int "no unrelated unavailable sources" 0 (List.length (rows "unavailable" output));
    check int "omission count matches unreturned nondeferred identities" (List.length omitted)
      (member "not_needed_count" output |> Json.to_int);
    check bool "invalid or inspect replies remain incomplete" (deferred<>[])
      (member "incomplete" output |> Json.to_bool);
    `Assoc ["boundary",`String "baseline_actual_tool";
      "states",state_table selected deferred omitted;
      "tool_output_bytes",`Int (String.length execution.raw_output);"output",output]) in
  check (list string) "exact frozen wire, once, no retry" [request_body] (List.rev !bodies);
  List.iter (fun (_,path,bytes) -> check (option string) "four authoritative stores unchanged" bytes
    (Fs_compat.load_file_opt path)) stores;
  `Assoc ["query_id",member "query_id" case;"purpose_id",member "purpose_id" case;
    "arm",member "arm" case;"repetition",member "repetition" case;
    "request_sha256",member "request_sha256" case;"response_sha256",member "response_sha256" case;
    "measurement",measurement]

let replay () =
  let path=Masc_test_deps.source_path "test/fixtures/event_genealogy_replay/actual.json" in
  let bytes=Fs_compat.load_file path in
  let envelope=Yojson.Safe.from_string bytes in
  let cases=rows "cases" envelope in
  check int "66 recorded cases required" 66 (List.length cases);
  check int "case identities do not collapse equal request hashes" 66
    (List.length (List.sort_uniq String.compare (List.map (jstring "query_id") cases)));
  List.iter (fun arm -> check int "33 repetitions per boundary" 33
    (List.length (List.filter (fun row -> jstring "arm" row=arm) cases))) ["baseline";"experimental"];
  List.iter (fun query -> List.iter (fun arm -> List.iter (fun repetition ->
    check int "every frozen purpose/arm/repetition occurs once" 1
      (List.length (List.filter (fun row -> member "purpose_id" row=member "query_id" query
        && jstring "arm" row=arm && member "repetition" row=`Int repetition) cases)))
      [1;2;3]) ["baseline";"experimental"]) (rows "queries" (member "capture" envelope));
  let results=List.map (replay_case envelope) cases in
  Printf.printf "MEMORY_EVENT_GENEALOGY_REPLAY %s\n%!" (Yojson.Safe.to_string (`Assoc
    ["fixture_sha256",`String (sha bytes);"cohort_sha256",member "cohort_sha256" envelope;
     "rubric_sha256",member "rubric_sha256" envelope;"results",`List results]))

let () = run "event genealogy actual response replay"
  ["recorded responses",[test_case "baseline tool and experimental core boundaries" `Quick replay]]
