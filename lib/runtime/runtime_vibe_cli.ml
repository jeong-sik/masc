module Headless = Runtime_vibe_headless

type config =
  { cli_path : string
  ; workdir : string
  ; trust_workdir : bool
  ; model : string option
  ; max_turns : int
  ; time_limit_s : int
  ; process_timeout_s : float
  }

(* RFC §2.1: a lane call runs the [ask] agent. It refuses every tool call that
   needs approval (m10), and the lane never auto-approves. *)
let agent = "ask"
let output_format = "json"
let export_file_name = "export.json"
let output_dir_prefix = "masc-vibe-"
let stderr_tail_bytes = 8192

let validate_config config =
  if String.trim config.cli_path = ""
  then Error "cli_path is empty"
  else if Filename.is_relative config.workdir
  then Error (Printf.sprintf "workdir %S is not absolute" config.workdir)
  else if not (Sys.file_exists config.workdir && Sys.is_directory config.workdir)
  then Error (Printf.sprintf "workdir %S is not a directory" config.workdir)
  else if config.max_turns < 1
  then Error (Printf.sprintf "max_turns %d is below 1" config.max_turns)
  else if config.time_limit_s < 1
  then Error (Printf.sprintf "time_limit_s %d is below 1" config.time_limit_s)
  else if not (config.process_timeout_s > float_of_int config.time_limit_s)
  then
    Error
      (Printf.sprintf
         "process_timeout_s %g must be longer than time_limit_s %d"
         config.process_timeout_s
         config.time_limit_s)
  else Ok ()
;;

let env_key entry =
  match String.index_opt entry '=' with
  | Some index -> String.sub entry 0 index
  | None -> entry
;;

(* A fixed list, not a list of names to drop: a provider key the server gains
   later stays out of the child without anyone remembering to add it here.
   Vibe resolves its key from the process env before the keyring, so passing
   MISTRAL_API_KEY would send the call to the API budget (m4). *)
let child_environment_key_allowed = function
  | "COLORTERM"
  | "HOME"
  | "LANG"
  | "LC_ALL"
  | "LC_CTYPE"
  | "LOGNAME"
  | "PATH"
  | "SHELL"
  | "SSL_CERT_DIR"
  | "SSL_CERT_FILE"
  | "TEMP"
  | "TERM"
  | "TMP"
  | "TMPDIR"
  | "TZ"
  | "USER"
  | "XDG_CACHE_HOME"
  | "XDG_CONFIG_HOME"
  | "XDG_DATA_HOME"
  | "XDG_RUNTIME_DIR" -> true
  | _ -> false
;;

let child_environment environment =
  environment
  |> Array.to_list
  |> List.filter (fun entry -> child_environment_key_allowed (env_key entry))
  |> Array.of_list
;;

let argv config ~output_dir =
  [ config.cli_path
  ; "--workdir"
  ; config.workdir
  ; "--output-dir"
  ; output_dir
  ; "--agent"
  ; agent
  ; "--output"
  ; output_format
  ; "--max-turns"
  ; string_of_int config.max_turns
  ; "--time-limit"
  ; string_of_int config.time_limit_s
  ]
  @ (if config.trust_workdir then [ "--trust" ] else [])
  @ (match config.model with
     | Some model -> [ "--model"; model ]
     | None -> [])
  @ [ "-p" ]
;;

type limit =
  | Deadline
  | Token_limit
  | Turn_limit

type transcript =
  | No_output
  | Entries of Headless.entry list

type run =
  { export : Headless.export
  ; transcript : transcript
  ; stderr_tail : string
  }

type completed =
  | Finished of run
  | Stopped_at_limit of
      { limit : limit
      ; run : run
      }
  | Usage_error of run
  | Infrastructure_failure of run
  | Unrecognized_outcome of
      { outcome : string
      ; run : run
      }

type error =
  | Invalid_config of string
  | Process_runtime_unavailable
  | Output_dir_failed of string
  | Timed_out of { after_s : float }
  | Signaled of int
  | Stopped of int
  | No_export of
      { exit_code : int
      ; stderr_tail : string
      }
  | Export_unreadable of Headless.error
  | Transcript_unreadable of Headless.error
  | Exit_code_mismatch of
      { process : int
      ; export : int
      }
  | Outcome_exit_mismatch of
      { outcome : Headless.outcome
      ; exit_code : int
      }

let outcome_to_string : Headless.outcome -> string = function
  | Headless.Finished -> "finished"
  | Headless.Usage_error -> "usage_error"
  | Headless.Infrastructure_failure -> "infrastructure_failure"
  | Headless.Deadline -> "deadline"
  | Headless.Token_limit -> "token_limit"
  | Headless.Turn_limit -> "turn_limit"
  | Headless.Unrecognized_outcome value -> value
;;

