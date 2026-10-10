open Alcotest
module Selection = Masc.Keeper_memory_successor_selection
module Current = Masc.Keeper_memory_os_current
module Memory = Masc.Keeper_memory_os_types
module Jev = Masc.Typesafeai_types

let fact claim = Memory.observed ~claim ~category:Memory.Fact ~now:100.
  ~origin:{kind=Memory.Authored;trace_id="successor-fixture"}
let candidate : Current.successor_recall_candidate =
  let original_target = fact "Production releases R-001 through R-200 require owner approval." in
  let target = fact "Production R-015 now requires two independent approvals; other releases retain owner approval." in
  {binding={candidate_id={queue_generation="generation";request_id="request";sequence=15;
      input_sha256=String.make 64 'a'};
    source_fact=fact "Production R-015 requires owner approval.";
    target_memory_id=Memory.memory_id original_target};
   born_revision=1;original_target;target;
   path=[{snapshot_revision=2;recorded_at=200.;source={kind=Current.Librarian;trace_id="revision"};
     commit_effect=Some Current.Rewritten;
     revision_links=Some [{superseded=Memory.memory_id original_target;superseded_by=Memory.memory_id target}];
     removed_memory_ids=[Memory.memory_id original_target];added_memory_ids=[Memory.memory_id target]}]}
let response choice : Jev.eval_response =
  {model="fixture";usage=None;answers=["applicability",Jev.Choice_answer
    {choice;confidence=1.;probabilities=List.map (fun label -> label,if label=choice then 1. else 0.)
      ["applies_to_query";"different_scope";"uncertain"]}]}
let test_corrected_truth_uses_current_target () =
  let evaluate ~state ~questions:_ =
    let evidence=Yojson.Safe.Util.member "evidence" state in
    check bool "old observation and changed current truth reach judgment separately" true
      (Yojson.Safe.Util.member "historical_source" evidence=Memory.fact_to_json candidate.binding.source_fact
       && Yojson.Safe.Util.member "current_target" evidence=Memory.fact_to_json candidate.target);
    Ok (response "applies_to_query") in
  let selected=Selection.select_with_evaluate ~evaluate ~query:"R-015" [candidate] in
  check bool "accepted lookup returns the current target with provenance" true (selected.selected=[candidate]);
  check int "accepted judgment has no unresolved branch" 0 (List.length selected.unresolved)
let test_other_scope_and_uncertainty_are_distinct () =
  let select choice=Selection.select_with_evaluate
    ~evaluate:(fun ~state:_ ~questions:_ -> Ok (response choice)) ~query:"staging R-015" [candidate] in
  let different=select "different_scope" and uncertain=select "uncertain" in
  check bool "different scope is omitted conclusively" true (different.selected=[] && different.unresolved=[]);
  match uncertain.selected,uncertain.unresolved with
  | [],[_,Selection.Judgment_uncertain] -> ()
  | _ -> fail "uncertainty became absence or current knowledge"
let test_one_provider_failure_preserves_other_judgments () =
  let other={candidate with target=fact "A separately scoped current successor."} in
  let calls=ref 0 in
  let evaluate ~state:_ ~questions:_ = incr calls;
    if !calls=1 then Error (Masc.Keeper_workspace_memory_selection.Unavailable "unavailable")
    else Ok (response "applies_to_query") in
  let result=Selection.select_with_evaluate ~evaluate ~query:"release" [candidate;other] in
  check bool "later successful scope survives an earlier failure" true (result.selected=[other]);
  match result.unresolved with
  | [original,Selection.Evaluation_failed _] -> check bool "failure retains exact candidate" true (original=candidate)
  | _ -> fail "provider failure lost unresolved provenance"
let test_extra_answers_never_publish () =
  let answer=response "applies_to_query" in
  let result=Selection.select_with_evaluate ~query:"R-015" [candidate]
    ~evaluate:(fun ~state:_ ~questions:_ -> Ok {answer with answers=answer.answers @ answer.answers}) in
  match result.selected,result.unresolved with
  | [],[_,Selection.Invalid_answer _] -> ()
  | _ -> fail "extra answer authorized current lookup"
