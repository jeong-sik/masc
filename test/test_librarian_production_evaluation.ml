open Alcotest
open Masc
module E = Librarian_production_evaluation
module R = Librarian_continuity_report
module L = Keeper_librarian_runtime
module F = Exact_output_fixture
module J = Yojson.Safe.Util

let get = function Ok value -> value | Error detail -> fail detail
let msg value = Agent_core.Types.make_message ~role:Agent_core.Types.User [Agent_core.Types.Text value]
let case : E.case =
  {id="actual-lane";previous_state=Some "Earlier work remains pending.";unread_messages=[];
   suffix=[msg "FUTURE-SUFFIX"];
   question="EVALUATION-QUESTION";
   source={Keeper_librarian.turn_ref=Ids.Turn_ref.make ~trace_id:"synthetic-production" ~absolute_turn:1;
     keeper_id=Masc_test_deps.keeper_id_fixture "production-evaluator";
     keeper_instructions="Respect pending approval.";goal_context=Keeper_librarian.No_task;
     historical_task_contexts=[];working_context=Keeper_librarian_context.empty;
     current=Some {facts=[Keeper_memory_os_types.observed ~claim:"A build is required."
       ~category:Keeper_memory_os_types.Fact ~now:0.
       ~origin:{kind=Keeper_memory_os_types.Authored;trace_id="synthetic-production"}]};
     messages=[msg "PREFIX-CODE ORCHID-731. Await approval."];
     tool_observations=[];counterpart_observations=[]}}
let contains needle value = String.split_on_char '\n' value
  |> List.exists (fun line ->
      let rec at index = index+String.length needle <= String.length line &&
        (String.sub line index (String.length needle)=needle || at (index+1)) in at 0)
let generation prompt text : R.generation =
  {request={runtime_id="answer-fixture";requested_model="fixture";prompt;prepared_requests=[]};
   response={response_id="answer";model="fixture";text}}
let judgment (request : R.judge_request) : R.judgment =
  {request;response_model="judge-fixture";request_body_sha256=String.make 64 'a';probability=0.}
let fixture f =
  Masc_test_deps.with_process_env Env_config.KeeperMemoryOs.librarian_env_key (Some "true") @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  Fs_compat.set_fs env#fs;
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  let base_path=Filename.temp_dir "librarian-production-test-" "" in
  Fun.protect ~finally:(fun () ->
    Prompt_registry.clear_prompt_override Prompt_names.librarian_continuity;
    Fs_compat.remove_tree base_path) (fun () ->
    let root=match Sys.getenv_opt "DUNE_SOURCEROOT" with Some root -> root | None -> Sys.getcwd () in
    Prompt_registry.set_markdown_dir (Filename.concat root "config/prompts");
    let keepers_dir=Common.keepers_runtime_dir_of_base ~base_path in
    let infer ~previous_state ~unread_messages input =
      L.infer_working_state ~base_path ~keepers_dir ~keeper_id:"production-evaluator"
        ~previous_state ~unread_messages input in
    f ~sw ~env ~base_path ~infer)
let evaluate ~infer ~path ~generate ~judge ~save =
  E.evaluate_case ~infer ~generate ~judge ~judge_endpoint:"https://synthetic.invalid/evaluate"
    ~judge_model:"fixture" ~snapshot_path:path ~save case

