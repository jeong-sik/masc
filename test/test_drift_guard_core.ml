open Alcotest

module Drift_guard = Masc_mcp.Drift_guard
module Coord = Masc_mcp.Coord

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else
      Sys.remove path

let with_temp_masc_dir f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-drift-guard-%d-%d" (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1_000_000.)))
  in
  Unix.mkdir base 0o755;
  let config = Coord.default_config base in
  ignore (Coord.init config ~agent_name:None);
  Fun.protect
    ~finally:(fun () ->
      let _ = Coord.reset config in
      rm_rf base)
    (fun () -> f config)

let test_text_similarity_identical () =
  let text = "This is a test sentence for similarity comparison." in
  let similarity = Drift_guard.text_similarity text text in
  check bool "similarity close to one" true (similarity > 0.99)

let test_verify_handoff_verified () =
  let original =
    "Task completed: Implemented user authentication with JWT tokens and OAuth2 support."
  in
  let received =
    "Task completed: Implemented user authentication using JWT tokens and OAuth2 support."
  in
  match Drift_guard.verify_handoff ~original ~received () with
  | Drift_guard.Verified summary ->
      check bool "passes threshold" true (summary.similarity >= 0.85)
  | Drift_guard.Drift_detected _ -> fail "expected verification to pass"

let test_verify_handoff_factual_drift () =
  let original =
    "Completed tasks: 1. Setup database 2. Create API endpoints 3. Write tests 4. Deploy to staging 5. Monitor logs"
  in
  let received = "Completed tasks: 1. Setup database" in
  match Drift_guard.verify_handoff ~original ~received () with
  | Drift_guard.Drift_detected details ->
      check string "drift type" "factual"
        (Drift_guard.drift_type_to_string details.drift_type)
  | Drift_guard.Verified _ -> fail "expected factual drift"

let test_verify_and_log_and_stats () =
  with_temp_masc_dir (fun config ->
      ignore
        (Drift_guard.verify_and_log config ~from_agent:"claude"
           ~to_agent:"gemini" ~task_id:"task-001" ~original:"same text"
           ~received:"same text" ());
      ignore
        (Drift_guard.verify_and_log config ~from_agent:"gemini"
           ~to_agent:"codex" ~task_id:"task-002"
           ~original:"Use PostgreSQL and Redis for this service."
           ~received:"Use MongoDB for this service." ());
      check bool "log file exists" true
        (Sys.file_exists (Drift_guard.drift_log_file config));
      let total, drift_count, avg_similarity =
        Drift_guard.get_drift_stats config ~days:7
      in
      check int "two records" 2 total;
      check int "one drift" 1 drift_count;
      check bool "avg in range" true
        (avg_similarity >= 0.0 && avg_similarity <= 1.0))

let test_result_to_json_shape () =
  let result =
    Drift_guard.verify_handoff ~original:"same text" ~received:"same text" ()
  in
  match Drift_guard.result_to_json result with
  | `Assoc fields ->
      check bool "has similarity" true (List.mem_assoc "similarity" fields);
      check bool "has passed" true (List.mem_assoc "passed" fields);
      check bool "has verdict" true (List.mem_assoc "verdict" fields)
  | _ -> fail "expected json object"

let () =
  run "Drift_guard core"
    [
      ( "similarity",
        [ test_case "identical text" `Quick test_text_similarity_identical ] );
      ( "verify_handoff",
        [
          test_case "verified" `Quick test_verify_handoff_verified;
          test_case "factual drift" `Quick test_verify_handoff_factual_drift;
        ] );
      ("logging", [ test_case "verify_and_log + stats" `Quick test_verify_and_log_and_stats ]);
      ("json", [ test_case "result_to_json" `Quick test_result_to_json_shape ]);
    ]
