let github_token_env_names =
  [ "GH_TOKEN"
  ; "GITHUB_TOKEN"
  ; "GH_ENTERPRISE_TOKEN"
  ; "GITHUB_ENTERPRISE_TOKEN"
  ]
;;

type auth_result =
  { authenticated : bool
  ; login : string option
  ; error : string option
  }

type observation =
  { keeper : string
  ; hostname : string
  ; config_dir : string
  ; projected_token_env_names : string list
  ; stored : auth_result
  ; effective : auth_result
  ; checked_at_unix : float
  }

let config_dir ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
    "github-cli"
;;

let container_config_dir ~container_masc_dir ~keeper_name =
  Filename.concat
    (Filename.concat (Filename.concat container_masc_dir "keepers") keeper_name)
    "github-cli"
;;

let file_kind_to_string = function
  | Unix.S_REG -> "regular file"
  | Unix.S_DIR -> "directory"
  | Unix.S_CHR -> "character device"
  | Unix.S_BLK -> "block device"
  | Unix.S_LNK -> "symbolic link"
  | Unix.S_FIFO -> "FIFO"
  | Unix.S_SOCK -> "socket"
;;

let lstat_opt path =
  try Ok (Some (Unix.lstat path)) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Unix.Unix_error (error, operation, target) ->
    Error
      (Printf.sprintf
         "cannot inspect GitHub CLI path %s: %s(%s): %s"
         path
         operation
         target
         (Unix.error_message error))
;;

let require_directory path =
  match lstat_opt path with
  | Error _ as error -> error
  | Ok None -> Error (Printf.sprintf "required GitHub CLI parent is missing: %s" path)
  | Ok (Some stats) when stats.Unix.st_kind = Unix.S_DIR -> Ok ()
  | Ok (Some stats) ->
    Error
      (Printf.sprintf
         "GitHub CLI path must be a directory, not a %s: %s"
         (file_kind_to_string stats.Unix.st_kind)
         path)
;;

let ensure_child_directory ~parent ~name ~private_mode =
  match require_directory parent with
  | Error _ as error -> error
  | Ok () ->
    let path = Filename.concat parent name in
    (match lstat_opt path with
     | Error _ as error -> error
     | Ok None ->
       (try Unix.mkdir path 0o700 with
        | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
        | Unix.Unix_error (error, operation, target) ->
          raise (Unix.Unix_error (error, operation, target)));
       (match require_directory path with
        | Error _ as error -> error
        | Ok () ->
          if private_mode then Unix.chmod path 0o700;
          Ok path)
     | Ok (Some stats) when stats.Unix.st_kind = Unix.S_DIR ->
       if private_mode then Unix.chmod path 0o700;
       Ok path
     | Ok (Some stats) ->
       Error
         (Printf.sprintf
            "GitHub CLI path must be a directory, not a %s: %s"
            (file_kind_to_string stats.Unix.st_kind)
            path))
;;

let inspect_config_files_in ~on_regular config_path =
  let rec inspect = function
    | [] -> Ok ()
    | filename :: rest ->
      let path = Filename.concat config_path filename in
      (match lstat_opt path with
       | Error _ as error -> error
       | Ok None -> inspect rest
       | Ok (Some stats) when stats.Unix.st_kind = Unix.S_REG ->
         on_regular path;
         inspect rest
       | Ok (Some stats) ->
         Error
           (Printf.sprintf
              "GitHub CLI credential must be a regular file, not a %s: %s"
              (file_kind_to_string stats.Unix.st_kind)
              path))
  in
  inspect [ "hosts.yml"; "config.yml" ]
;;

let secure_config_files_in config_path =
  inspect_config_files_in ~on_regular:(fun path -> Unix.chmod path 0o600) config_path
;;

let validate_config_files_in config_path =
  inspect_config_files_in ~on_regular:(fun _path -> ()) config_path
;;