let test_actual_preparation_and_paired_restore () = fixture @@ fun ~sw ~env ~base_path ~infer ->
  let changed="LATE-PROMPT-CHANGE" in
  let server=F.start_server ~sw ~net:env#net ~clock:env#clock
    ~on_request_before_reply:(fun () ->
      Prompt_registry.set_override Prompt_names.librarian_continuity changed |> get)
    (F.Reply (F.openai_response (`Assoc ["working_state",`String "Await approval; ORCHID-731."]))) in
  ignore (F.publish_registry ~lane_id:"librarian_exact" ~slot_ids:["production-slot"]
    (F.resolver_snapshot ~source:"synthetic-production-test" [{F.id="production-slot";base_url=server.base_url}]));
  let prompts=ref [] and references=ref [] and stages=ref [] in
  let path=Filename.concat base_path "snapshot.json" in
  let progress=evaluate ~infer ~path
    ~generate:(fun prompt -> prompts:= !prompts @ [prompt];Ok (generation prompt "Approval is pending."))
    ~judge:(fun request -> references:=request.R.reference::!references;Ok (judgment request))
    ~save:(fun progress ->
      (match progress.E.work with
       | E.Work_started -> check int "persist start before actual dispatch" 0 (F.post_count server)
       | E.Work_not_started | E.Work_finished _ -> ());
      stages:=progress::!stages;Ok ()) |> get in
  let inference=match progress.work with
    | E.Work_finished inference -> inference
    | E.Work_not_started | E.Work_started -> fail "actual inference evidence missing" in
  (match inference.outcome with
   | L.Inferred {served_by;working_state=_} -> (match served_by with
     | L.Api_slot id -> check string "actual served slot" "production-slot" id
     | L.Cli_slot _ -> fail "unexpected CLI slot")
   | L.Not_inferred _ -> fail "actual inference failed");
  let prepared=match inference.preparation with
    | L.Prompt_prepared prepared -> prepared
    | L.Not_prepared | L.Prompt_failed _ -> fail "actual preparation missing" in
  check bool "actual prefix in prepared production template" true (contains "PREFIX-CODE" prepared.rendered_prompt);
  check bool "question is absent from inference" false (contains case.question prepared.rendered_prompt);
  check bool "future suffix is absent from inference" false (contains "FUTURE-SUFFIX" prepared.rendered_prompt);
  check bool "prior state reaches actual production preparation" true (contains "Earlier work" prepared.rendered_prompt);
  check bool "preparation cannot be re-resolved after reply" false (contains changed prepared.rendered_prompt);
  check string "captured actual requirement" (Yojson.Safe.to_string Keeper_structured_output_schema.librarian_continuity_state_output_schema)
    (Yojson.Safe.to_string prepared.output_schema);
  check int "one actual inference POST" 1 (F.post_count server);
  let loaded=Librarian_continuity_snapshot.load ~path |> Result.map_error Librarian_continuity_snapshot.error_to_string |> get in
  (match !prompts with
   | [baseline;restored] ->
     let baseline=Yojson.Safe.from_string baseline.R.user and restored=Yojson.Safe.from_string restored.R.user in
     check bool "baseline retains source prefix" true (contains "PREFIX-CODE" (Yojson.Safe.to_string (J.member "source" baseline)));
     check bool "restoration does not leak source prefix" false (contains "PREFIX-CODE" (Yojson.Safe.to_string (J.member "source" restored)));
     check string "restoration uses actual loaded state" loaded.working_state (J.member "working_state" restored |> J.to_string);
     check string "same current Memory" (J.member "source" baseline |> J.member "current" |> Yojson.Safe.to_string)
       (J.member "source" restored |> J.member "current" |> Yojson.Safe.to_string)
   | [] | [_] | _::_::_ -> fail "paired answer prompts missing");
  check int "same reference for both judges" 1 (List.sort_uniq String.compare !references |> List.length);
  let score = function
    | R.Scored value -> value.judgment.probability
    | R.Not_started | R.Question_failed _ | R.Question_ready _ | R.Answer_failed _
    | R.Answer_ready _ | R.Judge_failed _ -> fail "actual arm outcome missing" in
  check (float 0.) "zero remains a raw successful score" 0. (score progress.baseline);
  check (float 0.) "both raw scores retained" 0. (score progress.restored)

let test_unread_hole_and_independent_judges () = fixture @@ fun ~sw ~env ~base_path ~infer ->
  let server=F.start_server ~sw ~net:env#net ~clock:env#clock
    (F.Reply (F.openai_response (`Assoc ["working_state",`String "The original code remains unread."]))) in
  ignore (F.publish_registry ~lane_id:"librarian_exact" ~slot_ids:["hole-slot"]
    (F.resolver_snapshot ~source:"synthetic-hole" [{F.id="hole-slot";base_url=server.base_url}]));
  let trace_id=Ids.Turn_ref.trace_id case.source.turn_ref in
  let hole=Keeper_librarian_unread.for_atom ~trace_id ~history_start_boundary_line:1
    ~atom:0 ~message_in_atom:0 ~messages:case.source.messages
    ~reasons:[Keeper_librarian_input_refusal.Input_capacity] |> get in
  let context : Keeper_librarian_task_context.t =
    {scope={source=Atom_span {trace_id;start_atom=0;end_atom=1};attribution=Unattributed};
     first_message=0;after_message=1;first_tool_observation=0;after_tool_observation=0} in
  let case={case with unread_messages=[hole];
    source={case.source with historical_task_contexts=[context]}} in
  let judges=ref 0 in
  let progress=E.evaluate_case ~infer ~generate:(fun prompt -> Ok (generation prompt "Unknown code."))
    ~judge:(fun request -> incr judges;
      if !judges=1 then Error "baseline judge unavailable" else Ok (judgment request))
    ~judge_endpoint:"https://synthetic.invalid/evaluate" ~judge_model:"fixture"
    ~snapshot_path:(Filename.concat base_path "hole.json") ~save:(fun _ -> Ok ()) case |> get in
  (match progress.selected_source with
   | None -> fail "actual selected input missing"
   | Some selected ->
     check int "all-hole original is not sent back to inference" 0 (List.length selected.messages);
     match selected.historical_task_contexts with
     | [selected] ->
       check int "historical start remapped" 0 selected.first_message;
       check int "historical end remapped" 0 selected.after_message
     | [] | _::_::_ -> fail "historical provenance missing");
  (match progress.work with
   | E.Work_finished inference -> (match inference.preparation with
     | L.Prompt_prepared prepared ->
       check bool "hole body absent from actual production prompt" false (contains "PREFIX-CODE" prepared.rendered_prompt)
     | L.Not_prepared | L.Prompt_failed _ -> fail "hole-only inference did not prepare")
   | E.Work_not_started | E.Work_started -> fail "hole-only inference did not finish");
  (match progress.snapshot with
   | E.Snapshot_ready snapshot ->
     check string "actual snapshot preserves original hole"
       (Yojson.Safe.to_string (Keeper_librarian_unread.list_to_json [hole]))
       (Yojson.Safe.to_string (Keeper_librarian_unread.list_to_json snapshot.unread_messages))
   | E.Snapshot_not_started | E.Snapshot_failed _ -> fail "hole snapshot missing");
  (match progress.baseline with
   | R.Judge_failed _ -> ()
   | R.Not_started | R.Question_failed _ | R.Question_ready _ | R.Answer_failed _ | R.Answer_ready _ | R.Scored _ ->
     fail "baseline judgment failure hidden");
  match progress.restored with
  | R.Scored _ -> ()
  | R.Not_started | R.Question_failed _ | R.Question_ready _ | R.Answer_failed _ | R.Answer_ready _ | R.Judge_failed _ ->
    fail "baseline judgment failure suppressed restored arm"

