module Selection = Masc.Keeper_workspace_memory_selection
module Types = Masc.Typesafeai_types

let candidate : Selection.candidate =
  {id="claim-fixture";summary="A staging-only exception may be relevant as contrast."}
let purpose = `Assoc ["decision", `String "Determine production approval requirements"]
let source = `Assoc ["scope", `String "staging only";"current", `Bool true]
let response choice : Types.eval_response =
  { model="fixture";usage=None;
    answers=["selection", Types.Choice_answer
      {choice;confidence=1.;probabilities=List.map (fun label ->
         label, if label=choice then 1. else 0.)
         ["current_decision";"comparison";"inspect_source";"not_needed"]}] }

let test_source_can_change_how_a_memory_is_used () =
  let events = ref [] in
  let evaluate ~state ~questions:_ =
    Alcotest.(check bool) "frozen purpose survives both assessments" true
      (Yojson.Safe.Util.member "current_purpose" state = purpose);
    match Yojson.Safe.Util.member "source_detail" state with
    | `Null -> events := !events @ ["summary"]; Ok (response "current_decision")
    | detail ->
      Alcotest.(check bool) "actual resolved source is judged" true (detail=source);
      events := !events @ ["source assessment"]; Ok (response "comparison") in
  let resolve ~id =
    Alcotest.(check string) "the selected candidate alone is resolved" candidate.id id;
    events := !events @ ["resolve"]; Ok source in
  (match Selection.select ~evaluate ~resolve ~purpose candidate with
   | Selected {use=For_comparison;source_detail;candidate=selected} ->
     Alcotest.(check string) "identity is preserved" candidate.id selected.id;
     Alcotest.(check bool) "scoped source accompanies comparison" true (source_detail=source)
   | _ -> Alcotest.fail "summary must not override source-scoped comparison");
  Alcotest.(check (list string)) "resolve occurs between the two assessments"
    ["summary";"resolve";"source assessment"] !events

let test_unrelated_memory_does_not_fetch_sources () =
  let evaluate ~state:_ ~questions:_ = Ok (response "not_needed") in
  let resolve ~id:_ = Alcotest.fail "unselected source was fetched" in
  match Selection.select ~evaluate ~resolve ~purpose candidate with
  | Not_needed _ -> ()
  | _ -> Alcotest.fail "expected purpose-specific omission"

let test_source_failure_is_not_a_negative_relevance_vote () =
  let evaluate ~state:_ ~questions:_ = Ok (response "inspect_source") in
  match Selection.select ~evaluate ~resolve:(fun ~id:_ -> Error "ledger changed") ~purpose candidate with
  | Deferred {reason=Source_unavailable "ledger changed";_} -> ()
  | _ -> Alcotest.fail "unavailable source must remain distinguishable from not needed"

let test_unresolved_source_does_not_loop () =
  let calls = ref 0 in
  let evaluate ~state:_ ~questions:_ = incr calls; Ok (response "inspect_source") in
  (match Selection.select ~evaluate ~resolve:(fun ~id:_ -> Ok source) ~purpose candidate with
   | Deferred {reason=Applicability_unresolved;_} -> ()
   | _ -> Alcotest.fail "unresolved applicability must stay deferred");
  Alcotest.(check int) "one summary assessment and one source assessment" 2 !calls

let test_invalid_judgment_does_not_deliver_or_discard_memory () =
  let evaluate ~state:_ ~questions:_ = Ok
    {Types.model="invalid-fixture";usage=None;answers=["selection", Types.Choice_answer
      {choice="comparison";confidence=0.9;probabilities=
        ["current_decision",0.01;"comparison",0.93;"inspect_source",0.05;"not_needed",0.]}]} in
  let resolve ~id:_ = Alcotest.fail "invalid judgment cannot authorize source selection" in
  match Selection.select ~evaluate ~resolve ~purpose candidate with
  | Deferred {reason=Invalid_answer _;_} -> ()
  | _ -> Alcotest.fail "invalid probabilities must not become a successful selection"

