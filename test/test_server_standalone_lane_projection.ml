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
            { outcome = Verification.Approved { reason = "" }
            ; evaluator_runtime = Some "verifier-primary"
            ; elapsed_s = 2.
            ; tools = []
            }
      }
    ]
  in
  let resolve_lane lane_id =
    Projection.Configured
      { admitted_slots = [ lane_id ^ "-primary" ]
      ; cli_slots = []
      ; dropped_slots = []
      ; admission_error = None
      }
  in
  let json =
    Projection.For_testing.snapshot_json_with
      ~now:110.
      ~resolve_lane
      ~exact_runs_total:(List.length exact_runs)
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
    "four fixed lanes"
    4
    (json |> Yojson.Safe.Util.member "lanes" |> Yojson.Safe.Util.to_list |> List.length);
  let status lane_id =
    lane_by_id json lane_id
    |> Yojson.Safe.Util.member "status"
    |> Yojson.Safe.Util.to_string
  in
  check string "board running" "running" (status "board_attention_exact");
  check string "hitl idle" "idle" (status "hitl_auto_judge");
  check string "librarian degraded" "degraded" (status "librarian_exact");
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

(* Lane audit W5+W7: the verifier lane's success means A VERDICT WAS
   PRODUCED — an exhausted evaluator (Not_reviewed) counts as failed — and a
   server-restart orphan's synthesised duration (now - started_at) must not
   enter the latency percentile, while still bounding last_terminal_at. *)
