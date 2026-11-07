open Alcotest

(* Fixtures are the sanitized Vibe 3.1.0 captures in fixtures/vibe_headless/.
   Each case pairs an export.json with the exit code and stdout its run had:
   the runs that did not finish wrote nothing to stdout. *)

module Cli = Runtime_vibe_cli
module Vibe = Runtime_vibe_headless

let read name =
  In_channel.with_open_bin ("fixtures/vibe_headless/" ^ name) In_channel.input_all
;;

let classify ~exit_code ?export ?(stdout = "") ?(stderr = "") () =
  Cli.classify ~exit_code ~export_json:(Option.map read export) ~stdout ~stderr
;;

let run_of = function
  | Ok (run : Cli.run) -> run
  | Error error -> fail (Cli.error_to_string error)
;;

let error = function
  | Ok _ -> fail "expected an error"
  | Error error -> error
;;

let test_outcomes () =
  (match run_of (classify ~exit_code:0 ~export:"export-finished.json"
                   ~stdout:(read "entries-first-call.json") ()) with
   | { export = { outcome = Vibe.Finished; _ }; transcript = Cli.Entries entries; _ } ->
     check int "m0 entries" 3 (List.length entries)
   | _ -> fail "m0 is finished with entries");
  (match run_of (classify ~exit_code:1 ~export:"export-usage-error.json" ()) with
   | { export = { outcome = Vibe.Usage_error; _ }; transcript = Cli.No_output; _ } -> ()
   | _ -> fail "m3 is usage_error without output");
  (match run_of (classify ~exit_code:2 ~export:"export-infrastructure-failure.json" ()) with
   | { export = { outcome = Vibe.Infrastructure_failure; error; _ }; _ } ->
     check (option string) "m4 provider refusal" (Some "backend_error")
       (Option.bind error (fun (e : Vibe.run_error) -> e.code))
   | _ -> fail "m4 is infrastructure_failure");
  match run_of (classify ~exit_code:3 ~export:"export-deadline.json" ()) with
  | { export = { outcome = Vibe.Deadline; _ }; transcript = Cli.No_output; _ } -> ()
  | _ -> fail "m5 is deadline without output"
;;

let test_disagreements () =
  (match error (classify ~exit_code:1 ~stderr:"error: unexpected argument '--no-such-flag'" ()) with
   | Cli.No_export { exit_code = 1; stderr_tail } ->
     check bool "stderr kept" true (String.length stderr_tail > 0)
   | other -> fail (Cli.error_to_string other));
  (match error (classify ~exit_code:0 ~export:"export-usage-error.json" ()) with
   | Cli.Exit_code_mismatch { process = 0; export = 1 } -> ()
   | other -> fail (Cli.error_to_string other));
  (* An export whose own exit_code agrees with the process but not with the
     code its outcome had: finished with 3. *)
  let finished_with_3 =
    match Yojson.Safe.from_string (read "export-finished.json") with
    | `Assoc fields ->
      Yojson.Safe.to_string
        (`Assoc (List.map (fun (k, v) -> if k = "exit_code" then k, `Int 3 else k, v) fields))
    | _ -> fail "export-finished.json is an object"
  in
  match error (Cli.classify ~exit_code:3 ~export_json:(Some finished_with_3) ~stdout:"" ~stderr:"") with
  | Cli.Outcome_exit_mismatch { outcome = Vibe.Finished; exit_code = 3 } -> ()
  | other -> fail (Cli.error_to_string other)
;;

let config =
  { Cli.cli_path = "/opt/vibe/bin/vibe"
  ; workdir = Filename.get_temp_dir_name ()
  ; trust_workdir = false
  ; model = None
  ; time_limit_s = Some 120
  }
;;

let test_child_process () =
  let env =
    Cli.child_environment
      [| "HOME=/home/k"; "PATH=/bin"; "MISTRAL_API_KEY=secret"; "VIBE_CLI_OIDC_ENABLED=1" |]
  in
  check (list string) "allowlist" [ "HOME=/home/k"; "PATH=/bin" ] (Array.to_list env);
  check (list string) "argv"
    [ "/opt/vibe/bin/vibe"; "--workdir"; config.workdir; "--output-dir"; "/c/out"
    ; "--agent"; "ask"; "--output"; "json"; "--prompt-file"; "/c/prompt.txt"
    ; "--time-limit"; "120" ]
    (Cli.argv config ~output_dir:"/c/out" ~prompt_file:"/c/prompt.txt");
  check bool "limit 120 accepted" true (Result.is_ok (Cli.validate_config config));
  check bool "limit 0 refused" true
    (Result.is_error (Cli.validate_config { config with time_limit_s = Some 0 }))
;;

let () =
  run
    "runtime_vibe_cli"
    [ ( "classify"
      , [ test_case "outcomes" `Quick test_outcomes
        ; test_case "disagreements" `Quick test_disagreements
        ] )
    ; "child process", [ test_case "env and argv" `Quick test_child_process ]
    ]
;;
