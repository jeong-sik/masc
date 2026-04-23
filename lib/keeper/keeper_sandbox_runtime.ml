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

type required_command_check =
  {
    command : string;
    available : bool;
  }

type docker_preflight =
  {
    ok : bool;
    image : string;
    docker_runtime_ok : bool;
    docker_runtime_error : string option;
    hardening_ok : bool;
    hardening_error : string option;
    image_present : bool;
    image_error : string option;
    required_commands : required_command_check list;
    missing_commands : string list;
    next_actions : string list;
  }

let docker_preflight_min_sec = 5.0
let docker_preflight_max_sec = 20.0

let docker_preflight_timeout ~timeout_sec =
  min docker_preflight_max_sec (max docker_preflight_min_sec timeout_sec)

let required_commands =
  [
    "sh";
    "bash";
    "cat";
    "find";
    "head";
    "tail";
    "wc";
    "git";
    "gh";
    "rg";
    "tree";
    "jq";
    "python3";
    "node";
    "npm";
    "make";
    "opam";
    "dune";
  ]

let option_field name = function
  | Some value -> (name, `String value)
  | None -> (name, `Null)

let dedupe_keep_order values =
  let seen = Hashtbl.create (List.length values) in
  List.filter
    (fun value ->
      if value = "" || Hashtbl.mem seen value then
        false
      else (
        Hashtbl.replace seen value ();
        true))
    values

let docker_image_present ~image ~timeout_sec =
  if String.trim image = "" then
    Error "keeper sandbox docker image is not configured"
  else
    let st, out =
      Process_eio.run_argv_with_status
        ~cwd:(Sys.getcwd ())
        ~timeout_sec
        [ "docker"; "image"; "inspect"; image ]
    in
    if st = Unix.WEXITED 0 then
      Ok ()
    else
      Error
        (Printf.sprintf
           "keeper sandbox image %s is not available locally: %s"
           image
           (Worker_dev_tools.truncate_for_log out))

let docker_image_required_commands ~image ~timeout_sec =
  let script =
    let quoted =
      List.map Filename.quote required_commands |> String.concat " "
    in
    Printf.sprintf
      "missing=''; for cmd in %s; do if ! command -v \"$cmd\" >/dev/null 2>&1; then missing=\"$missing$cmd\\n\"; fi; done; printf '%%s' \"$missing\""
      quoted
  in
  let st, out =
    Process_eio.run_argv_with_status
      ~cwd:(Sys.getcwd ())
      ~timeout_sec
      [ "docker"; "run"; "--rm"; "--network"; "none"; "--entrypoint"; "sh";
        image; "-lc"; script ]
  in
  if st = Unix.WEXITED 0 then
    let missing =
      out
      |> String.split_on_char '\n'
      |> List.map String.trim
      |> List.filter (fun item -> item <> "")
    in
    Ok missing
  else
    Error
      (Printf.sprintf
         "failed to inspect keeper sandbox image commands: %s"
         (Worker_dev_tools.truncate_for_log out))

let docker_preflight_to_yojson (preflight : docker_preflight) =
  `Assoc
    [
      ("backend", `String "docker");
      ("status", `String (if preflight.ok then "ok" else "error"));
      ("ok", `Bool preflight.ok);
      ("image", `String preflight.image);
      ("docker_runtime_ok", `Bool preflight.docker_runtime_ok);
      (option_field "docker_runtime_error" preflight.docker_runtime_error);
      ("hardening_ok", `Bool preflight.hardening_ok);
      (option_field "hardening_error" preflight.hardening_error);
      ("image_present", `Bool preflight.image_present);
      (option_field "image_error" preflight.image_error);
      ( "required_commands",
        `List
          (List.map
             (fun item ->
               `Assoc
                 [
                   ("command", `String item.command);
                   ("available", `Bool item.available);
                 ])
             preflight.required_commands) );
      ("missing_commands",
        `List (List.map (fun command -> `String command) preflight.missing_commands));
      ("next_actions",
        `List (List.map (fun action -> `String action) preflight.next_actions));
    ]