let test_no_verdict_is_failed_and_synthetic_elapsed_skips_p50 () =
  let exact_runs =
    [ exact_run
        ~run_id:"librarian-measured"
        ~lane:Exact.Librarian
        ~started_at:80.
        ~status:
          (Exact.Completed
             { outcome = Exact.Failed { code = "provider"; detail = "offline" }
             ; elapsed_s = 8.
             ; output = `Null
             ; selected_slot = None
             })
    ; exact_run
        ~run_id:"librarian-restart-orphan"
        ~lane:Exact.Librarian
        ~started_at:10.
        ~status:
          (Exact.Completed
             { outcome =
                 Exact.Failed { code = "server_restarted"; detail = "orphan" }
             ; elapsed_s = 100000.
             ; output = `Null
             ; selected_slot = None
             })
    ]
  in
  let verification_runs : Verification.run list =
    [ { verification_id = "verify-exhausted"
      ; task_id = "task-2"
      ; producer = "keeper-test"
      ; authority_kind = "completion"
      ; authority_actor = "operator"
      ; started_at = 70.
      ; status =
          Verification.Completed
            { outcome = Verification.Not_reviewed { gate = "Evaluator_unavailable"; detail = "exhausted" }
            ; evaluator_runtime = None
            ; elapsed_s = 2.
            ; tools = []
            }
      }
    ]
  in
  let resolve_lane lane_id =
    Projection.Configured
      { admitted_slots =
          (if String.equal lane_id "hitl_auto_judge" then [] else [ "slot" ])
      ; cli_slots =
          (if String.equal lane_id "hitl_auto_judge"
           then [ "antigravity_subscription.gemini-3-7-flash-high" ]
           else [])
      ; dropped_slots =
          (if String.equal lane_id "librarian_exact"
           then [ "slot-typo" ]
           else [])
      ; admission_error = None
      }
  in
  let json =
    Projection.For_testing.snapshot_json_with
      ~now:110.
      ~resolve_lane
      ~exact_runs_total:(List.length exact_runs)
      ~exact_runs
      ~verification_runs
      ~goal_verification_runs:[]
  in
  let field lane_id name =
    lane_by_id json lane_id |> Yojson.Safe.Util.member name
  in
  check int
    "an exhausted evaluator counts as a lane failure"
    1
    (field Runtime.verifier_exact_lane_id "failed_count"
     |> Yojson.Safe.Util.to_int);
  check int
    "no verdict means no lane success"
    0
    (field Runtime.verifier_exact_lane_id "succeeded_count"
     |> Yojson.Safe.Util.to_int);
  check bool
    "p50 comes from measured durations only"
    true
    (match field "librarian_exact" "p50_elapsed_s" with
     | `Float value -> Float.equal value 8.
     | _ -> false);
  (* Lane audit W4: a declared-but-inadmissible slot is visible per lane, so
     "configured single" and "configured double, one dropped" stop looking
     identical on this surface. *)
  check bool
    "dropped slots are surfaced per lane"
    true
    (match field "librarian_exact" "dropped_slots" with
     | `List [ `String "slot-typo" ] -> true
     | _ -> false);
  check bool
    "a lane with nothing dropped says so"
    true
    (match field "hitl_auto_judge" "dropped_slots" with
     | `List [] -> true
     | _ -> false);
  (* RFC cli-runtimes-as-lane-slots: the declared cli suffix is on the wire,
     and a lane whose only slots are cli ones is ready, not degraded. *)
  check bool
    "cli slots are surfaced per lane"
    true
    (match field "hitl_auto_judge" "cli_slots" with
     | `List [ `String "antigravity_subscription.gemini-3-7-flash-high" ] -> true
     | _ -> false);
  check string
    "a cli-only lane is ready"
    "ready"
    (field "hitl_auto_judge" "configuration_state" |> Yojson.Safe.Util.to_string);
  check bool
    "an http-only lane carries an empty cli list"
    true
    (match field "librarian_exact" "cli_slots" with
     | `List [] -> true
     | _ -> false)
;;

let test_latest_terminal_uses_completion_time () =
  let exact_runs =
    [ exact_run
        ~run_id:"started-later-finished-first"
        ~lane:Exact.Librarian
        ~started_at:100.
        ~status:
          (Exact.Completed
             { outcome = Exact.Failed { code = "early"; detail = "early" }
             ; elapsed_s = 1.
             ; output = `Null
             ; selected_slot = Some "secondary"
             })
    ; exact_run
        ~run_id:"started-first-finished-last"
        ~lane:Exact.Librarian
        ~started_at:90.
        ~status:
          (Exact.Completed
             { outcome = Exact.Succeeded
             ; elapsed_s = 20.
             ; output = `Null
             ; selected_slot = Some "primary"
             })
    ]
  in
  let json =
    Projection.For_testing.snapshot_json_with
      ~now:120.
      ~resolve_lane:(fun lane_id ->
        Projection.Configured
          { admitted_slots = [ lane_id ^ "-primary" ]
      ; cli_slots = []
      ; dropped_slots = []
      ; admission_error = None
      })
      ~exact_runs_total:10
      ~exact_runs
      ~verification_runs:[]
      ~goal_verification_runs:[]
  in
  let librarian = lane_by_id json "librarian_exact" in
  check bool
    "bounded exact projection is explicit"
    true
    (json
     |> Yojson.Safe.Util.member "exact_run_projection_truncated"
     |> Yojson.Safe.Util.to_bool);
  check int
    "source total"
    10
    (json |> Yojson.Safe.Util.member "exact_run_source_total" |> Yojson.Safe.Util.to_int);
  check string
    "status follows last completion"
    "idle"
    (librarian |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  check string
    "outcome follows last completion"
    "succeeded"
    (librarian
     |> Yojson.Safe.Util.member "last_outcome"
     |> Yojson.Safe.Util.to_string);
  check (float 0.)
    "terminal timestamp"
    110.
    (librarian
     |> Yojson.Safe.Util.member "last_terminal_at"
     |> Yojson.Safe.Util.to_float)
;;

let () =
  run
    "server standalone lane projection"
    [ ( "snapshot"
      , [ test_case
            "all four lanes and observation states"
            `Quick
            test_snapshot_names_every_lane_and_keeps_observed_truth
        ; test_case
            "latest terminal is ordered by completion time"
            `Quick
            test_latest_terminal_uses_completion_time
        ; test_case
            "no verdict is failed; synthetic elapsed skips p50"
            `Quick
            test_no_verdict_is_failed_and_synthetic_elapsed_skips_p50
        ] )
    ]
;;