let with_adapter f =
  let base = Filename.temp_dir "memory-selection-io-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () ->
    let config = Masc.Workspace.default_config base in
    let destination : Masc.Typesafeai_client.destination =
      {endpoint="https://fixture.invalid/evaluate";model="fixture";api_key="private-fixture-key"} in
    let adapter = Masc.Keeper_workspace_memory_selection_io.create
      ~config ~keeper_id:"fixture" ~destinations:(destination,[]) in
    f adapter destination)

let test_request_is_durable_before_dispatch () = with_adapter (fun adapter destination ->
  let module IO = Masc.Keeper_workspace_memory_selection_io in
  let calls = ref 0 in
  let read_rows () = Fs_compat.load_file (IO.journal_path adapter)
    |> String.split_on_char '\n' |> List.filter (fun line -> line<>"")
    |> List.map Yojson.Safe.from_string in
  let call ~destinations:_ ~state ~questions:_ () =
    incr calls;
    let rows = read_rows () in
    let row = List.hd (List.rev rows) in
    Alcotest.(check string) "last durable record precedes provider dispatch" "started"
      Yojson.Safe.Util.(row |> member "status" |> to_string);
    Alcotest.(check bool) "exact source-bearing state is retained" true
      (Yojson.Safe.Util.member "state" row = state);
    Alcotest.(check bool) "credentials are absent from the record" false
      (String_util.contains_substring (Yojson.Safe.to_string row) destination.api_key);
    Ok {Masc.Typesafeai_client.response=response "not_needed";
        destination=Masc.Typesafeai_client.identify destination;
        request_body_sha256="fixture-request";passed_over=[]} in
  (match IO.For_testing.evaluate_with ~call adapter ~state:purpose ~questions:[] with
   | Ok _ -> () | Error _ -> Alcotest.fail "adapter failed");
  Alcotest.(check int) "one actual effect call" 1 !calls;
  Alcotest.(check int) "started and terminal evidence retained" 2 (List.length (read_rows ()));
  Alcotest.(check int) "request identity available for prompt evidence join" 1 (List.length (IO.request_ids adapter)))

let test_failed_record_prevents_dispatch () = with_adapter (fun adapter _ ->
  let module IO = Masc.Keeper_workspace_memory_selection_io in
  Fs_compat.mkdir_p (IO.journal_path adapter);
  let call ~destinations:_ ~state:_ ~questions:_ () = Alcotest.fail "undurable request was dispatched" in
  match IO.For_testing.evaluate_with ~call adapter ~state:purpose ~questions:[] with
  | Error _ -> Alcotest.(check int) "no accepted input receipt" 0 (List.length (IO.request_ids adapter))
  | Ok _ -> Alcotest.fail "input persistence failure cannot report successful judgment")

let test_failed_response_record_prevents_delivery () = with_adapter (fun adapter destination ->
  let module IO = Masc.Keeper_workspace_memory_selection_io in
  let call ~destinations:_ ~state:_ ~questions:_ () =
    Unix.rename (IO.journal_path adapter) (IO.journal_path adapter ^ ".started");
    Unix.mkdir (IO.journal_path adapter) 0o700;
    Ok {Masc.Typesafeai_client.response=response "current_decision";
        destination=Masc.Typesafeai_client.identify destination;
        request_body_sha256="fixture-request";passed_over=[]} in
  match IO.For_testing.evaluate_with ~call adapter ~state:purpose ~questions:[] with
  | Error _ -> Alcotest.(check int) "started request identity survives response storage failure" 1
      (List.length (IO.request_ids adapter))
  | Ok _ -> Alcotest.fail "unretained response was delivered as a selection judgment")

let batch_response questions choice =
  let result = response choice in
  let answer = snd (List.hd result.Types.answers) in
  {result with Types.answers=List.map (fun (id,_) -> id,answer) questions}