let ensure_config_dir ~base_path ~keeper_name =
  if not (Keeper_config.validate_name keeper_name)
  then Error (Printf.sprintf "invalid keeper name: %s" keeper_name)
  else begin
    let keepers_root = Common.keepers_runtime_dir_of_base ~base_path in
    try
      match require_directory keepers_root with
      | Error _ as error -> error
      | Ok () ->
        (match
           ensure_child_directory
             ~parent:keepers_root
             ~name:keeper_name
             ~private_mode:false
         with
         | Error _ as error -> error
         | Ok keeper_root ->
           (match
              ensure_child_directory
                ~parent:keeper_root
                ~name:"github-cli"
                ~private_mode:true
            with
            | Error _ as error -> error
            | Ok path ->
              (match secure_config_files_in path with
               | Error _ as error -> error
               | Ok () -> Ok path)))
    with
    | Unix.Unix_error (error, operation, target) ->
      Error
        (Printf.sprintf
           "cannot prepare GitHub CLI directory under %s: %s(%s): %s"
           keepers_root
           operation
           target
           (Unix.error_message error))
  end
;;

let env_key entry =
  match String.index_opt entry '=' with
  | None -> entry
  | Some index -> String.sub entry 0 index
;;

let remove_env_keys keys env =
  Array.to_list env
  |> List.filter (fun entry -> not (List.mem (env_key entry) keys))
  |> Array.of_list
;;

let overlay_config_env ~config_dir env =
  Array.append
    [| "GH_CONFIG_DIR=" ^ config_dir |]
    (remove_env_keys [ "GH_CONFIG_DIR" ] env)
;;

let strip_github_token_env env = remove_env_keys github_token_env_names env

let projected_token_env_names env =
  List.filter
    (fun name -> Array.exists (fun entry -> String.equal (env_key entry) name) env)
    github_token_env_names
;;

let runtime_env ~base_path ~keeper_name env =
  match ensure_config_dir ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok keeper_config_dir -> Ok (overlay_config_env ~config_dir:keeper_config_dir env)
;;

type tool_identity_state =
  | Unconfigured
  | Configured of string

let inspect_optional_directory path =
  match lstat_opt path with
  | Error _ as error -> error
  | Ok None -> Ok false
  | Ok (Some stats) when stats.Unix.st_kind = Unix.S_DIR -> Ok true
  | Ok (Some stats) ->
    Error
      (Printf.sprintf
         "GitHub CLI path must be a directory, not a %s: %s"
         (file_kind_to_string stats.Unix.st_kind)
         path)
;;

let existing_config_dir ~base_path ~keeper_name =
  if not (Keeper_config.validate_name keeper_name)
  then Error (Printf.sprintf "invalid keeper name: %s" keeper_name)
  else begin
    let keepers_root = Common.keepers_runtime_dir_of_base ~base_path in
    let keeper_root = Filename.concat keepers_root keeper_name in
    let keeper_config_dir = Filename.concat keeper_root "github-cli" in
    match inspect_optional_directory keepers_root with
    | Error _ as error -> error
    | Ok false -> Ok None
    | Ok true ->
      (match inspect_optional_directory keeper_root with
       | Error _ as error -> error
       | Ok false -> Ok None
       | Ok true ->
         (match inspect_optional_directory keeper_config_dir with
          | Error _ as error -> error
          | Ok false -> Ok None
          | Ok true ->
            (match validate_config_files_in keeper_config_dir with
             | Error _ as error -> error
             | Ok () -> Ok (Some keeper_config_dir))))
  end
;;

let runtime_env_for_tool ~base_path ~keeper_name env =
  match existing_config_dir ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok None ->
    Ok
      ( overlay_config_env ~config_dir:(config_dir ~base_path ~keeper_name) env
      , Unconfigured )
  | Ok (Some path) -> Ok (overlay_config_env ~config_dir:path env, Configured path)
;;

