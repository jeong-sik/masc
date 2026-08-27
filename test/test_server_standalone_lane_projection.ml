open Alcotest

module Projection = Server_standalone_lane_projection
module Exact = Masc.Exact_lane_run_registry
module Verification = Masc.Verification_run_registry

let exact_run ~run_id ~lane ~started_at ~status : Exact.run =
  { run_id
  ; lane
  ; actor = "keeper-test"
  ; started_at
  ; input = Exact.Exact_input (`Assoc [])
  ; status
  }
;;

let lane_by_id json lane_id =
  json
  |> Yojson.Safe.Util.member "lanes"
  |> Yojson.Safe.Util.to_list
  |> List.find (fun lane ->
    String.equal
      lane_id
      (lane |> Yojson.Safe.Util.member "lane_id" |> Yojson.Safe.Util.to_string))
;;

let test_snapshot_names_every_lane_and_keeps_observed_truth () =
  let exact_runs =
    [ exact_run
        ~run_id:"board-running"
        ~lane:Exact.Board_attention
        ~started_at:100.
        ~status:Exact.Running
    ; exact_run
        ~run_id:"hitl-completed"
        ~lane:Exact.Hitl_auto_judge
        ~started_at:90.
        ~status:
          (Exact.Completed
             { outcome = Exact.Succeeded
             ; elapsed_s = 4.
             ; output = `Assoc []
             ; selected_slot = Some "hitl-primary"
             })
    ; exact_run
        ~run_id:"librarian-failed"
        ~lane:Exact.Librarian
        ~started_at:80.
        ~status:
          (Exact.Completed
             { outcome = Exact.Failed { code = "provider"; detail = "offline" }
             ; elapsed_s = 8.
             ; output = `Null
             ; selected_slot = Some "librarian-secondary"
             })
    ]
  in
  let verification_runs : Verification.run list =
    [ { verification_id = "verify-1"
      ; task_id = "task-1"
      ; producer = "keeper-test"
      ; authority_kind = "completion"
      ; authority_actor = "operator"
      ; started_at = 70.
      ; status =
          Verification.Completed
            { outcome = Verification.Approved
            ; evaluator_runtime = Some "verifier-primary"
            ; elapsed_s = 2.
            ; tools = []
            }
      }
    ]
  in
  let resolve_lane lane_id =
    Projection.Configured
      { admitted_slots = [ lane_id ^ "-primary" ]; admission_error = None }
  in
  let json =
    Projection.For_testing.snapshot_json_with
      ~now:110.
      ~resolve_lane
      ~exact_runs
      ~verification_runs
      ~goal_verification_runs:[]
  in
  check bool
    "observation only"
    true
    (json
     |> Yojson.Safe.Util.member "observation_only"
     |> Yojson.Safe.Util.to_bool);
  check int
    "five fixed lanes"
    5
    (json |> Yojson.Safe.Util.member "lanes" |> Yojson.Safe.Util.to_list |> List.length);
  let status lane_id =
    lane_by_id json lane_id
    |> Yojson.Safe.Util.member "status"
    |> Yojson.Safe.Util.to_string
  in
  check string "board running" "running" (status "board_attention_exact");
  check string "hitl idle" "idle" (status "hitl_auto_judge");
  check string "librarian degraded" "degraded" (status "librarian_exact");
  check string
    "compaction has no retained observation"
    "no_retained_observation"
    (status "compaction_exact");
  check string "verifier idle" "idle" (status Runtime.verifier_exact_lane_id);
  let hitl_slots =
    lane_by_id json "hitl_auto_judge"
    |> Yojson.Safe.Util.member "selected_slots"
    |> Yojson.Safe.Util.to_list
  in
  match hitl_slots with
  | [ slot ] ->
    check string
      "selected slot"
      "hitl-primary"
      (slot |> Yojson.Safe.Util.member "slot_id" |> Yojson.Safe.Util.to_string);
    check int
      "selected slot count"
      1
      (slot |> Yojson.Safe.Util.member "count" |> Yojson.Safe.Util.to_int)
  | _ -> fail "expected one selected HITL slot"
;;

let () =
  run
    "server standalone lane projection"
    [ ( "snapshot"
      , [ test_case
            "all five lanes and observation states"
            `Quick
            test_snapshot_names_every_lane_and_keeps_observed_truth
        ] )
    ]
;;
