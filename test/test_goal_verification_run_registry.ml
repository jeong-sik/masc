open Alcotest
open Masc

module R = Goal_verification_run_registry

let criterion = Goal_store.Criterion
  { revision = "criterion-original"; title = "Verify three services";
    metric = Some "verified services"; target_value = Some "3" }


let with_path f =
  let path = Filename.temp_file "goal_verification_runs_" ".jsonl" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () -> f path)
;;

let sample_tool () : Verification_run_registry.tool_observation =
  { tool_name = "verification_read_file"
  ; input =
      `Assoc
        [ "producer", `String "builder"
        ; "file_path", `String "artifacts/proof.txt"
        ]
  ; disposition = Tool_result.Completed ()
  ; output_excerpt = "proof bytes"
  ; output_truncated = false
  ; duration_ms = 3.0
  ; finished_at = 12.5
  }
;;

let test_completed_run_replays_with_tool_evidence () =
  with_path
  @@ fun path ->
  let registry = R.create ~path () in
  let run_id = "goal-run-completed" in
  R.register_running
    registry
    ~run_id
    ~goal_id:"goal-a"
    ~request_id:"proof-request-original" ~criterion ~review_kind:R.Proof
    ~authority_actor:"verifier_exact"
    ~started_at:10.0;
  R.mark_completed
    registry
    ~run_id
    ~outcome:R.Committed ~evaluated_verdict:(Some (R.Approved { reason = "three services verified" }))
    ~tools:[ sample_tool () ]
    ~evaluator_runtime:"runtime-a"
    ~elapsed_s:2.5
    ();
  match R.get (R.replay path) ~run_id with
  | Some
      { goal_id = "goal-a"
      ; review_kind = R.Proof
      ; authority_actor = "verifier_exact"
      ; status =
          R.Completed
            { outcome = R.Committed
            ; evaluator_runtime = Some "runtime-a"
            ; tools = [ tool ]
            ; _
            }
      ; _
      } ->
    check string "replayed tool" "verification_read_file" tool.tool_name
  | _ -> fail "completed Goal verification run did not replay"
;;

let test_cancelled_review_preserves_its_observations_after_restart () =
  with_path @@ fun path ->
  let registry = R.create ~path () in
  let run_id = "goal-run-cancelled" in
  let detail = "review fiber cancelled after reading the measurement" in
  R.register_running registry ~run_id ~goal_id:"goal-cancelled"
    ~request_id:"proof-request-original" ~criterion ~review_kind:R.Proof ~authority_actor:"verifier_exact" ~started_at:10.0;
  R.mark_completed registry ~run_id ~outcome:(R.Review_cancelled { detail }) ~evaluated_verdict:None
    ~tools:[ sample_tool () ] ~evaluator_runtime:"runtime-a" ~elapsed_s:2.5 ();
  let before = match R.get registry ~run_id with
    | Some run -> R.run_to_yojson run |> Yojson.Safe.to_string
    | None -> fail "cancelled run was not recorded before restart"
  in
  match R.get (R.replay path) ~run_id with
  | Some ({ status = R.Completed
      { outcome = R.Review_cancelled { detail = retained_detail };
        tools = [ tool ]; evaluator_runtime = Some "runtime-a"; _ }; _ } as run) ->
    check string "cancellation explanation survives" detail retained_detail;
    check string "lookup result survives" "proof bytes" tool.output_excerpt;
    check string "every projected observation survives replay" before
      (R.run_to_yojson run |> Yojson.Safe.to_string)
  | _ -> fail "persisted cancellation disappeared or changed after restart"
;;

let test_superseded_review_retains_its_bound_criterion_and_verdict () =
  with_path @@ fun path ->
  let registry = R.create ~path () in
  let run_id = "superseded-review" in
  let evaluated_verdict = Some (R.Approved { reason = "three services reached target three" }) in
  R.register_running registry ~run_id ~goal_id:"goal-revised"
    ~request_id:"request-before-edit" ~criterion
    ~review_kind:R.Proof ~authority_actor:"verifier_exact" ~started_at:10.;
  R.mark_completed registry ~run_id ~outcome:R.Reviewed ~evaluated_verdict
    ~tools:[ sample_tool () ] ~evaluator_runtime:"runtime-a" ~elapsed_s:2. () ;
  (* The evaluated verdict must already survive a restart before commit runs. *)
  (match R.get (R.replay path) ~run_id with
   | Some { status = R.Completed { outcome = R.Reviewed; evaluated_verdict = Some (R.Approved _); _ }; _ } -> ()
   | _ -> fail "evaluated verdict was not durable before commit");
  R.mark_completed registry ~run_id
    ~outcome:(R.Superseded { detail = "a new proof request replaced the reviewed criterion" })
    ~evaluated_verdict ~tools:[ sample_tool () ] ~evaluator_runtime:"runtime-a" ~elapsed_s:3. () ;
  match R.get (R.replay path) ~run_id with
  | Some { request_id; criterion = retained_criterion;
      status = R.Completed { outcome = R.Superseded _;
        evaluated_verdict = Some (R.Approved { reason }); tools = [ tool ]; _ }; _ } ->
    check string "original request retained" "request-before-edit" request_id;
    check bool "frozen criterion retained" true (Goal_store.criterion_equal criterion retained_criterion);
    check string "evaluated approval retained" "three services reached target three" reason;
    check string "lookup evidence retained" "proof bytes" tool.output_excerpt
  | _ -> fail "superseded review lost its historical evidence"
;;

let test_judged_run_without_verdict_is_not_replayed_as_judged () =
  List.iter (fun outcome -> with_path (fun path ->
    let registry = R.create ~path () in
    let run_id = "invalid-judged-run" in
    R.register_running registry ~run_id ~goal_id:"goal-a"
      ~request_id:"request-a" ~criterion ~review_kind:R.Proof
      ~authority_actor:"verifier_exact" ~started_at:10.;
    R.mark_completed registry ~run_id ~outcome
      ~evaluated_verdict:(Some (R.Approved { reason = "measured three" }))
      ~tools:[] ~elapsed_s:1. ();
    (match R.get (R.replay path) ~run_id with Some _ -> () | None -> fail "valid baseline did not replay");
    let lines = In_channel.with_open_bin path In_channel.input_all
      |> String.split_on_char '\n' |> List.filter (fun line -> line <> "") in
    let malformed = List.map (fun line ->
      match Yojson.Safe.from_string line with
      | `Assoc fields ->
        `Assoc (List.map (function
          | "completion", `Assoc completion ->
            "completion", `Assoc (List.map (function
              | "evaluated_verdict", _ -> "evaluated_verdict", `Null
              | field -> field) completion)
          | field -> field) fields)
      | json -> json) lines in
    Out_channel.with_open_bin path (fun ch -> List.iter (fun json ->
      output_string ch (Yojson.Safe.to_string json ^ "\n")) malformed);
    match R.get (R.replay path) ~run_id with
    | None -> ()
    | Some _ -> fail "a missing verdict replayed as a completed judgement"))
    [ R.Reviewed; R.Committed ]