let test_resolved_sources_are_present_before_any_omission () =
  let rows = List.map (fun (id,event) ->
    ({Selection.id;summary="Consolidated release policy"} : Selection.candidate),
    `Assoc ["historical_event",`String event;"current_target",`String "review required";
            "committed_revision_path",`List [`String "original-to-current"]])
    ["same-event","E18";"comparison","E17"] in
  let calls = ref 0 in
  let evaluate ~state ~questions =
    incr calls;
    Alcotest.(check bool) "purpose remains frozen" true
      (Yojson.Safe.Util.member "current_purpose" state = purpose);
    let candidates = Yojson.Safe.Util.(state |> member "candidates" |> to_list) in
    let answers = List.map (fun (id,_) ->
      let row = List.find (fun row -> Yojson.Safe.Util.member "question_id" row = `String id) candidates in
      let detail = Yojson.Safe.Util.member "source_detail" row in
      let choice = if detail=`Null then "not_needed" else (
        Alcotest.(check bool) "complete original evidence is assessed" true
          (detail = List.assoc id (List.map (fun (c,d) -> c.Selection.id,d) rows));
        match Yojson.Safe.Util.member "historical_event" detail with
        | `String "E18" -> "current_decision"
        | `String "E17" -> "comparison"
        | _ -> Alcotest.fail "unexpected fixture source") in
      id,snd (List.hd (response choice).Types.answers)) questions in
    Ok {Types.model="fixture";usage=None;answers} in
  let resolve ~id:_ = Alcotest.fail "summary-only rejection does not resolve" in
  let omitted = Selection.select_many ~evaluate ~resolve ~purpose (List.map fst rows) in
  Alcotest.(check bool) "summary-only control would omit both candidates" true
    (List.for_all (function Selection.Not_needed _ -> true | _ -> false) omitted);
  calls := 0;
  (match Selection.select_resolved_many ~evaluate ~purpose rows with
   | [Selected {use=For_current_decision;source_detail=first;_};
      Selected {use=For_comparison;source_detail=second;_}] ->
     Alcotest.(check bool) "selected results preserve both full witnesses" true
       ([first;second] = List.map snd rows)
   | _ -> Alcotest.fail "first judgment must see full event evidence");
  Alcotest.(check int) "resolved sources need one assessment, no preliminary rejection" 1 !calls

let test_resolved_partial_answers_and_inspection_stay_deferred () =
  let rows = List.map (fun id -> {candidate with id},source) ["selected";"inspect";"missing"] in
  let calls = ref 0 in
  let evaluate ~state:_ ~questions:_ =
    incr calls;
    let answer choice = snd (List.hd (response choice).Types.answers) in
    Ok {Types.model="fixture";usage=None;
        answers=["inspect",answer "inspect_source";"selected",answer "comparison"]} in
  (match Selection.select_resolved_many ~evaluate ~purpose rows with
   | [Selected {use=For_comparison;_};Deferred {reason=Applicability_unresolved;_};
      Deferred {reason=Invalid_answer _;_}] -> ()
   | _ -> Alcotest.fail "missing scope evidence and missing answers are not absence");
  Alcotest.(check int) "source inspection is deferred without a private loop" 1 !calls;
  let unavailable ~state:_ ~questions:_ = incr calls; Error (Selection.Unavailable "offline") in
  let results = Selection.select_resolved_many ~evaluate:unavailable ~purpose rows in
  Alcotest.(check int) "provider outage is one request, no split" 2 !calls;
  Alcotest.(check bool) "outage preserves all candidate uncertainty" true
    (List.for_all (function Selection.Deferred {reason=Evaluation_failed "offline";_} -> true
      | _ -> false) results)

let test_resolved_capacity_split_keeps_full_details () =
  let rows = List.map (fun id -> {candidate with id},`Assoc ["original",`String id])
      ["left";"oversized";"right"] in
  let attempts = ref [] in
  let evaluate ~state ~questions =
    let ids = List.map fst questions in
    attempts := ids :: !attempts;
    Alcotest.(check bool) "split keeps exact purpose" true
      (Yojson.Safe.Util.member "current_purpose" state = purpose);
    Yojson.Safe.Util.(state |> member "candidates" |> to_list) |> List.iter (fun row ->
      let id = Yojson.Safe.Util.(row |> member "question_id" |> to_string) in
      Alcotest.(check bool) "full detail survives each provider-capacity partition" true
        (Yojson.Safe.Util.member "source_detail" row = `Assoc ["original",`String id]));
    if List.length ids > 1 || ids=["oversized"] then Error (Selection.Capacity_refused "fixture")
    else Ok (batch_response questions "current_decision") in
  (match Selection.select_resolved_many ~evaluate ~purpose rows with
   | [Selected {candidate={id="left";_};_};
      Deferred {candidate={id="oversized";_};reason=Capacity_unresolved _};
      Selected {candidate={id="right";_};_}] -> ()
   | _ -> Alcotest.fail "capacity failure must preserve unresolved singleton and valid peers");
  Alcotest.(check int) "refused singleton is not retried" 1
    (List.length (List.filter ((=) ["oversized"]) !attempts))

let host_inventory hash = `Assoc
  ["status",`String "available";"ledger_sha256",`String hash;
   "claims",`List [`Assoc ["id",`String candidate.id;"text",`String candidate.summary;
     "members",`List [`Assoc ["keeper_id",`String "source-keeper"]]]];
   "conflicts",`List []]

let host_detail hash version = `Assoc
  ["found",`Bool true;"id",`String candidate.id;"ledger_sha256",`String hash;
   "source_version",`Int version;"scope",`String "another environment"]

let test_host_selection_preserves_comparison_and_purpose () =
  let module Host = Masc.Keeper_workspace_memory_host_recall.For_testing in
  let reads = ref 0 in
  let summary () = Ok (host_inventory "ledger-a") in
  let detail ~id = incr reads; Alcotest.(check string) "source ID stays bound" candidate.id id;
    Ok (host_detail "ledger-a" 1) in
  let evaluate ~state ~questions =
    if Yojson.Safe.Util.member "current_purpose" state = `String "compare environments"
    then Ok (batch_response questions "comparison") else Ok (batch_response questions "not_needed") in
  let require = function Ok value -> value | Error detail -> Alcotest.fail detail in
  let selected = Host.collect ~summary ~detail ~evaluate ~purpose:(`String "compare environments") () |> require in
  let rows = Yojson.Safe.Util.(selected |> member "selected" |> to_list) in
  Alcotest.(check int) "one scoped memory selected" 1 (List.length rows);
  Alcotest.(check string) "different environment is comparison, not current authority" "comparison"
    Yojson.Safe.Util.(List.hd rows |> member "use" |> to_string);
  Alcotest.(check int) "selected source is resolved then revalidated" 2 !reads;
  let omitted = Host.collect ~summary ~detail ~evaluate ~purpose:(`String "unrelated purpose") () |> require in
  Alcotest.(check int) "same memory is omitted for another purpose" 0
    Yojson.Safe.Util.(omitted |> member "selected" |> to_list |> List.length);
  Alcotest.(check int) "omission does not fetch unrelated sources" 2 !reads

let test_host_rejects_source_change_during_judgment () =
  let version = ref 1 in
  let summary () = Ok (host_inventory "ledger-a") in
  let detail ~id:_ = Ok (host_detail "ledger-a" !version) in
  let evaluate ~state ~questions =
    if Yojson.Safe.Util.(state |> member "candidates" |> to_list
        |> List.exists (fun row -> member "source_detail" row <> `Null)) then version := 2;
    Ok (batch_response questions "comparison") in
  match Masc.Keeper_workspace_memory_host_recall.For_testing.collect ~summary ~detail ~evaluate ~purpose () with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "source change during evaluation must prevent publication"

let test_host_rejects_ledger_change_during_judgment () =
  let hash = ref "ledger-a" in
  let summary () = Ok (host_inventory !hash) in
  let detail ~id:_ = Ok (host_detail "ledger-a" 1) in
  let evaluate ~state:_ ~questions = hash := "ledger-b"; Ok (batch_response questions "not_needed") in
  match Masc.Keeper_workspace_memory_host_recall.For_testing.collect ~summary ~detail ~evaluate ~purpose () with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "a changed ledger cannot establish that its memories are irrelevant"

let test_host_failure_is_not_empty_success () =
  let summary () = Ok (host_inventory "ledger-a") in
  let detail ~id:_ = Alcotest.fail "failed assessment cannot select source" in
  let evaluate ~state:_ ~questions:_ = Error (Selection.Unavailable "provider unavailable") in
  match Masc.Keeper_workspace_memory_host_recall.For_testing.collect ~summary ~detail ~evaluate ~purpose () with
  | Error detail -> Alcotest.fail detail
  | Ok result ->
    Alcotest.(check string) "unassessed memory remains visibly unresolved" "partially_unavailable"
      Yojson.Safe.Util.(result |> member "status" |> to_string);
    Alcotest.(check int) "no successful irrelevance judgment invented" 0
      Yojson.Safe.Util.(result |> member "not_needed_count" |> to_int)

let test_host_never_dispatches_excluded_source_summaries () =
  let summary () = Ok (host_inventory "ledger-a") in
  let detail ~id:_ = Alcotest.fail "excluded source was resolved" in
  let evaluate ~state:_ ~questions:_ = Alcotest.fail "excluded source summary reached the provider" in
  match Masc.Keeper_workspace_memory_host_recall.For_testing.collect
      ~is_excluded:(fun keeper -> keeper="source-keeper") ~summary ~detail ~evaluate ~purpose () with
  | Error detail -> Alcotest.fail detail
  | Ok result ->
    Alcotest.(check int) "excluded source is withheld, not judged irrelevant" 1
      Yojson.Safe.Util.(result |> member "source_policy_withheld_count" |> to_int);
    Alcotest.(check int) "no false irrelevance judgment" 0
      Yojson.Safe.Util.(result |> member "not_needed_count" |> to_int)

let test_host_refreshes_one_snapshot_per_phase_for_many_candidates () =
  let ids = List.init 200 (fun i -> Printf.sprintf "claim-%d" i) in
  let summary () = Ok (`Assoc
    ["status",`String "available";"ledger_sha256",`String "ledger-a";
     "claims",`List (List.map (fun id -> `Assoc
       ["id",`String id;"text",`String "Relevant source observation";
        "members",`List [`Assoc ["keeper_id",`String "source-keeper"]]]) ids);
     "conflicts",`List []]) in
  let generations = ref 0 in
  let changed = ref false in
  let detail_snapshot () =
    incr generations;
    let version = if !changed && !generations = 2 then 2 else 1 in
    fun ~id -> Ok (`Assoc ["found",`Bool true;"id",`String id;
      "ledger_sha256",`String "ledger-a";"source_version",`Int version]) in
  let assessments = ref 0 in
  let evaluate ~state:_ ~questions =
    incr assessments;
    Ok (batch_response questions "comparison") in
  let collect () = Masc.Keeper_workspace_memory_host_recall.For_testing.collect_with_snapshots
    ~summary ~detail_snapshot ~evaluate ~purpose in
  (match collect () with
   | Error detail -> Alcotest.fail detail
   | Ok result -> Alcotest.(check int) "all selected IDs survive shared source resolution" 200
       Yojson.Safe.Util.(result |> member "selected" |> to_list |> List.length));
  Alcotest.(check int) "source snapshot belongs to assessment and publication phases" 2 !generations;
  Alcotest.(check int) "200 candidates use two model batches" 2 !assessments;
  generations := 0;
  changed := true;
  match collect () with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "cached assessment sources replaced the fresh publication check"

