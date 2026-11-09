module Headless = Runtime_vibe_headless

type config =
  { cli_path : string
  ; workdir : string
  ; trust_workdir : bool
  ; model : string option
  ; time_limit_s : int option
  }

(* RFC §2.1: a lane call runs the [ask] agent. It refuses every tool call that
   needs approval (m10), and the lane never auto-approves. *)
let agent = "ask"
let output_format = "json"
let export_file_name = "export.json"
let prompt_file_name = "prompt.txt"
let output_dir_name = "out"
let call_dir_prefix = "masc-vibe-"
let private_dir_perm = 0o700
let private_file_perm = 0o600
let stderr_tail_bytes = 8192

(* m5 ran 3.05 s on a 1-second [--time-limit] and still wrote export.json.
   MASC kills the process only this long after Vibe's own limit: the kill is
   for a Vibe that no longer keeps its limit, not a second deadline. *)
let export_grace_s = 30.0

let validate_config config =
  if String.trim config.cli_path = ""
  then Error "cli_path is empty"
  else if Filename.is_relative config.workdir
  then Error (Printf.sprintf "workdir %S is not absolute" config.workdir)
  else if not (Sys.file_exists config.workdir && Sys.is_directory config.workdir)
  then Error (Printf.sprintf "workdir %S is not a directory" config.workdir)
  else (
    match config.time_limit_s with
    | Some limit when limit < 1 -> Error (Printf.sprintf "time_limit_s %d is below 1" limit)
    | Some _ | None -> Ok ())
;;

let process_timeout_s config =
  Option.map (fun limit -> float_of_int limit +. export_grace_s) config.time_limit_s
;;

let env_key entry =
  match String.index_opt entry '=' with
  | Some index -> String.sub entry 0 index
  | None -> entry
;;

(* A fixed list, not a list of names to drop: a provider key the server gains
   later stays out of the child without anyone remembering to add it here.
   Vibe takes a key in the process env before the keyring, so passing
   MISTRAL_API_KEY would send the call to the API budget (m4). *)
let child_environment_key_allowed = function
  | "ALL_PROXY"
  | "COLORTERM"
  | "HOME"
  | "HTTPS_PROXY"
  | "HTTP_PROXY"
  | "LANG"
  | "LC_ALL"
  | "LC_CTYPE"
  | "LOGNAME"
  | "NO_PROXY"
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
  | "XDG_RUNTIME_DIR"
  | "all_proxy"
  | "http_proxy"
  | "https_proxy"
  | "no_proxy" -> true
  | _ -> false
;;

let child_environment environment =
  environment
  |> Array.to_list
  |> List.filter (fun entry -> child_environment_key_allowed (env_key entry))
  |> Array.of_list
;;

let argv config ~output_dir ~prompt_file =
  [ config.cli_path
  ; "--workdir"
  ; config.workdir
  ; "--output-dir"
  ; output_dir
  ; "--agent"
  ; agent
  ; "--output"
  ; output_format
  ; "--prompt-file"
  ; prompt_file
  ]
  @ (match config.time_limit_s with
     | Some limit -> [ "--time-limit"; string_of_int limit ]
     | None -> [])
  @ (if config.trust_workdir then [ "--trust" ] else [])
  @
  match config.model with
  | Some model -> [ "--model"; model ]
  | None -> []
;;

type transcript =
  | No_output
  | Entries of Headless.entry list

type run =
  { export : Headless.export
  ; transcript : transcript
  ; stderr_tail : string
  }