let error_to_string = function
  | Invalid_config detail -> "invalid Vibe config: " ^ detail
  | Process_runtime_unavailable -> "Eio process runtime is not initialized"
  | Output_dir_failed detail -> "Vibe output directory failed: " ^ detail
  | Timed_out { after_s } -> Printf.sprintf "Vibe was killed after %gs" after_s
  | Signaled signal -> "Vibe was killed by " ^ Process_eio.signal_name signal
  | Stopped signal -> "Vibe was stopped by " ^ Process_eio.signal_name signal
  | No_export { exit_code; stderr_tail } ->
    Printf.sprintf "Vibe exited %d without export.json: %s" exit_code stderr_tail
  | Export_unreadable error -> "export.json: " ^ Headless.error_to_string error
  | Transcript_unreadable error -> "stdout: " ^ Headless.error_to_string error
  | Exit_code_mismatch { process; export } ->
    Printf.sprintf "Vibe exited %d but export.json says %d" process export
  | Outcome_exit_mismatch { outcome; exit_code } ->
    Printf.sprintf
      "Vibe outcome %s came with exit %d"
      (outcome_to_string outcome)
      exit_code
;;

let stderr_tail stderr =
  String_util.utf8_suffix
    ~max_bytes:stderr_tail_bytes
    (Secret_patterns.redact_text (String.trim stderr))
;;

let transcript_of_stdout = function
  | "" -> Ok No_output
  | stdout ->
    (match Headless.decode_entries stdout with
     | Ok entries -> Ok (Entries entries)
     | Error error -> Error (Transcript_unreadable error))
;;

(* The exit code each outcome came with in the retained runs (§4.1). *)
let observed_exit_code : Headless.outcome -> int option = function
  | Headless.Finished -> Some 0
  | Headless.Usage_error -> Some 1
  | Headless.Infrastructure_failure -> Some 2
  | Headless.Deadline | Headless.Token_limit | Headless.Turn_limit -> Some 3
  | Headless.Unrecognized_outcome _ -> None
;;

let completed_of_run (run : run) : completed =
  match run.export.outcome with
  | Headless.Finished -> Finished run
  | Headless.Usage_error -> Usage_error run
  | Headless.Infrastructure_failure -> Infrastructure_failure run
  | Headless.Deadline -> Stopped_at_limit { limit = Deadline; run }
  | Headless.Token_limit -> Stopped_at_limit { limit = Token_limit; run }
  | Headless.Turn_limit -> Stopped_at_limit { limit = Turn_limit; run }
  | Headless.Unrecognized_outcome outcome -> Unrecognized_outcome { outcome; run }
;;

let classify ~exit_code ~export_json ~stdout ~stderr =
  let stderr_tail = stderr_tail stderr in
  match export_json with
  | None -> Error (No_export { exit_code; stderr_tail })
  | Some json ->
    (match Headless.decode_export json with
     | Error error -> Error (Export_unreadable error)
     | Ok export when export.exit_code <> exit_code ->
       Error (Exit_code_mismatch { process = exit_code; export = export.exit_code })
     | Ok export ->
       (match observed_exit_code export.outcome with
        | Some expected when expected <> exit_code ->
          Error (Outcome_exit_mismatch { outcome = export.outcome; exit_code })
        | Some _ | None ->
          (match transcript_of_stdout stdout with
           | Error error -> Error error
           | Ok transcript -> Ok (completed_of_run { export; transcript; stderr_tail }))))
;;

let read_export output_dir =
  let path = Filename.concat output_dir export_file_name in
  if Sys.file_exists path
  then Some (In_channel.with_open_bin path In_channel.input_all)
  else None
;;

let make_output_dir () =
  match Filename.temp_dir output_dir_prefix "" with
  | dir -> Ok dir
  | exception Sys_error detail -> Error (Output_dir_failed detail)
;;

let run_process config ~prompt ~output_dir =
  let status, stdout, stderr =
    Process_eio.run_argv_with_stdin_and_status_split
      ~timeout_sec:config.process_timeout_s
      ~env:(child_environment (Unix.environment ()))
      ~cwd:config.workdir
      ~fallback_policy:Process_eio.Eio_only
      ~stdin_content:prompt
      (argv config ~output_dir)
  in
  match Process_eio.exit_reason_of_status status with
  | Process_eio.Completed exit_code ->
    (match read_export output_dir with
     | export_json -> classify ~exit_code ~export_json ~stdout ~stderr
     | exception Sys_error detail -> Error (Output_dir_failed detail))
  | Process_eio.Timed_out -> Error (Timed_out { after_s = config.process_timeout_s })
  | Process_eio.Signaled signal -> Error (Signaled signal)
  | Process_eio.Stopped signal -> Error (Stopped signal)
;;

(* The directory holds the run's export.json and session copy, so a removal
   that fails is said out loud. It is caught here: an exception from a
   [Fun.protect] finally would replace the run's own result. *)
let remove_output_dir output_dir =
  try Fs_compat.remove_tree output_dir with
  | (Sys_error _ | Unix.Unix_error _) as exn ->
    Log.Runtime_agent.warn
      "Vibe run left its output directory %s behind: %s"
      output_dir
      (Printexc.to_string exn)
;;

let run config ~prompt =
  match validate_config config with
  | Error detail -> Error (Invalid_config detail)
  | Ok () when not (Process_eio.is_initialized ()) -> Error Process_runtime_unavailable
  | Ok () ->
    (match make_output_dir () with
     | Error error -> Error error
     | Ok output_dir ->
       Fun.protect
         ~finally:(fun () -> remove_output_dir output_dir)
         (fun () -> run_process config ~prompt ~output_dir))
;;