let test_batch_partial_and_malformed_answers_stay_deferred () =
  let candidates = [candidate; {candidate with id="second"}] in
  let calls = ref 0 in
  let evaluate ~state:_ ~questions =
    incr calls;
    let result = batch_response questions "comparison" in
    if !calls = 1 then Ok {result with answers=List.tl result.answers}
    else Ok result in
  let resolved = ref [] in
  let resolve ~id = resolved := id :: !resolved; Ok source in
  (match Selection.select_many ~evaluate ~resolve ~purpose candidates with
   | [Deferred {reason=Invalid_answer _;_}; Selected {candidate={id="second";_};_}] -> ()
   | _ -> Alcotest.fail "a missing answer must remain deferred without losing valid peers");
  Alcotest.(check (list string)) "only answered candidate reaches its source" ["second"] !resolved;
  List.iter (fun malformed ->
    let evaluate ~state:_ ~questions =
      let result = batch_response questions "comparison" in
      let first = List.hd result.answers in
      Ok {result with answers=if malformed then first::result.answers
        else ("unknown",snd first)::result.answers} in
    let resolve ~id:_ = Alcotest.fail "invalid answer IDs authorized source access" in
    let outcomes = Selection.select_many ~evaluate ~resolve ~purpose candidates in
    Alcotest.(check bool) "ambiguous batch identity defers all candidates" true
      (List.for_all (function Selection.Deferred {reason=Invalid_answer _;_} -> true | _ -> false) outcomes))
    [true;false];
  let evaluate ~state:_ ~questions:_ = Alcotest.fail "empty batch dispatched" in
  Alcotest.(check int) "empty inventory needs no judgment" 0
    (List.length (Selection.select_many ~evaluate ~resolve ~purpose []))

