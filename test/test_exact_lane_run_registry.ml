open Alcotest
module R = Masc.Exact_lane_run_registry

let remove_if_exists path =
  try Sys.remove path with
  | Sys_error _ -> ()
;;

let test_round_trip_preserves_exact_evidence () =
  let path = Filename.temp_file "exact-lane-runs-" ".jsonl" in
  remove_if_exists path;
  let registry = R.create ~path () in
  R.register_running
    registry
    ~run_id:"run-1"
    ~lane:R.Librarian
    ~subject_id:"trace-1"
    ~actor:"keeper-a"
    ~started_at:10.0
    ~input:(`Assoc [ "message_count", `Int 4 ]);
  R.mark_completed
    registry
    ~run_id:"run-1"
    ~outcome:R.Succeeded
    ~elapsed_s:0.5
    ~output:(`Assoc [ "fact_count", `Int 3 ]);
  let replayed = R.replay path in
  let original = R.get registry ~run_id:"run-1" |> Option.get |> R.run_to_yojson in
  let restored = R.get replayed ~run_id:"run-1" |> Option.get |> R.run_to_yojson in
  check string "round trip" (Yojson.Safe.to_string original) (Yojson.Safe.to_string restored);
  remove_if_exists path
;;

let test_running_shape_has_no_invented_completion () =
  let registry = R.create () in
  R.register_running
    registry
    ~run_id:"run-live"
    ~lane:R.Board_attention
    ~subject_id:"candidate-1"
    ~actor:"keeper-a"
    ~started_at:20.0
    ~input:`Null;
  let run = R.get registry ~run_id:"run-live" |> Option.get in
  check string "status" "running" (R.status_label run.status);
  match R.run_to_yojson run with
  | `Assoc fields ->
    check bool "no elapsed" false (List.mem_assoc "elapsed_s" fields);
    check bool "no output" false (List.mem_assoc "output" fields)
  | _ -> fail "run serializer must emit an object"
;;

let () =
  run
    "exact_lane_run_registry"
    [ ( "registry"
      , [ test_case "durable exact evidence" `Quick test_round_trip_preserves_exact_evidence
        ; test_case "running shape" `Quick test_running_shape_has_no_invented_completion
        ] )
    ]
