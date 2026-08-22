open Alcotest
open Masc

module R = Goal_verification_run_registry

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
    ~review_kind:R.Proof
    ~authority_actor:"verifier_exact"
    ~started_at:10.0;
  R.mark_completed
    registry
    ~run_id
    ~outcome:R.Committed
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

let test_running_attempt_is_not_claimed_after_restart () =
  with_path
  @@ fun path ->
  let registry = R.create ~path () in
  R.register_running
    registry
    ~run_id:"goal-run-interrupted"
    ~goal_id:"goal-interrupted"
    ~review_kind:R.Proof
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
    ~review_kind:R.Proof
    ~authority_actor:"verifier_exact"
    ~started_at:20.0;
  R.mark_completed
    registry
    ~run_id
    ~outcome:R.Reviewed
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
