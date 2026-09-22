open Alcotest
module E = Masc.Librarian_working_state_evaluation
module R = Masc.Librarian_continuity_report
module S = Masc.Librarian_continuity_snapshot
module U = Yojson.Safe.Util
let get = function Ok value -> value | Error error -> fail error
let message text = Agent_core.Types.make_message ~role:Agent_core.Types.User [Agent_core.Types.Text text]
let case : E.case =
  {id="paired"; trace_id="synthetic-paired"; absolute_turn=1;
   prefix=[message "Prefix secret: ORCHID-731; await permission."];
   suffix=[message "Later suffix: keep waiting."];
   facts=[{R.id="fact-a"; claim="Existing Memory fact."}]; question="What remains pending?"}
let request prompt : R.generation_request =
  {runtime_id="fixture-runtime"; requested_model="fixture-model"; prompt; prepared_requests=[]}
let generation prompt text : R.generation =
  {request=request prompt; response={response_id="fixture-response";model="actual-fixture";text}}
let failure prompt : R.failed_generation =
  {request=request prompt;error="fixture-generation-failure";incomplete_response=None}
let judgment (request : R.judge_request) : R.judgment =
  {request;response_model="fixture-judge";request_body_sha256=String.make 64 'a'; probability=0.}
let with_path f =
  Eio_main.run @@ fun env -> Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir=Filename.temp_dir "paired-evaluation-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree dir)
    (fun () -> f (Filename.concat dir "snapshot.json"))
let evaluate path ~generate ~judge ~save =
  E.evaluate_case ~generate ~judge ~judge_endpoint:"https://synthetic.invalid/evaluate"
    ~judge_model:"requested-judge" ~snapshot_path:path ~save case
let test_isolation_and_roundtrip () = with_path @@ fun path ->
  let prompts=ref [] and judgments=ref [] and saves=ref [] in
  let generate prompt = prompts := !prompts @ [prompt];
    Ok (generation prompt (if List.length !prompts=1 then "Await permission; code ORCHID-731." else "Permission is pending.")) in
  let progress=evaluate path ~generate
    ~judge:(fun request -> judgments:=request::!judgments; Ok (judgment request))
    ~save:(fun progress ->
      if !saves=[] then (match progress.E.work with
        | E.Work_ready _ -> check bool "work saved before snapshot side effect" false (Sys.file_exists path)
        | _ -> fail "first save omitted successful generation");
      saves:=progress::!saves; Ok ()) |> get in
  (match !prompts with
   | [work; baseline; restored] ->
     let work=Yojson.Safe.from_string work.R.user in
     check (list string) "working request sees only prefix" ["prefix"] (List.map fst (U.to_assoc work));
     let baseline=Yojson.Safe.from_string baseline.R.user and restored=Yojson.Safe.from_string restored.R.user in
     check string "same question" (U.member "question" baseline |> U.to_string) (U.member "question" restored |> U.to_string);
     check string "same Memory facts" (U.member "facts" baseline |> Yojson.Safe.to_string) (U.member "facts" restored |> Yojson.Safe.to_string);
     check int "baseline receives full history" 2 (U.member "messages" baseline |> U.to_list |> List.length);
     check int "restored receives suffix only" 1 (U.member "messages" restored |> U.to_list |> List.length);
     let loaded= S.load ~path |> Result.map_error S.error_to_string |> get in
     check string "restored state comes from saved artifact" loaded.working_state (U.member "working_state" restored |> U.to_string)
   | _ -> fail "expected work plus two answer requests");
  check int "both judges called" 2 (List.length !judgments);
  (match progress.baseline,progress.restored with
   | R.Scored left,R.Scored right ->
     check (float 0.) "zero stays a successful raw judgment" 0. left.judgment.probability;
     check (float 0.) "both raw probabilities retained" 0. right.judgment.probability
   | _ -> fail "paired scores missing")
let test_work_failure_keeps_baseline () = with_path @@ fun path ->
  let calls=ref 0 in
  let generate prompt = incr calls; if !calls=1 then Error (failure prompt) else Ok (generation prompt "Baseline answer") in
  let progress=evaluate path ~generate ~judge:(fun request -> Ok (judgment request)) ~save:(fun _ -> Ok ()) |> get in
  (match progress.work,progress.baseline,progress.restored with
   | E.Work_failed _,R.Scored _,R.Not_started -> () | _ -> fail "work failure suppressed or fabricated an arm");
  check int "baseline still generated" 2 !calls;
  check bool "failed work creates no snapshot" false (Sys.file_exists path)
let test_arm_failures_are_independent () = with_path @@ fun path ->
  let judges=ref 0 in
  let progress=evaluate path ~generate:(fun prompt -> Ok (generation prompt "Synthetic answer"))
    ~judge:(fun request -> incr judges; if !judges=1 then Error "judge unavailable" else Ok (judgment request))
    ~save:(fun _ -> Ok ()) |> get in
  (match progress.baseline,progress.restored with
   | R.Judge_failed _,R.Scored _ -> () | _ -> fail "judge failure became zero or suppressed restored arm");
  let calls=ref 0 in
  let progress=evaluate (path ^ ".second") ~generate:(fun prompt -> incr calls;
    if !calls=2 then Error (failure prompt) else Ok (generation prompt "Synthetic answer"))
    ~judge:(fun request -> Ok (judgment request)) ~save:(fun _ -> Ok ()) |> get in
  match progress.baseline,progress.restored with
  | R.Answer_failed _,R.Scored _ -> () | _ -> fail "answer failure suppressed restored arm"
let test_disk_failure_stops_before_more_calls () = with_path @@ fun path ->
  let calls=ref 0 in
  let result=evaluate path ~generate:(fun prompt -> incr calls; Ok (generation prompt "Work"))
    ~judge:(fun _ -> fail "judge after failed persistence") ~save:(fun _ -> Error "disk full") in
  check bool "disk failure propagated" true (result=Error "disk full");
  check int "no later generation after disk failure" 1 !calls;
  check bool "snapshot not written before work receipt" false (Sys.file_exists path)
let test_dataset () =
  let json=`Assoc ["provenance",R.provenance_to_yojson R.Synthetic;"cases",`List [E.case_to_yojson case]] in
  ignore (E.parse_dataset json |> get);
  let bad=`Assoc ["provenance",`List [`String "Observed"];"cases",`List [E.case_to_yojson case]] in
  check bool "non-synthetic rejected" true (Result.is_error (E.parse_dataset bad));
  let fields=E.case_to_yojson case |> U.to_assoc in
  let bad=`Assoc ["provenance",R.provenance_to_yojson R.Synthetic;"cases",`List [`Assoc
    (List.map (fun (key,value) -> key,if key="prefix" then `List [`Null] else value) fields)]] in
  check bool "malformed canonical message rejected without exception" true (Result.is_error (E.parse_dataset bad))
let () = run "working-state paired evaluation"
  ["pipeline",[test_case "isolation and snapshot roundtrip" `Quick test_isolation_and_roundtrip;
    test_case "working failure preserves baseline" `Quick test_work_failure_keeps_baseline;
    test_case "independent answer and judge failures" `Quick test_arm_failures_are_independent;
    test_case "disk failure stops progress" `Quick test_disk_failure_stops_before_more_calls;
    test_case "synthetic dataset and canonical message validation" `Quick test_dataset]]