let test_negative_judgment_cannot_survive_changed_successor () =
  let old_snapshot : Current.t =
    {revision=2;updated_at=200.;source={kind=Current.Librarian;trace_id="before-judge"};
     facts=[candidate.target];change={added=[candidate.target];removed=[];retained=0;invalidated=[]}} in
  let different = Selection.select_with_evaluate ~query:"staging R-015" [candidate]
    ~evaluate:(fun ~state:_ ~questions:_ -> Ok (response "different_scope")) in
  let stable : Current.successor_recall = {receipt_verification=Ok ();snapshot=Some old_snapshot;direct_bindings=[];
    successor_candidates=[candidate];unresolved=[]} in
  let stable_result = Selection.revalidate ~snapshot:(Some old_snapshot) ~candidates:[candidate]
    ~current:stable different in
  check bool "unchanged negative judgment remains conclusive" true
    (stable_result.selected=[] && stable_result.unresolved=[]);
  let changed_target=fact "Production and staging R-015 now require two independent approvals." in
  let changed_candidate={candidate with target=changed_target} in
  let changed={stable with snapshot=Some {old_snapshot with revision=3;facts=[changed_target]};
    successor_candidates=[changed_candidate]} in
  let result=Selection.revalidate ~snapshot:(Some old_snapshot) ~candidates:[candidate]
    ~current:changed different in
  (match result.selected,result.unresolved with
   | [],[old,Selection.Evidence_changed] -> check bool "negative belongs to the old successor" true (old=candidate)
   | _ -> fail "a negative answer about old B hid changed successor C");
  let checked_again=Selection.revalidate ~snapshot:(Some old_snapshot) ~candidates:[candidate]
    ~current:changed result in
  check int "second publication check does not duplicate unresolved evidence" 1
    (List.length checked_again.unresolved)
(* An endpoint that accepts the judgment request and never answers. The turn
   clock passed to [run] must end that request at the HTTP request timeout;
   without it the search never returns. The mock clock is moved past any
   request timeout until the call returns, and a real-time guard fails the
   test instead of hanging it. *)
let far_past_any_request_timeout = 1e6
let real_time_guard_seconds = 10.0

let test_a_stalled_endpoint_ends_at_the_turn_clock () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env and real_clock = Eio.Stdenv.clock env in
  Eio_context.with_test_env ~net ~clock:real_clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  let base_path = Filename.temp_dir "successor-stalled-endpoint-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  let socket = Eio.Net.listen net ~sw ~backlog:4 ~reuse_addr:true
    (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port | _ -> fail "stalled endpoint has no TCP port" in
  let accepted, accept = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let _held = Eio.Net.accept ~sw socket in
    Eio.Promise.resolve accept ();
    Eio.Fiber.await_cancel ());
  let key = "MASC_TEST_SUCCESSOR_STALLED_KEY" in
  Masc_test_deps.with_process_env key (Some "synthetic-stalled-key") @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    {Runtime_schema.default_typesafeai with lane_enabled=true; absorb_gate=false; excluded_keepers=[];
     destinations=({Runtime_schema.endpoint=Printf.sprintf "http://127.0.0.1:%d/evaluate" port;
                    model="jev-fixture"; api_key_env=key},[])} @@ fun () ->
  let config = Masc.Workspace.default_config base_path in
  let keeper_id = "successor-stalled-keeper" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let clock = Eio_mock.Clock.make () in
  let judged = Eio.Fiber.fork_promise ~sw (fun () ->
    Selection.run ~clock:(Some clock) ~config ~keepers_dir ~keeper_id ~query:"R-015"
      ~snapshot:None [candidate]) in
  Eio.Time.with_timeout_exn real_clock real_time_guard_seconds (fun () ->
    Eio.Promise.await accepted;
    (* The request timeout's watcher registers its sleep at an unknown point
       after the request starts; keep moving the clock until it has fired. *)
    let rec push () =
      if not (Eio.Promise.is_resolved judged) then begin
        Eio_mock.Clock.set_time clock (Eio.Time.now clock +. far_past_any_request_timeout);
        Eio.Time.sleep real_clock 0.05;
        push ()
      end in
    push ());
  (match Eio.Promise.await_exn judged with
   | {Selection.selected=[]; unresolved=[_, _]} -> ()
   | _ -> fail "a stalled judgment must leave its candidate unresolved");
  let journal = Filename.concat (Filename.concat (Masc.Workspace.keepers_runtime_dir config) keeper_id)
    "memory-selection-evaluations.jsonl" in
  let statuses = match Fs_compat.load_file_opt journal with
    | None -> []
    | Some text -> String.split_on_char '\n' text
      |> List.filter (fun line -> String.trim line <> "")
      |> List.map (fun line -> Yojson.Safe.(from_string line |> Util.member "status" |> Util.to_string)) in
  check (list string) "the stalled request ended as a provider failure"
    ["started"; "provider_failed"]
    (List.filter (fun status -> List.mem status ["started"; "provider_failed"; "response_received"; "cancelled"])
       statuses)

let () = run "successor scope selection"
  ["judgment",[test_case "corrected truth preserves identity not old wording" `Quick test_corrected_truth_uses_current_target;
    test_case "different scope and uncertainty remain distinct" `Quick test_other_scope_and_uncertainty_are_distinct;
    test_case "one failed assessment does not erase another" `Quick test_one_provider_failure_preserves_other_judgments;
    test_case "extra answers cannot publish" `Quick test_extra_answers_never_publish;
    test_case "negative decision becomes unresolved when successor changes" `Quick test_negative_judgment_cannot_survive_changed_successor;
    test_case "a stalled endpoint ends at the turn clock" `Quick test_a_stalled_endpoint_ends_at_the_turn_clock]]