let test_batch_identity_survives_filtering_and_answer_reordering () =
  let candidates = List.map (fun id -> {candidate with id}) ["omit";"production";"staging"] in
  let stages = ref [] in
  let evaluate ~state ~questions =
    let ids = List.map fst questions in
    stages := !stages @ [ids];
    let rows = Yojson.Safe.Util.(state |> member "candidates" |> to_list) in
    List.iter (fun row ->
      Alcotest.(check string) "question identity is the stable memory ID"
        Yojson.Safe.Util.(row |> member "candidate" |> member "id" |> to_string)
        Yojson.Safe.Util.(row |> member "question_id" |> to_string)) rows;
    let answers = List.map (fun (id,_) ->
      let choice = match id with "omit" -> "not_needed" | "production" -> "current_decision"
        | "staging" -> "comparison" | _ -> Alcotest.fail "unexpected ID" in
      id,snd (List.hd (response choice).answers)) questions in
    Ok {Types.model="fixture";usage=None;answers=List.rev answers} in
  let resolve ~id = Ok (`Assoc ["id",`String id]) in
  (match Selection.select_many ~evaluate ~resolve ~purpose candidates with
   | [Not_needed _;Selected {use=For_current_decision;_};Selected {use=For_comparison;_}] -> ()
   | _ -> Alcotest.fail "answer order or filtered peers changed candidate scope");
  Alcotest.(check (list (list string))) "source stage retains IDs after omission"
    [["omit";"production";"staging"];["production";"staging"]] !stages;
  let evaluate ~state:_ ~questions:_ = Alcotest.fail "duplicate memory IDs reached provider" in
  let result = Selection.select_many ~evaluate ~resolve ~purpose [candidate;candidate] in
  Alcotest.(check bool) "ambiguous source identities defer without dispatch" true
    (List.for_all (function Selection.Deferred {reason=Invalid_answer _;_} -> true | _ -> false) result)

