open Alcotest
module R = Masc.Exact_lane_run_registry

let remove_if_exists path =
  try Sys.remove path with
  | Sys_error _ -> ()
;;

let write_file path content =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () -> output_string channel content)
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
    ~input:(R.Exact_input (`Assoc [ "message_count", `Int 4 ]));
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
    ~input:(R.Exact_input `Null);
  let run = R.get registry ~run_id:"run-live" |> Option.get in
  check string "status" "running" (R.status_label run.status);
  match R.run_to_yojson run with
  | `Assoc fields ->
    check bool "no elapsed" false (List.mem_assoc "elapsed_s" fields);
    check bool "no output" false (List.mem_assoc "output" fields)
  | _ -> fail "run serializer must emit an object"
;;

let test_research_trace_path_is_typed_by_registry_envelope () =
  let registry = R.create () in
  let input =
    R.Research_input
      { raw_trace_path = Some "/tmp/keeper/raw-traces/research.jsonl"
      ; payload = `Assoc [ "message_count", `Int 4 ]
      }
  in
  R.register_running
    registry
    ~run_id:"research-1"
    ~lane:R.Librarian
    ~subject_id:"trace-1"
    ~actor:"keeper-a"
    ~started_at:20.0
    ~input;
  check
    (list string)
    "registered research path"
    [ "/tmp/keeper/raw-traces/research.jsonl" ]
    (R.research_raw_trace_paths registry ~actor:"keeper-a");
  check
    (list string)
    "other actor cannot retain the path"
    []
    (R.research_raw_trace_paths registry ~actor:"keeper-b")
;;

let test_open_json_input_is_not_replayed_into_current_store () =
  let path = Filename.temp_file "exact-lane-runs-v1-" ".jsonl" in
  write_file
    path
    {|{"event":"register","id":"old-run","started_at":1.0,"registration":{"lane":"librarian_exact","subject_id":"trace-old","actor":"keeper-a","input":{"message_count":4}}}
|};
  let replayed = R.replay path in
  check int "old open input is absent" 0 (List.length (R.list_runs replayed));
  check string "current-only store file" "exact-lane-runs-v2.jsonl" R.storage_filename;
  remove_if_exists path
;;

let test_blank_research_trace_path_is_rejected_before_persistence () =
  let registry = R.create () in
  check_raises
    "blank trace path"
    (Invalid_argument "exact lane research raw trace path must not be blank")
    (fun () ->
       R.register_running
         registry
         ~run_id:"research-blank"
         ~lane:R.Librarian
         ~subject_id:"trace-blank"
         ~actor:"keeper-a"
         ~started_at:20.0
         ~input:(R.Research_input { raw_trace_path = Some "  "; payload = `Null }))
;;

let () =
  run
    "exact_lane_run_registry"
    [ ( "registry"
      , [ test_case "durable exact evidence" `Quick test_round_trip_preserves_exact_evidence
        ; test_case "running shape" `Quick test_running_shape_has_no_invented_completion
        ; test_case "research trace reachability envelope" `Quick
            test_research_trace_path_is_typed_by_registry_envelope
        ; test_case "open JSON input is not replayed" `Quick
            test_open_json_input_is_not_replayed_into_current_store
        ; test_case "blank research trace path is rejected" `Quick
            test_blank_research_trace_path_is_rejected_before_persistence
        ] )
    ]