type error =
  | Invalid_config of string
  | Process_runtime_unavailable
  | Call_dir_failed of string
  | Spawn_refused of Process_eio.spawn_refusal
  | Timed_out of
      { after_s : float option
      ; stderr_tail : string
      }
  | Signaled of
      { signal : int
      ; stderr_tail : string
      }
  | Stopped of
      { signal : int
      ; stderr_tail : string
      }
  | No_export of
      { exit_code : int
      ; stderr_tail : string
      }
  | Export_unreadable of Headless.error
  | Transcript_unreadable of
      { error : Headless.error
      ; usage : Headless.usage option
      }
  | Exit_code_mismatch of
      { process : int
      ; export : int
      ; usage : Headless.usage option
      }
  | Outcome_exit_mismatch of
      { outcome : Headless.outcome
      ; exit_code : int
      ; usage : Headless.usage option
      }

let reported_usage = function
  | Transcript_unreadable { usage; _ }
  | Exit_code_mismatch { usage; _ }
  | Outcome_exit_mismatch { usage; _ } -> usage
  | Invalid_config _
  | Process_runtime_unavailable
  | Call_dir_failed _
  | Spawn_refused _
  | Timed_out _
  | Signaled _
  | Stopped _
  | No_export _
  | Export_unreadable _ -> None
;;

let error_to_string = function
  | Invalid_config detail -> "invalid Vibe config: " ^ detail
  | Process_runtime_unavailable -> "Eio process runtime is not initialized"
  | Call_dir_failed detail -> "Vibe call directory failed: " ^ detail
  | Spawn_refused refusal ->
    "Vibe did not start: " ^ Process_eio.spawn_refusal_to_string refusal
  | Timed_out { after_s = Some after_s; stderr_tail } ->
    Printf.sprintf "Vibe was killed after %gs: %s" after_s stderr_tail
  | Timed_out { after_s = None; stderr_tail } ->
    "Vibe exited with the timeout status and no MASC deadline was set: " ^ stderr_tail
  | Signaled { signal; stderr_tail } ->
    Printf.sprintf
      "Vibe was killed by %s: %s"
      (Process_eio.signal_name signal)
      stderr_tail
  | Stopped { signal; stderr_tail } ->
    Printf.sprintf
      "Vibe was stopped by %s: %s"
      (Process_eio.signal_name signal)
      stderr_tail
  | No_export { exit_code; stderr_tail } ->
    Printf.sprintf "Vibe exited %d without export.json: %s" exit_code stderr_tail
  | Export_unreadable error -> "export.json: " ^ Headless.error_to_string error
  | Transcript_unreadable { error; usage = _ } -> "stdout: " ^ Headless.error_to_string error
  | Exit_code_mismatch { process; export; usage = _ } ->
    Printf.sprintf "Vibe exited %d but export.json says %d" process export
  | Outcome_exit_mismatch { outcome; exit_code; usage = _ } ->
    Printf.sprintf
      "Vibe outcome %s came with exit %d"
      (Headless.outcome_to_wire outcome)
      exit_code
;;

let stderr_tail stderr =
  String_util.utf8_suffix
    ~max_bytes:stderr_tail_bytes
    (Secret_patterns.redact_text (String.trim stderr))
;;

let transcript_of_stdout = function
  | "" -> Ok No_output
  | stdout -> Result.map (fun entries -> Entries entries) (Headless.decode_entries stdout)
;;

let classify ~exit_code ~export_json ~stdout ~stderr =
  let stderr_tail = stderr_tail stderr in
  match export_json with
  | None -> Error (No_export { exit_code; stderr_tail })
  | Some json ->
    (match Headless.decode_export json with
     | Error error -> Error (Export_unreadable error)
     | Ok export when export.exit_code <> exit_code ->
       Error
         (Exit_code_mismatch
            { process = exit_code; export = export.exit_code; usage = export.usage })
     | Ok export ->
       (match Headless.exit_code_of_outcome export.outcome with
        | Some expected when expected <> exit_code ->
          Error
            (Outcome_exit_mismatch
               { outcome = export.outcome; exit_code; usage = export.usage })
        | Some _ | None ->
          (match transcript_of_stdout stdout with
           | Ok transcript -> Ok { export; transcript; stderr_tail }
           | Error error -> Error (Transcript_unreadable { error; usage = export.usage }))))