let capacity_attempt status body : Masc.Typesafeai_client.attempt =
  {destination_uri="https://fixture.invalid/evaluate";model="fixture";
   refusal=Http_response_failure {status;body;destination_uri="https://fixture.invalid/evaluate";detail="fixture"}}

let test_capacity_protocol_is_exact_and_receipted () =
  let module Client = Masc.Typesafeai_client in
  let body = {|{"detail":{"error_type":"max_tokens_exceeded"}}|} in
  let first_attempt = capacity_attempt 400 body in
  let failure : Client.failure = {first_attempt;later_attempts=[]} in
  Alcotest.(check bool) "observed protocol refusal is capacity evidence" true
    (Client.failure_kind failure = Capacity_refused);
  List.iter (fun refusal ->
    Alcotest.(check bool) "other or ambiguous refusals do not authorize splitting" true
      (Client.failure_kind {failure with first_attempt=refusal} = Other_refusal))
    [capacity_attempt 503 body;capacity_attempt 400 "max_tokens_exceeded";
     capacity_attempt 400 {|{"detail":{"error_type":"other","message":"max_tokens_exceeded"}}|};
     capacity_attempt 400 {|{"detail":{"error_type":"max_tokens_exceeded","error_type":"other"}}|};
     {first_attempt with refusal=Transport_failure "offline"}];
  Alcotest.(check bool) "mixed destination failures are not all-capacity" true
    (Client.failure_kind {failure with later_attempts=[capacity_attempt 503 body]} = Other_refusal);
  with_adapter (fun adapter _ ->
    let module IO = Masc.Keeper_workspace_memory_selection_io in
    let call ~destinations:_ ~state:_ ~questions:_ () = Error failure in
    (match IO.For_testing.evaluate_with ~call adapter ~state:purpose ~questions:[] with
     | Error (Selection.Capacity_refused _) -> ()
     | _ -> Alcotest.fail "durable adapter lost typed capacity evidence");
    let records = Fs_compat.load_file (IO.journal_path adapter) |> String.split_on_char '\n'
      |> List.filter (fun s -> s<>"") |> List.map Yojson.Safe.from_string in
    Alcotest.(check (list string)) "refusal is retained before split permission returns"
      ["started";"provider_failed"]
      (List.map (fun row -> Yojson.Safe.Util.(row |> member "status" |> to_string)) records))