;;

let test_running_attempt_is_not_claimed_after_restart () =
  with_path
  @@ fun path ->
  let registry = R.create ~path () in
  R.register_running
    registry
    ~run_id:"goal-run-interrupted"
    ~goal_id:"goal-interrupted"
    ~request_id:"proof-request-original" ~criterion ~review_kind:R.Proof
    ~authority_actor:"verifier_exact"
    ~started_at:20.0;
  check int "replayed running attempts are dropped" 0
    (List.length (R.list_runs (R.replay path)))
;;

let test_reviewed_observation_survives_replay () =
  with_path
  @@ fun path ->
  let registry = R.create ~path () in
  let run_id = "goal-run-reviewed" in
  R.register_running
    registry
    ~run_id
    ~goal_id:"goal-reviewed"
    ~request_id:"proof-request-original" ~criterion ~review_kind:R.Proof
    ~authority_actor:"verifier_exact"
    ~started_at:20.0;
  R.mark_completed
    registry
    ~run_id
    ~outcome:R.Reviewed ~evaluated_verdict:(Some (R.Approved { reason = "three services verified" }))
    ~tools:[ sample_tool () ]
    ~evaluator_runtime:"runtime-a"
    ~elapsed_s:2.5
    ();
  match R.get (R.replay path) ~run_id with
  | Some
      { status =
          R.Completed
            { outcome = R.Reviewed; tools = [ tool ]; _ }
      ; _
      } ->
    check string "replayed reviewed tool" "verification_read_file" tool.tool_name
  | _ -> fail "reviewed Goal verification observation did not replay"
;;

let () =
  run
    "goal verification run registry"
    [ ( "durability"
      , [ test_case
            "completed run replays with tool evidence"
            `Quick
            test_completed_run_replays_with_tool_evidence
        ; test_case
            "cancelled review preserves observations after restart"
            `Quick
            test_cancelled_review_preserves_its_observations_after_restart
        ; test_case
            "superseded review retains criterion and evaluated verdict"
            `Quick
            test_superseded_review_retains_its_bound_criterion_and_verdict
        ; test_case
            "judged run without verdict does not replay as judged"
            `Quick
            test_judged_run_without_verdict_is_not_replayed_as_judged
        ; test_case
            "running attempt is not claimed after restart"
            `Quick
            test_running_attempt_is_not_claimed_after_restart
        ; test_case
            "reviewed observation survives restart"
            `Quick
            test_reviewed_observation_survives_replay
        ] )
    ]
;;