let docker_preflight_failure_message (preflight : docker_preflight) =
  let reasons =
    [
      preflight.docker_runtime_error;
      preflight.hardening_error;
      preflight.image_error;
      (if preflight.missing_commands = [] then
         None
       else
         Some
           (Printf.sprintf
              "keeper sandbox image is missing required commands: %s"
              (String.concat ", " preflight.missing_commands)));
    ]
    |> List.filter_map (fun item -> item)
    |> dedupe_keep_order
  in
  let next_actions =
    match preflight.next_actions with
    | [] -> ""
    | actions -> " Next: " ^ String.concat " " actions
  in
  Printf.sprintf "Docker sandbox preflight failed: %s.%s"
    (String.concat "; " reasons)
    next_actions

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
        match
          docker_info_security_options
            ~timeout_sec:(docker_preflight_timeout ~timeout_sec)
        with
        | Error _ as err -> err
        | Ok security_options ->
            let has needle =
              List.exists
                (fun option_text ->
                  String_util.contains_substring option_text needle)
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

let docker_preflight ~timeout_sec () =
  if not (Env_config_keeper.KeeperSandbox.preflight_enabled ()) then
    None
  else
    let timeout_sec = docker_preflight_timeout ~timeout_sec in
    let image = Env_config_keeper.KeeperSandbox.docker_image () in
    let docker_runtime_ok, docker_runtime_error =
      match docker_info_security_options ~timeout_sec with
      | Ok _ -> (true, None)
      | Error message -> (false, Some message)
    in
    let hardening_ok, hardening_error =
      match ensure_keeper_sandbox_runtime ~timeout_sec with
      | Ok _ -> (true, None)
      | Error message -> (false, Some message)
    in
    let image_present, image_error =
      match docker_image_present ~image ~timeout_sec with
      | Ok () -> (true, None)
      | Error message -> (false, Some message)
    in
    let missing_commands, command_error =
      if not image_present then
        ([], None)
      else
        match docker_image_required_commands ~image ~timeout_sec with
        | Ok missing -> (missing, None)
        | Error message -> ([], Some message)
    in
    let required_commands =
      List.map
        (fun command ->
          { command; available = not (List.mem command missing_commands) })
        required_commands
    in
    let next_actions =
      [
        (if not docker_runtime_ok then
           Some
             "Ensure Docker is installed and the daemon is reachable from this shell."
         else
           None);
        (if not image_present || missing_commands <> [] then
           Some
             "Run scripts/build-keeper-sandbox-image.sh to build the default keeper sandbox image."
         else
           None);
        (if not hardening_ok then
           Some
             "Fix the keeper sandbox hardening configuration (seccomp/rootless/userns) and rerun doctor."
         else
           None);
      ]
      |> List.filter_map (fun action -> action)
      |> dedupe_keep_order
    in
    let image_error =
      match image_error, command_error with
      | Some message, None -> Some message
      | None, Some message -> Some message
      | Some message, Some _ -> Some message
      | None, None -> None
    in
    Some
      {
        ok =
          docker_runtime_ok
          && hardening_ok
          && image_present
          && command_error = None
          && missing_commands = [];
        image;
        docker_runtime_ok;
        docker_runtime_error;
        hardening_ok;
        hardening_error;
        image_present;
        image_error;
        required_commands;
        missing_commands;
        next_actions;
      }

let ensure_keeper_startup_preflight ~timeout_sec ~sandbox_profile =
  match sandbox_profile with
  | Keeper_types.Local -> Ok ()
  | Keeper_types.Docker ->
      (match docker_preflight ~timeout_sec () with
       | None -> Ok ()
       | Some preflight ->
           if preflight.ok then Ok ()
           else Error (docker_preflight_failure_message preflight))