let docker_args ~base_path ~keeper_name ~container_masc_dir =
  match ensure_config_dir ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok host_dir ->
    let container_dir = container_config_dir ~container_masc_dir ~keeper_name in
    Ok
      [ "--env"
      ; "GH_CONFIG_DIR=" ^ container_dir
      ; "-v"
      ; host_dir ^ ":" ^ container_dir ^ ":ro"
      ]
;;

let docker_args_for_tool ~base_path ~keeper_name ~container_masc_dir =
  match existing_config_dir ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok None ->
    let container_dir = container_config_dir ~container_masc_dir ~keeper_name in
    Ok ([ "--env"; "GH_CONFIG_DIR=" ^ container_dir ], Unconfigured)
  | Ok (Some host_dir) ->
    let container_dir = container_config_dir ~container_masc_dir ~keeper_name in
    Ok
      ( [ "--env"
        ; "GH_CONFIG_DIR=" ^ container_dir
        ; "-v"
        ; host_dir ^ ":" ^ container_dir ^ ":ro"
        ]
      , Configured host_dir )
;;

let login_argv ~hostname =
  [ "gh"
  ; "auth"
  ; "login"
  ; "--hostname"
  ; hostname
  ; "--git-protocol"
  ; "https"
  ; "--skip-ssh-key"
  ; "--web"
  ; "--insecure-storage"
  ]
;;

let logout_argv ~hostname = [ "gh"; "auth"; "logout"; "--hostname"; hostname ]

let projected_base_env ~base_path ~keeper_name =
  match
    Keeper_secret_projection.local_env_for_keeper
      ~host_env:(Unix.environment ())
      ~base_path
      ~keeper_name
      ()
  with
  | Error _ as error -> error
  | Ok None ->
    Error
      "keeper secret projection returned no environment; refusing host-environment fallback"
  | Ok (Some env) -> Ok env
;;

let projected_env ~base_path ~keeper_name =
  match projected_base_env ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok env -> runtime_env ~base_path ~keeper_name env
;;

let login_env ~base_path ~keeper_name =
  match projected_env ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok env -> Ok (strip_github_token_env env)
;;

let process_exit_text = function
  | Unix.WEXITED code -> Printf.sprintf "exit %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped by signal %d" signal
;;

let run_capture ~env = function
  | [] -> Unix.WEXITED 127, "", "GitHub CLI argv must not be empty"
  | argv ->
    Process_eio.run_argv_with_status_split
      ~timeout_sec:15.0
      ~env
      argv
;;

let auth_result_of_command ~redact ~env ~hostname =
  let status, stdout, stderr =
    run_capture
      ~env
      [ "gh"; "api"; "--hostname"; hostname; "user"; "--jq"; ".login" ]
  in
  let login = String.trim stdout in
  match status with
  | Unix.WEXITED 0 when not (String.equal login "") ->
    { authenticated = true; login = Some login; error = None }
  | _ ->
    let detail = String.trim (redact stderr) in
    let detail = if String.equal detail "" then process_exit_text status else detail in
    { authenticated = false; login = None; error = Some detail }
;;

let observe ~base_path ~keeper_name ~hostname =
  let hostname = String.trim hostname in
  if String.equal hostname "" then Error "GitHub hostname must not be empty"
  else
    match projected_base_env ~base_path ~keeper_name with
    | Error _ as error -> error
    | Ok base_env ->
      let redaction = Keeper_secret_redaction.snapshot ~base_path ~keeper_name in
      let redact = Keeper_secret_redaction.redact_text redaction in
      let token_env_names = projected_token_env_names base_env in
      (match existing_config_dir ~base_path ~keeper_name with
       | Error _ as error -> error
       | Ok existing ->
         let unconfigured =
           { authenticated = false
           ; login = None
           ; error = Some "Keeper GitHub CLI identity is not configured"
           }
         in
         let probe_with_ephemeral_config env =
           let probe_dir = Filename.temp_dir "masc-gh-observe-" "" in
           Unix.chmod probe_dir 0o700;
           Fun.protect
             ~finally:(fun () -> Fs_compat.remove_tree probe_dir)
             (fun () ->
                auth_result_of_command
                  ~redact
                  ~env:(overlay_config_env ~config_dir:probe_dir env)
                  ~hostname)
         in
         let stored, effective =
           match existing with
           | Some path ->
             let effective_env = overlay_config_env ~config_dir:path base_env in
             ( auth_result_of_command
                 ~redact
                 ~env:(strip_github_token_env effective_env)
                 ~hostname
             , auth_result_of_command ~redact ~env:effective_env ~hostname )
           | None ->
             let effective =
               match token_env_names with
               | [] -> unconfigured
               | _ :: _ -> probe_with_ephemeral_config base_env
             in
             unconfigured, effective
         in
         Ok
           { keeper = keeper_name
           ; hostname
           ; config_dir = config_dir ~base_path ~keeper_name
           ; projected_token_env_names = token_env_names
           ; stored
           ; effective
           ; checked_at_unix = Time_compat.now ()
           })