let test_actual_invalid_output_keeps_baseline () = fixture @@ fun ~sw ~env ~base_path ~infer ->
  let server=F.start_server ~sw ~net:env#net ~clock:env#clock
    (F.Reply (F.openai_response (`Assoc ["working_state",`String ""]))) in
  ignore (F.publish_registry ~lane_id:"librarian_exact" ~slot_ids:["invalid-slot"]
    (F.resolver_snapshot ~source:"synthetic-invalid-output" [{F.id="invalid-slot";base_url=server.base_url}]));
  let answers=ref 0 and path=Filename.concat base_path "absent.json" in
  let progress=evaluate ~infer ~path ~generate:(fun prompt -> incr answers;Ok (generation prompt "Baseline."))
    ~judge:(fun request -> Ok (judgment request)) ~save:(fun _ -> Ok ()) |> get in
  (match progress.work with
   | E.Work_finished inference -> (match inference.preparation,inference.outcome with
     | L.Prompt_prepared _,L.Not_inferred failure ->
       check bool "domain refusal does not grant unread authority" true (failure.exhausted_input_refusals=None);
       check bool "failure reports remain" true (failure.reports<>[])
     | (L.Not_prepared | L.Prompt_failed _ | L.Prompt_prepared _),(L.Inferred _ | L.Not_inferred _) ->
       fail "invalid output became success or lost preparation")
   | E.Work_not_started | E.Work_started -> fail "inference did not finish");
  check int "failed work still runs baseline" 1 !answers;
  check bool "failed inference creates no snapshot" false (Sys.file_exists path);
  match progress.restored with
  | R.Not_started -> ()
  | R.Question_failed _ | R.Question_ready _ | R.Answer_failed _ | R.Answer_ready _ | R.Judge_failed _ | R.Scored _ ->
    fail "failed inference fabricated restored outcome"

let test_save_failure_prevents_inference () = fixture @@ fun ~sw:_ ~env:_ ~base_path ~infer ->
  let called=ref false in
  let result=evaluate ~infer:(fun ~previous_state ~unread_messages input ->
      called:=true;infer ~previous_state ~unread_messages input)
    ~path:(Filename.concat base_path "absent.json")
    ~generate:(fun prompt -> Ok (generation prompt "Unreachable"))
    ~judge:(fun request -> Ok (judgment request)) ~save:(fun _ -> Error "report unavailable") in
  check bool "no paid or local inference before start receipt" false !called;
  match result with Ok _ -> fail "report failure hidden" | Error detail -> check string "original failure" "report unavailable" detail

let () = run "Librarian production comparison"
  ["actual inference and artifact",
    [test_case "actual preparation survives later prompt mutation and pairs real restoration" `Quick test_actual_preparation_and_paired_restore;
     test_case "unread bodies stay out of inference and one judge failure preserves the other" `Quick test_unread_hole_and_independent_judges;
     test_case "actual domain failure preserves baseline and authority" `Quick test_actual_invalid_output_keeps_baseline;
     test_case "report refusal stops before inference" `Quick test_save_failure_prevents_inference]]
