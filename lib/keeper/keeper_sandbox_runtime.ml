(** See .mli for contract.

    Extracted from [Keeper_exec_shell] (RFC-0006 Phase B-3b) so both
    [Keeper_exec_shell] (bash sandbox) and [Keeper_docker_read] (read
    sandbox) can preflight the host docker runtime against the
    configured hardening requirements without forming a module
    dependency cycle. *)

let docker_info_security_options ~timeout_sec =
  let st, out =
    Process_eio.run_argv_with_status
      ~cwd:(Sys.getcwd ())
      ~timeout_sec
      [ "docker"; "info"; "--format"; "{{json .SecurityOptions}}" ]
  in
  if st <> Unix.WEXITED 0 then
    Error
      (Printf.sprintf "docker info failed while validating sandbox runtime: %s"
         (Worker_dev_tools.truncate_for_log out))
  else
    try
      match Yojson.Safe.from_string (String.trim out) with
      | `List items ->
          Ok
            (List.filter_map Yojson.Safe.Util.to_string_option items
            |> List.map String.lowercase_ascii)
      | `Null -> Ok []
      | _ ->
          Error
            "docker info returned unexpected SecurityOptions payload while validating sandbox runtime"
    with
    | Yojson.Json_error err ->
        Error
          (Printf.sprintf
             "failed to parse docker info SecurityOptions JSON: %s"
             err)

let ensure_keeper_sandbox_runtime ~timeout_sec =
  let seccomp_profile =
    String.trim (Env_config_keeper.KeeperSandbox.seccomp_profile ())
  in
  let require_rootless = Env_config_keeper.KeeperSandbox.require_rootless () in
  let require_userns = Env_config_keeper.KeeperSandbox.require_userns () in
  let seccomp_args =
    if seccomp_profile = "" then
      Ok []
    else if Sys.file_exists seccomp_profile then
      Ok [ "--security-opt"; "seccomp=" ^ seccomp_profile ]
    else
      Error
        (Printf.sprintf
           "sandbox seccomp profile not found: %s"
           seccomp_profile)
  in
  match seccomp_args with
  | Error _ as err -> err
  | Ok seccomp_args ->
      if not require_rootless && not require_userns then
        Ok seccomp_args
      else
        match docker_info_security_options ~timeout_sec:(min 20.0 (max 5.0 timeout_sec)) with
        | Error _ as err -> err
        | Ok security_options ->
            let has needle =
              List.exists
                (fun option_text -> String_util.contains_substring option_text needle)
                security_options
            in
            if require_rootless && not (has "rootless") then
              Error
                "sandbox runtime requires Docker rootless mode (set MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS=false to disable this check)"
            else if require_userns && not (has "userns") then
              Error
                "sandbox runtime requires Docker userns support (set MASC_KEEPER_SANDBOX_REQUIRE_USERNS=false to disable this check)"
            else
              Ok seccomp_args