let test_capacity_split_preserves_rows_and_singleton_failure () =
  let candidates = List.map (fun id -> {candidate with id}) ["a";"b";"oversized";"d";"e"] in
  let calls = ref [] in
  let evaluate ~state ~questions =
    Alcotest.(check bool) "purpose survives every capacity split" true
      (Yojson.Safe.Util.member "current_purpose" state = purpose);
    let ids = List.map fst questions in
    calls := ids :: !calls;
    (* The fixture provider accepts at most two questions. This is a provider
       refusal under test, not a configured product batch-size limit. *)
    if List.length ids > 2 || List.mem "oversized" ids then
      Error (Selection.Capacity_refused "fixture provider capacity")
    else Ok (batch_response questions "comparison") in
  let resolve ~id =
    if id="oversized" then Alcotest.fail "unassessed oversized memory was resolved";
    Ok (`Assoc ["id",`String id]) in
  (match Selection.select_many ~evaluate ~resolve ~purpose candidates with
   | [Selected _;Selected _;Deferred {candidate={id="oversized";_};reason=Capacity_unresolved _};Selected _;Selected _] -> ()
   | _ -> Alcotest.fail "split lost order, valid peers or singleton uncertainty");
  Alcotest.(check int) "refused singleton is attempted once, not looped" 1
    (List.length (List.filter ((=) ["oversized"]) !calls));
  let failures = ref 0 in
  let evaluate ~state:_ ~questions:_ = incr failures; Error (Selection.Unavailable "offline") in
  let outcomes = Selection.select_many ~evaluate ~resolve ~purpose candidates in
  Alcotest.(check int) "outage does not amplify into per-candidate retries" 1 !failures;
  Alcotest.(check bool) "all outage candidates stay deferred" true
    (List.for_all (function Selection.Deferred {reason=Evaluation_failed _;_} -> true | _ -> false) outcomes)

