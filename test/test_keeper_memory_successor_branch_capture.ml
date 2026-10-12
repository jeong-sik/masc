open Alcotest
module Current = Masc.Keeper_memory_os_current
module Memory = Masc.Keeper_memory_os_types
module Queue = Masc.Keeper_memory_admission_queue
module Selector = Masc.Keeper_memory_successor_selection
let require = function Ok value -> value | Error detail -> fail detail
let sha bytes = Digestif.SHA256.(digest_string bytes |> to_hex)
let hash_json json = sha (Yojson.Safe.to_string json)
let () = Masc.Prompt_defaults.init ()

(* These transitions are authored synthetic evidence, not a model's discovery
   of an event split. Only production request rendering is measured here. *)
let capture () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
  let base_path=Filename.temp_dir "successor-branch-capture-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some (Filename.concat base_path "config")) @@ fun () ->
  Config_dir_resolver.reset ();
  Fun.protect ~finally:Config_dir_resolver.reset @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled=false;absorb_gate=false} @@ fun () ->
  let keeper_id="synthetic-successor-branches" and trace_id="authored-event-lineage-fixture" in
  let config=Masc.Workspace.default_config base_path in
  let meta=Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name",`String keeper_id;"trace_id",`String trace_id]) |> require in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let now=Time_compat.now () in
  let fact claim = Memory.observed ~claim ~category:Memory.Fact ~now
    ~origin:{kind=Memory.Authored;trace_id} in
  let source_claims=[
    "Event E17: production R-015 requires owner approval.";
    "Event E17: staging R-015 requires owner approval.";
    "Event E18: an unrelated production R-015 release requires release-manager approval."] in
  let request_ids=List.map (fun claim ->
    let result=Masc.Keeper_tool_memory_runtime.keeper_memory_write_with_outcome
      ~config ~meta ~args:(`Assoc ["content",`String claim]) in
    let json=Yojson.Safe.from_string result.raw_output in
    check string "real write producer persists admission input" "persisted_pending_admission"
      Yojson.Safe.Util.(json |> member "outcome" |> to_string);
    Yojson.Safe.Util.(json |> member "request_id" |> to_string)) source_claims in
  let batch=match Queue.read_pending ~keepers_dir ~keeper_id |> require with
    | Some batch -> batch | None -> fail "producer queue missing" in
  let candidates=Queue.candidates batch and ids=Queue.candidate_ids batch in
  check (list string) "queue preserves the three distinct observations" source_claims
    (List.map (fun (candidate : Queue.candidate) -> candidate.fact.claim) candidates);
  let a=fact "Event E17: deployment of R-015 to either production or staging requires owner approval." in
  let u=fact "Event E18: release-manager approval governs this unrelated production R-015 release." in
  let targets=[a;a;u] in
  let bindings=List.map2 (fun ((candidate : Queue.candidate),(candidate_id : Current.explicit_candidate_id)) target ->
    {Current.candidate_id;source_fact=candidate.fact;target_memory_id=Memory.memory_id target})
    (List.combine candidates ids) targets in
  let source={Current.kind=Current.Librarian;trace_id} in
  ignore (Current.apply_disposition ~keepers_dir ~keeper_id ~now ~source
    ~explicit_candidate_ids:ids
    ~admission_recall:{Current.decided_at_revision=None; bindings}
    ~absorbed:[] ~revisions:[] ~new_claims:[a;u] () |> require : Current.disposition);
  Queue.acknowledge_committed ~keepers_dir ~keeper_id |> require;
  check bool "only actual receipts consume initial observations" true
    ((Queue.read_pending ~keepers_dir ~keeper_id |> require)=None);
  let b=fact "Event E17 production R-015: the owner must authorize the rollout." in
  let c=fact "Event E17 staging R-015: obtain owner sign-off before deployment." in
  let d=fact "Event E17 production R-015: the revised rollout policy now requires two independent approvals, replacing owner-only authorization." in
  let revise old successors reason =
    let revisions=List.map (fun successor ->
      {Memory.superseded=Memory.memory_id old;superseded_by=Memory.memory_id successor}) successors in
    ignore (Current.apply_disposition ~keepers_dir ~keeper_id ~now:(Time_compat.now ()) ~source
      ~dropped_statements:[{Memory.memory_id=Memory.memory_id old;reason}]
      ~absorbed:[] ~revisions ~new_claims:successors () |> require : Current.disposition) in
  revise a [b;c] "Authored fixture: E17 owner separates the production and staging policy records.";
  revise b [d] "Authored fixture: E17 owner approves two independent approvals for production only.";
  let state=Current.read_successor_recall_for_keepers_dir ~keepers_dir ~keeper_id |> require in
  check int "each E17 observation has both explicitly linked branches" 4 (List.length state.successor_candidates);
  check int "unrelated E18 observation remains direct" 1 (List.length state.direct_bindings);
  check int "authored lineage is complete" 0 (List.length state.unresolved);
  check (list int) "production traverses two transitions and staging one" [1;1;2;2]
    (List.map (fun (candidate : Current.successor_recall_candidate) -> List.length candidate.path)
       state.successor_candidates |> List.sort Int.compare);
  List.iter (fun (candidate : Current.successor_recall_candidate) ->
    check bool "unrelated event is never inferred into a successor path" true
      (List.mem candidate.binding.candidate_id.request_id (List.take 2 request_ids));
    check bool "each path retains the actual combined predecessor" true (candidate.original_target=a)) state.successor_candidates;
  let stores=["current_snapshot",Current.path_for_keepers_dir ~keepers_dir ~keeper_id;
    "consumption_and_lookup_receipt",Current.durable_range_receipt_path ~keepers_dir ~keeper_id;
    "memory_journal",Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id;
    "pending_queue",Queue.path ~keepers_dir ~keeper_id] in
  let before=List.map (fun (name,path) -> name,Fs_compat.load_file_opt path) stores in
  let state_bundle=`Assoc (List.map (fun (name,bytes) -> name,match bytes with
    | None -> `Assoc ["present",`Bool false]
    | Some bytes -> `Assoc ["present",`Bool true;"bytes",`String bytes;"sha256",`String (sha bytes)]) before) in
  let queries=["E17 production R-015";"E17 staging R-015";"E17 R-015 across environments";
    "E18 production R-015";"R-015 approval policy"] in
  let query_exports=List.mapi (fun index query ->
    let matched=Masc.Keeper_tool_memory_runtime.For_testing.successor_candidates_for_query
      ~query state.successor_candidates in
    let requests=ref [] in
    let evaluate ~state ~questions =
      let body=Masc.Typesafeai_types.request_to_yojson ~model:"jev-latest" ~state ~questions
        |> Yojson.Safe.to_string in
      let questions=`Assoc (List.map (fun (id,question) ->
        id,Masc.Typesafeai_types.question_to_yojson question) questions) in
      requests:=`Assoc ["request_index",`Int (List.length !requests);"model",`String "jev-latest";
        "request_body",`String body;"request_body_sha256",`String (sha body);
        "state",state;"questions",questions;"state_sha256",`String (hash_json state);
        "questions_sha256",`String (hash_json questions)] :: !requests;
      Error (Masc.Keeper_workspace_memory_selection.Unavailable "capture only") in
    let result=Selector.select_with_evaluate ~evaluate ~query matched in
    check int "one exact production request per matched pair" (List.length matched) (List.length !requests);
    check int "capture does not claim semantic success" 0 (List.length result.selected);
    check int "capture preserves all undecided pairs" (List.length matched) (List.length result.unresolved);
    `Assoc ["query_id",`String (Printf.sprintf "query-%03d" (index+1));"query",`String query;
      "matched_candidate_count",`Int (List.length matched);"requests",`List (List.rev !requests)]) queries in
  List.iter (fun (name,path) -> check (option string) (name ^ " unchanged by question capture")
    (List.assoc name before) (Fs_compat.load_file_opt path)) stores;
  let provenance=`Assoc ["transition_origin",`String "authored_synthetic_production_api_transitions";
    "model_discovered_split",`Bool false;"source_observations",`List (List.map (fun claim -> `String claim) source_claims);
    "admitted_targets",`List (List.map Memory.fact_to_json [a;u]);
    "split_targets",`List (List.map Memory.fact_to_json [b;c]);"later_production_target",Memory.fact_to_json d] in
  Printf.printf "MEMORY_SUCCESSOR_JUDGMENT_EXPORT %s\n%!" (Yojson.Safe.to_string (`Assoc
    ["measurement",`String "production_successor_judgment_capture";
     "semantic_judgment_performed",`Bool false;"captured_at",`Float (Time_compat.now ());
     "phase",`String "after_authored_split_and_followup_revision";
     "scenario",`String "event_environment_split_and_two_step_revision";"scenario_provenance",provenance;
     "scenario_sha256",`String (hash_json provenance);"keeper_id",`String keeper_id;
     "trace_id",`String trace_id;"absolute_turn",`Int 0;
     "state_bundle",state_bundle;"state_bundle_sha256",`String (hash_json state_bundle);
     "queries",`List query_exports]))
let () = run "successor split and chain capture"
  ["authored lineage",[test_case "capture production selection for environment and event branches" `Quick capture]]