;;

let auth_result_to_yojson result =
  `Assoc
    [ "authenticated", `Bool result.authenticated
    ; "login", (match result.login with Some value -> `String value | None -> `Null)
    ; "error", (match result.error with Some value -> `String value | None -> `Null)
    ]
;;

let observation_to_yojson observation =
  `Assoc
    [ "ok", `Bool true
    ; "keeper", `String observation.keeper
    ; "hostname", `String observation.hostname
    ; "config_dir", `String observation.config_dir
    ; ( "projected_token_env_names"
      , `List (List.map (fun value -> `String value) observation.projected_token_env_names) )
    ; "stored", auth_result_to_yojson observation.stored
    ; "effective", auth_result_to_yojson observation.effective
    ; "checked_at_unix", `Float observation.checked_at_unix
    ]
;;

let secure_config_files ~base_path ~keeper_name =
  let root = config_dir ~base_path ~keeper_name in
  try
    match require_directory root with
    | Error _ as error -> error
    | Ok () ->
      Unix.chmod root 0o700;
      secure_config_files_in root
  with
  | Unix.Unix_error (error, operation, target) ->
    Error
      (Printf.sprintf
         "cannot secure GitHub CLI path %s: %s(%s): %s"
         root
         operation
         target
         (Unix.error_message error))
;;

let stream_login ~base_path ~keeper_name ~hostname ~env ~is_closed ~send_event =
  let send event json =
    if is_closed ()
    then raise (Eio.Cancel.Cancelled (Failure "GitHub login response closed"))
    else
      try send_event event json with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> raise (Eio.Cancel.Cancelled exn)
  in
  match Eio_context.get_clock_opt () with
  | None -> Error "GitHub login streaming requires the server Eio clock"
  | Some clock ->
    let redaction = Keeper_secret_redaction.snapshot ~base_path ~keeper_name in
    let stdout_redaction = Keeper_secret_redaction.create_stream_state redaction in
    let stderr_redaction = Keeper_secret_redaction.create_stream_state redaction in
    let send_redacted_output stream state chunk =
      let text = Keeper_secret_redaction.redact_stream_chunk state chunk in
      if not (String.equal text "")
      then send "output" (`Assoc [ "stream", `String stream; "text", `String text ])
    in
    let finish_redacted_output stream state =
      let text = Keeper_secret_redaction.redact_stream_finish state in
      if not (String.equal text "")
      then send "output" (`Assoc [ "stream", `String stream; "text", `String text ])
    in
    let run_process () =
      let finished = Atomic.make false in
      let process_result = ref None in
      Eio.Cancel.sub (fun cancellation ->
        Eio.Fiber.both
          (fun () ->
             Fun.protect
               ~finally:(fun () -> Atomic.set finished true)
               (fun () ->
                  process_result :=
                    Some
                      (Process_eio.run_argv_with_status_split_streaming
                         ~timeout_sec:600.0
                         ~env
                         ~on_stdout_chunk:
                           (send_redacted_output "stdout" stdout_redaction)
                         ~on_stderr_chunk:
                           (send_redacted_output "stderr" stderr_redaction)
                         (login_argv ~hostname))))
          (fun () ->
             while (not (Atomic.get finished)) && not (is_closed ()) do
               Eio.Time.sleep clock 0.1
             done;
             if is_closed ()
             then
               Eio.Cancel.cancel
                 cancellation
                 (Failure "GitHub login response closed")));
      match !process_result with
      | Some result -> result
      | None -> failwith "GitHub login process completed without a result"
    in
    (try
       let status, _, stderr = run_process () in
       finish_redacted_output "stdout" stdout_redaction;
       finish_redacted_output "stderr" stderr_redaction;
       let stderr = Keeper_secret_redaction.redact_text redaction stderr in
       (match status with
        | Unix.WEXITED 0 ->
          (match secure_config_files ~base_path ~keeper_name with
           | Error message -> send "error" (`Assoc [ "message", `String message ])
           | Ok () ->
             (match observe ~base_path ~keeper_name ~hostname with
              | Ok observation ->
                send
                  "complete"
                  (`Assoc [ "observation", observation_to_yojson observation ])
              | Error message ->
                send "error" (`Assoc [ "message", `String message ])))
        | failed ->
          let detail = String.trim stderr in
          let detail =
            if String.equal detail "" then process_exit_text failed else detail
          in
          send "error" (`Assoc [ "message", `String detail ]));
       Ok ()
     with
     | Eio.Cancel.Cancelled _ when is_closed () -> Ok ()
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Printexc.to_string exn))
;;

let print_observation ~base_path ~keeper_name ~hostname =
  match observe ~base_path ~keeper_name ~hostname with
  | Error message ->
    prerr_endline message;
    false
  | Ok observation ->
    observation_to_yojson observation |> Yojson.Safe.pretty_to_string |> print_endline;
    true
;;

let run_inherited ~env = function
  | [] -> Unix.WEXITED 127
  | command :: _ as argv ->
    (try
       let process =
         Unix.create_process_env
           command
           (Array.of_list argv)
           env
           Unix.stdin
           Unix.stdout
           Unix.stderr
       in
       let rec wait () =
         try snd (Unix.waitpid [] process) with
         | Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
       in
       wait ()
     with
     | Unix.Unix_error (error, operation, target) ->
       prerr_endline
         (Printf.sprintf
            "cannot run GitHub CLI: %s(%s): %s"
            operation
            target
            (Unix.error_message error));
       Unix.WEXITED 127)
;;

let run_cli_login ~base_path ~keeper_name ~hostname =
  match login_env ~base_path ~keeper_name with
  | Error message ->
    prerr_endline message;
    1
  | Ok env ->
    let status = run_inherited ~env (login_argv ~hostname) in
    let secured =
      match status with
      | Unix.WEXITED 0 ->
        (match secure_config_files ~base_path ~keeper_name with
         | Ok () -> true
         | Error message ->
           prerr_endline message;
           false)
      | _ ->
        prerr_endline ("gh auth login failed: " ^ process_exit_text status);
        false
    in
    let observed = print_observation ~base_path ~keeper_name ~hostname in
    if secured && observed then 0 else 1
;;

let run_cli_status ~base_path ~keeper_name ~hostname =
  if print_observation ~base_path ~keeper_name ~hostname then 0 else 1
;;

let run_cli_logout ~base_path ~keeper_name ~hostname =
  match login_env ~base_path ~keeper_name with
  | Error message ->
    prerr_endline message;
    1
  | Ok env ->
    let status = run_inherited ~env (logout_argv ~hostname) in
    let logged_out =
      match status with
      | Unix.WEXITED 0 -> true
      | _ ->
        prerr_endline ("gh auth logout failed: " ^ process_exit_text status);
        false
    in
    let observed = print_observation ~base_path ~keeper_name ~hostname in
    if logged_out && observed then 0 else 1
;;