let test_provider_capacity_projection_keeps_whole_records_and_receipts () =
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  let module Host = Masc.Keeper_workspace_memory_host_recall in
  let row id = `Assoc ["id",`String id;"use",`String "comparison";
    "sources",`String (id ^ String.make 2000 'x')] in
  let payload = `Assoc ["selection_id",`String "selection-fixture";
    "status",`String "selected";"selected",`List [row "a";row "b";row "c";row "d"]] in
  let saved = ref [] in
  let can_save = ref false in
  let validate_ok = ref true in
  let retain ~reason:_ ~payload =
    if !can_save then (saved := payload :: !saved; Ok ()) else Error "disk unavailable" in
  let prepared = Host.For_testing.prepare_projection ~payload ~retain
    ~validate:(fun _ -> if !validate_ok then Ok () else Error "source changed") in
  let original = Host.render_prepared prepared in
  let refusal = Agent_core.Error.Api (ContextOverflow {message="fixture";limit=None}) in
  (match Host.defer_for_capacity prepared ~refusal with
   | Error _ -> () | Ok _ -> Alcotest.fail "undurable reduction was admitted");
  Alcotest.(check string) "failed receipt preserves original projection" original (Host.render_prepared prepared);
  can_save := true;
  let transmitted = ref [] in
  let attempt ~capacity =
    Alcotest.(check int) "host-only reduction keeps the history capacity" 100 capacity;
    let text = Host.render_prepared prepared in
    transmitted := text :: !transmitted;
    if String.length text >= String.length original then Error refusal else Ok text in
  (match Masc.Keeper_turn_driver_try_provider.context_overflow_shrink_sequence
      ~starting_capacity:100 ~same_run_retry_authorized:(fun () -> true)
      ~shrink_capacity:(fun ~capacity ~default_capacity:_ -> capacity)
      ~shrink_admits_history:(fun ~capacity:_ -> false)
      ~on_shrink_retry:(fun ~shrink_attempt:_ ~previous_capacity:_ ~capacity:_ ->
        Alcotest.fail "host recovery dropped conversation history")
      ~on_memory_capacity_refusal:(Host.defer_for_capacity prepared)
      ~attempt () with
   | Ok _ -> () | Error _ -> Alcotest.fail "rendered host projection did not recover provider refusal");
  Alcotest.(check int) "provider sees refused then smaller evidence projection" 2 (List.length !transmitted);
  let reduced = Host.render_prepared prepared in
  Alcotest.(check bool) "actual rendered context shrinks" true (String.length reduced < String.length original);
  let retained = List.hd !saved in
  Alcotest.(check bool) "records are retained whole, never text-truncated" true
    (Yojson.Safe.Util.member "selected" retained = `List [row "a";row "b"]);
  Alcotest.(check int) "gap is explicit" 2
    Yojson.Safe.Util.(retained |> member "capacity_deferred_count" |> to_int);
  validate_ok := false;
  let unavailable = Host.render_prepared prepared in
  Alcotest.(check bool) "changed sources cannot reappear on the next retry" false
    (String_util.contains_substring unavailable (String.make 2000 'x'));
  (match Host.defer_for_capacity prepared ~refusal with
   | Ok Unchanged -> () | _ -> Alcotest.fail "empty evidence projection authorized another retry")

let () = Alcotest.run "purpose-specific workspace memory selection"
  ["selection",[
    Alcotest.test_case "resolved first assessment sees full lineage" `Quick
      test_resolved_sources_are_present_before_any_omission;
    Alcotest.test_case "resolved inspection and partial answers remain unresolved" `Quick
      test_resolved_partial_answers_and_inspection_stay_deferred;
    Alcotest.test_case "resolved capacity partition preserves full sources" `Quick
      test_resolved_capacity_split_keeps_full_details;
    Alcotest.test_case "resolved source changes selection use" `Quick test_source_can_change_how_a_memory_is_used;
    Alcotest.test_case "unrelated purpose avoids source read" `Quick test_unrelated_memory_does_not_fetch_sources;
    Alcotest.test_case "source failure is not irrelevance" `Quick test_source_failure_is_not_a_negative_relevance_vote;
    Alcotest.test_case "unresolved applicability stays pending" `Quick test_unresolved_source_does_not_loop;
    Alcotest.test_case "invalid judgment retains uncertainty" `Quick test_invalid_judgment_does_not_deliver_or_discard_memory;
    Alcotest.test_case "request precedes dispatch durably" `Quick test_request_is_durable_before_dispatch;
    Alcotest.test_case "failed request record prevents dispatch" `Quick test_failed_record_prevents_dispatch;
    Alcotest.test_case "failed response record prevents delivery" `Quick test_failed_response_record_prevents_delivery;
    Alcotest.test_case "host preserves purpose and comparison scope" `Quick test_host_selection_preserves_comparison_and_purpose;
    Alcotest.test_case "host rejects changed sources" `Quick test_host_rejects_source_change_during_judgment;
    Alcotest.test_case "host rejects changed ledger" `Quick test_host_rejects_ledger_change_during_judgment;
    Alcotest.test_case "host failure is not empty success" `Quick test_host_failure_is_not_empty_success;
    Alcotest.test_case "host honors source Keeper exclusion before dispatch" `Quick test_host_never_dispatches_excluded_source_summaries;
    Alcotest.test_case "200 candidates share phase snapshots and refresh before publication" `Quick
      test_host_refreshes_one_snapshot_per_phase_for_many_candidates;
    Alcotest.test_case "batch missing and malformed answers retain uncertainty" `Quick
      test_batch_partial_and_malformed_answers_stay_deferred;
    Alcotest.test_case "batch question identities survive filtering and reordered answers" `Quick
      test_batch_identity_survives_filtering_and_answer_reordering;
    Alcotest.test_case "capacity protocol is exact and retained before use" `Quick
      test_capacity_protocol_is_exact_and_receipted;
    Alcotest.test_case "capacity split retains peers and singleton uncertainty" `Quick
      test_capacity_split_preserves_rows_and_singleton_failure;
    Alcotest.test_case "provider capacity projects whole records only after durable receipt" `Quick
      test_provider_capacity_projection_keeps_whole_records_and_receipts]]