;;

let read_export output_dir =
  let path = Filename.concat output_dir export_file_name in
  if Sys.file_exists path
  then Some (In_channel.with_open_bin path In_channel.input_all)
  else None
;;

(* The call directory holds [prompt.txt] and Vibe's output directory [out].
   Vibe's export and session copy land in [out], apart from the prompt. *)
let prepare_call_dir call_dir ~prompt =
  let output_dir = Filename.concat call_dir output_dir_name in
  let prompt_file = Filename.concat call_dir prompt_file_name in
  match
    Sys.mkdir output_dir private_dir_perm;
    Out_channel.with_open_gen
      [ Open_wronly; Open_creat; Open_excl; Open_binary ]
      private_file_perm
      prompt_file
      (fun channel ->
        Out_channel.output_string channel prompt;
        (* [with_open_gen] closes with [close_out_noerr], which would swallow
           a failed final flush or close and leave Vibe a cut-off prompt.
           Closing here raises [Sys_error]; the later close does nothing. *)
        Out_channel.close channel)
  with
  | () -> Ok (output_dir, prompt_file)
  | exception Sys_error detail -> Error (Call_dir_failed detail)
;;

let completed_process ~exit_code ~output_dir ~stdout ~stderr =
  match read_export output_dir with
  | export_json -> classify ~exit_code ~export_json ~stdout ~stderr
  | exception Sys_error detail -> Error (Call_dir_failed detail)
;;

let run_process config ~output_dir ~prompt_file =
  let timeout_s = process_timeout_s config in
  match
    Process_eio.run_argv_with_status_split_or_refusal
      ?timeout_sec:timeout_s
      ~env:(child_environment (Unix.environment ()))
      ~cwd:config.workdir
      (argv config ~output_dir ~prompt_file)
  with
  | Error refusal -> Error (Spawn_refused refusal)
  | Ok (status, stdout, stderr) ->
    (match Process_eio.exit_reason_of_status status with
     | Process_eio.Completed exit_code ->
       completed_process ~exit_code ~output_dir ~stdout ~stderr
     | Process_eio.Timed_out ->
       Error (Timed_out { after_s = timeout_s; stderr_tail = stderr_tail stderr })
     | Process_eio.Signaled signal ->
       Error (Signaled { signal; stderr_tail = stderr_tail stderr })
     | Process_eio.Stopped signal ->
       Error (Stopped { signal; stderr_tail = stderr_tail stderr }))
;;

(* The directory holds the prompt, export.json and Vibe's session copy, so a
   removal that fails is said out loud instead of failing the switch. *)
let remove_call_dir call_dir =
  try Fs_compat.remove_tree call_dir with
  | (Sys_error _ | Unix.Unix_error _) as exn ->
    Log.Runtime_agent.warn
      "Vibe run left its call directory %s behind: %s"
      call_dir
      (Printexc.to_string exn)
;;

let run ~host:(_ : Runtime_account_access.host_account) config ~prompt =
  match validate_config config with
  | Error detail -> Error (Invalid_config detail)
  | Ok () when not (Process_eio.is_initialized ()) -> Error Process_runtime_unavailable
  | Ok () ->
    (* The directory is made inside the switch and its removal registered
       with no effect in between: [Switch.run] can raise [Cancelled] before
       its callback runs, and Eio runs release hooks with cancellation off. *)
    Eio.Switch.run
    @@ fun sw ->
    (match Filename.temp_dir ~perms:private_dir_perm call_dir_prefix "" with
     | exception Sys_error detail -> Error (Call_dir_failed detail)
     | call_dir ->
       Eio.Switch.on_release sw (fun () -> remove_call_dir call_dir);
       (match prepare_call_dir call_dir ~prompt with
        | Error error -> Error error
        | Ok (output_dir, prompt_file) -> run_process config ~output_dir ~prompt_file))
;;
