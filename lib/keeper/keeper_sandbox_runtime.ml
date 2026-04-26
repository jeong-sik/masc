(** See .mli for contract.

    Extracted from [Keeper_exec_shell] (RFC-0006 Phase B-3b) so both
    [Keeper_exec_shell] (bash sandbox) and [Keeper_docker_read] (read
    sandbox) can preflight the host docker runtime against the
    configured hardening requirements without forming a module
    dependency cycle. *)

let docker_command () =
  match Sys.getenv_opt "MASC_TEST_FAKE_DOCKER_PATH" with
  | Some path when String.trim path <> "" -> path
  | _ ->
      let bin = "docker" in
      match Sys.getenv_opt "PATH" with
      | None -> bin
      | Some path ->
          let rec loop = function
            | [] -> bin
            | dir :: rest ->
                let dir = if dir = "" then "." else dir in
                let candidate = Filename.concat dir bin in
                (try
                   Unix.access candidate [ Unix.X_OK ];
                   candidate
                 with
                 | Unix.Unix_error _ -> loop rest)
          in
          loop (String.split_on_char ':' path)

let docker_command_argv () =
  match Sys.getenv_opt "MASC_TEST_FAKE_DOCKER_PATH" with
  | Some path when String.trim path <> "" -> [ "/bin/sh"; path ]
  | _ -> [ docker_command () ]

let docker_info_security_options ~timeout_sec =
  let st, out =
    Process_eio.run_argv_with_status
      ~env:(Unix.environment ())
      ~cwd:(Sys.getcwd ())
      ~timeout_sec
      (docker_command_argv () @ [ "info"; "--format"; "{{json .SecurityOptions}}" ])
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
    hard_mode : bool;
    credential_fallbacks_disabled : bool;
    git_egress : string;
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
    "ssh";
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

type cleanup_result =
  {
    scanned : int;
    removed : int;
    errors : string list;
  }

let sandbox_component_label_key = "masc.mcp.component"
let sandbox_component_label_value = "keeper-sandbox"
let sandbox_base_path_hash_label_key = "masc.mcp.base_path_hash"
let sandbox_keeper_label_key = "masc.mcp.keeper"
let sandbox_kind_label_key = "masc.mcp.kind"
let sandbox_owner_pid_label_key = "masc.mcp.owner_pid"
let sandbox_started_at_label_key = "masc.mcp.started_at"
let sandbox_network_label_key = "masc.mcp.network"
let sandbox_ttl_sec_label_key = "masc.mcp.ttl_sec"

let strip_trailing_slashes path =
  let rec loop i =
    if i > 0 && path.[i - 1] = '/' then loop (i - 1) else i
  in
  let len = loop (String.length path) in
  if len = String.length path then path else String.sub path 0 len

let normalize_base_path_for_hash base_path =
  let abs =
    if Filename.is_relative base_path then
      Filename.concat (Sys.getcwd ()) base_path
    else
      base_path
  in
  strip_trailing_slashes abs

let base_path_hash base_path =
  Digest.to_hex (Digest.string (normalize_base_path_for_hash base_path))

let sanitize_label_value value =
  String.map
    (function
      | 'a' .. 'z'
      | 'A' .. 'Z'
      | '0' .. '9'
      | '_'
      | '-'
      | '.' as c ->
          c
      | _ -> '_')
    value

let docker_label_args ?ttl_sec ~base_path ~keeper_name ~container_kind ~network_label () =
  let label key value = [ "--label"; key ^ "=" ^ value ] in
  label sandbox_component_label_key sandbox_component_label_value
  @ label sandbox_base_path_hash_label_key (base_path_hash base_path)
  @ label sandbox_keeper_label_key (sanitize_label_value keeper_name)
  @ label sandbox_kind_label_key (sanitize_label_value container_kind)
  @ label sandbox_owner_pid_label_key (string_of_int (Unix.getpid ()))
  @ label sandbox_started_at_label_key
      (Printf.sprintf "%.3f" (Unix.gettimeofday ()))
  @ label sandbox_network_label_key (sanitize_label_value network_label)
  @
  match ttl_sec with
  | Some value when value > 0.0 ->
      label sandbox_ttl_sec_label_key (Printf.sprintf "%.0f" value)
  | _ -> []

let docker_network_args = function
  | Keeper_types.Network_none -> ([ "--network"; "none" ], "none")
  | Keeper_types.Network_inherit -> ([], "inherit")

let docker_nofile_args () =
  let limit = Env_config_keeper.KeeperSandbox.nofile_limit () in
  [ "--ulimit"; Printf.sprintf "nofile=%d:%d" limit limit ]

type inspected_container =
  {
    owner_pid : int option;
    started_at : float option;
    running : bool option;
    ttl_sec : float option;
  }

type live_container =
  {
    id : string;
    name : string;
    image : string;
    status : string;
    running : bool option;
    created_at : string option;
    keeper_name : string option;
    container_kind : string option;
    network_label : string option;
    owner_pid : int option;
    started_at : float option;
    ttl_sec : float option;
  }

type stop_result =
  {
    matched : int;
    removed : int;
    errors : string list;
  }

(* #10488: previously used [String.trim] which strips ALL trailing
   whitespace including [\t]. Docker inspect templates emit tab-
   separated fields and a trailing-empty-field shows up as [...\t].
   [String.trim] silently dropped the trailing tab, collapsing 4
   tab-separated fields into 3 and breaking the exact-match parser
   below. Strip only the line-terminator [\r] so trailing-empty
   tab-separated fields survive. *)
let strip_cr line =
  let n = String.length line in
  if n > 0 && line.[n - 1] = '\r'
  then String.sub line 0 (n - 1)
  else line

let nonempty_lines out =
  out
  |> String.split_on_char '\n'
  |> List.map strip_cr
  |> List.filter (fun line -> line <> "")

let int_opt text =
  try Some (int_of_string (String.trim text)) with
  | Failure _ -> None

let float_opt text =
  try Some (float_of_string (String.trim text)) with
  | Failure _ -> None

let bool_opt text =
  match String.lowercase_ascii (String.trim text) with
  | "true" -> Some true
  | "false" -> Some false
  | _ -> None

let string_opt text =
  match String.trim text with
  | "" | "<no value>" -> None
  | value -> Some value

let strip_leading_slash text =
  let text = String.trim text in
  if String.length text > 0 && text.[0] = '/' then
    String.sub text 1 (String.length text - 1)
  else
    text

(* #10488: accept both 4-field (current schema, with [ttl_sec]
   label) and 3-field (legacy containers spawned before the
   [sandbox_ttl_sec] label was introduced) payloads.  Without this
   fallback, a single legacy container in the fleet produces a
   sustained 4.6%-of-events log spam loop because the 5-minute
   cleanup pass keeps re-attempting [parse_inspect_line] and
   keeps failing with [Error].  Treating [ttl_sec=None] is
   equivalent to "no TTL configured" — cleanup then falls back to
   the running-state / owner-pid heuristics, which is the correct
   semantics for a label-less container. *)
let parse_inspect_line line =
  match String.split_on_char '\t' line with
  | [ owner_pid; started_at; running; ttl_sec ] ->
      Ok
        {
          owner_pid = int_opt owner_pid;
          started_at = float_opt started_at;
          running = bool_opt running;
          ttl_sec = float_opt ttl_sec;
        }
  | [ owner_pid; started_at; running ] ->
      Ok
        {
          owner_pid = int_opt owner_pid;
          started_at = float_opt started_at;
          running = bool_opt running;
          ttl_sec = None;
        }
  | _ ->
      Error
        (Printf.sprintf "unexpected docker inspect cleanup payload: %s"
           (Worker_dev_tools.truncate_for_log line))

let parse_live_container_line line =
  match String.split_on_char '\t' line with
  | [
      id;
      name;
      image;
      status;
      running;
      created_at;
      keeper_name;
      container_kind;
      network_label;
      owner_pid;
      started_at;
      ttl_sec;
    ] ->
      Ok
        {
          id = String.trim id;
          name = strip_leading_slash name;
          image = String.trim image;
          status = String.trim status;
          running = bool_opt running;
          created_at = string_opt created_at;
          keeper_name = string_opt keeper_name;
          container_kind = string_opt container_kind;
          network_label = string_opt network_label;
          owner_pid = int_opt owner_pid;
          started_at = float_opt started_at;
          ttl_sec = float_opt ttl_sec;
        }
  | _ ->
      Error
        (Printf.sprintf "unexpected docker inspect container payload: %s"
           (Worker_dev_tools.truncate_for_log line))

let pid_alive pid =
  if pid <= 0 then
    false
  else
    try
      Unix.kill pid 0;
      true
    with
    | Unix.Unix_error (Unix.ESRCH, _, _) -> false
    | Unix.Unix_error (Unix.EPERM, _, _) -> true
    | Unix.Unix_error _ -> false

let should_remove_container ~now ~max_age_sec
    (inspected : inspected_container) =
  let stopped =
    match inspected.running with
    | Some false -> true
    | Some true | None -> false
  in
  let owner_dead =
    match inspected.owner_pid with
    | Some pid -> not (pid_alive pid)
    | None -> false
  in
  let age_limit =
    match inspected.ttl_sec with
    | Some ttl when ttl > 0.0 -> min max_age_sec ttl
    | _ -> max_age_sec
  in
  let expired =
    match inspected.started_at with
    | Some started_at -> now -. started_at > age_limit
    | None -> false
  in
  stopped || owner_dead || expired

let inspect_cleanup_container ~container_id ~timeout_sec =
  let format =
    "{{ index .Config.Labels \""
    ^ sandbox_owner_pid_label_key
    ^ "\" }}\t{{ index .Config.Labels \""
    ^ sandbox_started_at_label_key
    ^ "\" }}\t{{ .State.Running }}\t{{ index .Config.Labels \""
    ^ sandbox_ttl_sec_label_key
    ^ "\" }}"
  in
  let st, out =
    Process_eio.run_argv_with_status
      ~env:(Unix.environment ())
      ~cwd:(Sys.getcwd ())
      ~timeout_sec
      (docker_command_argv () @ [ "inspect"; "--format"; format; container_id ])
  in
  if st <> Unix.WEXITED 0 then
    Error
      (Printf.sprintf "docker inspect failed for cleanup container %s: %s"
         container_id
         (Worker_dev_tools.truncate_for_log out))
  else
    match nonempty_lines out with
    | line :: _ -> parse_inspect_line line
    | [] ->
        Error
          (Printf.sprintf
             "docker inspect returned no cleanup metadata for container %s"
             container_id)

let remove_cleanup_container ~container_id ~timeout_sec =
  let st, out =
    Process_eio.run_argv_with_status
      ~env:(Unix.environment ())
      ~cwd:(Sys.getcwd ())
      ~timeout_sec
      (docker_command_argv () @ [ "rm"; "-f"; container_id ])
  in
  if st = Unix.WEXITED 0 then
    Ok ()
  else
    Error
      (Printf.sprintf "docker rm -f failed for cleanup container %s: %s"
         container_id
         (Worker_dev_tools.truncate_for_log out))

let cleanup_stale_containers ?(now = Unix.gettimeofday ())
    ?(max_age_sec = Env_config_keeper.KeeperSandbox.cleanup_stale_after_sec ())
    ~base_path ~timeout_sec () =
  try
    let st, out =
      Process_eio.run_argv_with_status
        ~env:(Unix.environment ())
        ~cwd:(Sys.getcwd ())
        ~timeout_sec
        (docker_command_argv ()
        @ [
            "ps";
            "-aq";
            "--filter";
            "label="
            ^ sandbox_component_label_key
            ^ "="
            ^ sandbox_component_label_value;
            "--filter";
            "label="
            ^ sandbox_base_path_hash_label_key
            ^ "="
            ^ base_path_hash base_path;
          ])
    in
    if st <> Unix.WEXITED 0 then
      {
        scanned = 0;
        removed = 0;
        errors =
          [
            Printf.sprintf "docker ps failed during keeper sandbox cleanup: %s"
              (Worker_dev_tools.truncate_for_log out);
          ];
      }
    else
      let container_ids = nonempty_lines out in
      let scanned = List.length container_ids in
      let removed, errors =
        List.fold_left
          (fun (removed, errors) container_id ->
            match inspect_cleanup_container ~container_id ~timeout_sec with
            | Error err -> (removed, err :: errors)
            | Ok inspected ->
                if should_remove_container ~now ~max_age_sec inspected then
                  match remove_cleanup_container ~container_id ~timeout_sec with
                  | Ok () -> (removed + 1, errors)
                  | Error err -> (removed, err :: errors)
                else
                  (removed, errors))
          (0, [])
          container_ids
      in
      { scanned; removed; errors = List.rev errors }
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      {
        scanned = 0;
        removed = 0;
        errors =
          [
            Printf.sprintf "keeper sandbox cleanup failed: %s"
              (Printexc.to_string exn);
          ];
      }

let docker_filter_args ?keeper_name ?container_kind ~base_path () =
  let label_filter key value = [ "--filter"; "label=" ^ key ^ "=" ^ value ] in
  label_filter sandbox_component_label_key sandbox_component_label_value
  @ label_filter sandbox_base_path_hash_label_key (base_path_hash base_path)
  @
  (match keeper_name with
   | Some name when String.trim name <> "" ->
       label_filter sandbox_keeper_label_key (sanitize_label_value name)
   | _ -> [])
  @
  match container_kind with
  | Some kind when String.trim kind <> "" ->
      label_filter sandbox_kind_label_key (sanitize_label_value kind)
  | _ -> []

let list_container_ids ?keeper_name ?container_kind ~base_path ~timeout_sec () =
  try
    let st, out =
      Process_eio.run_argv_with_status
        ~env:(Unix.environment ())
        ~cwd:(Sys.getcwd ())
        ~timeout_sec
        (docker_command_argv () @ [ "ps"; "-aq" ]
         @ docker_filter_args ?keeper_name ?container_kind ~base_path ())
    in
    if st = Unix.WEXITED 0 then
      Ok (nonempty_lines out)
    else
      Error
        (Printf.sprintf "docker ps failed while listing keeper sandbox containers: %s"
           (Worker_dev_tools.truncate_for_log out))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      Error
        (Printf.sprintf "keeper sandbox container listing failed: %s"
           (Printexc.to_string exn))

let live_inspect_format =
  "{{ .Id }}\t{{ .Name }}\t{{ .Config.Image }}\t{{ .State.Status }}\t{{ .State.Running }}\t{{ .Created }}\t{{ index .Config.Labels \""
  ^ sandbox_keeper_label_key
  ^ "\" }}\t{{ index .Config.Labels \""
  ^ sandbox_kind_label_key
  ^ "\" }}\t{{ index .Config.Labels \""
  ^ sandbox_network_label_key
  ^ "\" }}\t{{ index .Config.Labels \""
  ^ sandbox_owner_pid_label_key
  ^ "\" }}\t{{ index .Config.Labels \""
  ^ sandbox_started_at_label_key
  ^ "\" }}\t{{ index .Config.Labels \""
  ^ sandbox_ttl_sec_label_key
  ^ "\" }}"

let list_containers ?keeper_name ?container_kind ~base_path ~timeout_sec () =
  match list_container_ids ?keeper_name ?container_kind ~base_path ~timeout_sec () with
  | Error _ as err -> err
  | Ok [] -> Ok []
  | Ok ids ->
      let st, out =
        Process_eio.run_argv_with_status
          ~env:(Unix.environment ())
          ~cwd:(Sys.getcwd ())
          ~timeout_sec
          (docker_command_argv () @ [ "inspect"; "--format"; live_inspect_format ] @ ids)
      in
      if st <> Unix.WEXITED 0 then
        Error
          (Printf.sprintf "docker inspect failed while listing keeper sandbox containers: %s"
             (Worker_dev_tools.truncate_for_log out))
      else
        let parsed =
          nonempty_lines out
          |> List.map parse_live_container_line
        in
        let errors =
          parsed
          |> List.filter_map (function Error err -> Some err | Ok _ -> None)
        in
        if errors <> [] then
          Error (String.concat "; " errors)
        else
          Ok
            (parsed
             |> List.filter_map (function Ok item -> Some item | Error _ -> None))

let option_string_field name = function
  | Some value -> (name, `String value)
  | None -> (name, `Null)

let option_float_field name = function
  | Some value -> (name, `Float value)
  | None -> (name, `Null)

let option_int_field name = function
  | Some value -> (name, `Int value)
  | None -> (name, `Null)

let option_bool_field name = function
  | Some value -> (name, `Bool value)
  | None -> (name, `Null)

let live_container_to_yojson (c : live_container) =
  `Assoc
    [
      ("id", `String c.id);
      ("name", `String c.name);
      ("image", `String c.image);
      ("status", `String c.status);
      option_bool_field "running" c.running;
      option_string_field "created_at" c.created_at;
      option_string_field "keeper_name" c.keeper_name;
      option_string_field "container_kind" c.container_kind;
      option_string_field "network_label" c.network_label;
      option_int_field "owner_pid" c.owner_pid;
      option_float_field "started_at" c.started_at;
      option_float_field "ttl_sec" c.ttl_sec;
    ]

let stop_containers ?keeper_name ?container_kind ~base_path ~timeout_sec () =
  match list_container_ids ?keeper_name ?container_kind ~base_path ~timeout_sec () with
  | Error err -> { matched = 0; removed = 0; errors = [ err ] }
  | Ok ids ->
      let removed, errors =
        List.fold_left
          (fun (removed, errors) container_id ->
            match remove_cleanup_container ~container_id ~timeout_sec with
            | Ok () -> (removed + 1, errors)
            | Error err -> (removed, err :: errors))
          (0, [])
          ids
      in
      { matched = List.length ids; removed; errors = List.rev errors }

let last_cleanup_at = ref 0.0

let maybe_cleanup_stale_containers ~base_path ~timeout_sec () =
  if not (Env_config_keeper.KeeperSandbox.cleanup_enabled ()) then
    None
  else
    let now = Unix.gettimeofday () in
    let interval = Env_config_keeper.KeeperSandbox.cleanup_interval_sec () in
    if now -. !last_cleanup_at < interval then
      None
    else (
      last_cleanup_at := now;
      Some (cleanup_stale_containers ~now ~base_path ~timeout_sec ()))

let docker_image_present ~image ~timeout_sec =
  if String.trim image = "" then
    Error "keeper sandbox docker image is not configured"
  else
    let st, out =
      Process_eio.run_argv_with_status
        ~env:(Unix.environment ())
        ~cwd:(Sys.getcwd ())
        ~timeout_sec
        (docker_command_argv () @ [ "image"; "inspect"; image ])
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
      ~env:(Unix.environment ())
      ~cwd:(Sys.getcwd ())
      ~timeout_sec
      (docker_command_argv ()
      @ [
          "run";
          "--rm";
          "--network";
          "none";
          "--entrypoint";
          "sh";
          image;
          "-lc";
          script;
        ])
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
      ("hard_mode", `Bool preflight.hard_mode);
      ( "credential_fallbacks_disabled",
        `Bool preflight.credential_fallbacks_disabled );
      ("git_egress", `String preflight.git_egress);
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
  let hard_mode = Env_config_keeper.KeeperSandbox.hard_mode () in
  let relax_fs = Env_config_keeper.KeeperSandbox.relax_fs () in
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
      if hard_mode && relax_fs then
        Error
          "sandbox hard mode requires MASC_KEEPER_SANDBOX_RELAX_FS=false"
      else if not require_rootless && not require_userns then
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
                (if hard_mode then
                   "sandbox hard mode requires Docker rootless mode"
                 else
                   "sandbox runtime requires Docker rootless mode (set MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS=false to disable this check)")
            else if require_userns && not (has "userns") then
              Error
                (if hard_mode then
                   "sandbox hard mode requires Docker userns support"
                 else
                   "sandbox runtime requires Docker userns support (set MASC_KEEPER_SANDBOX_REQUIRE_USERNS=false to disable this check)")
            else
              Ok seccomp_args

let docker_preflight ~timeout_sec () =
  if not (Env_config_keeper.KeeperSandbox.preflight_enabled ()) then
    None
  else
    let timeout_sec = docker_preflight_timeout ~timeout_sec in
    let hard_mode = Env_config_keeper.KeeperSandbox.hard_mode () in
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
             "Fix the keeper sandbox hardening configuration (seccomp/rootless/userns/hard-mode) and rerun doctor."
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
        hard_mode;
        credential_fallbacks_disabled = hard_mode;
        git_egress =
          (if hard_mode then "brokered_structured_tools"
           else if Env_config_keeper.KeeperSandbox.with_git_dispatch_enabled () then
             "docker_git_dispatch"
           else "container_network_policy");
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

module For_testing = struct
  let nonempty_lines = nonempty_lines

  (* Project the internal [inspected_container] record onto a tuple so
     the test does not need a re-exported type. Order:
     (owner_pid, started_at, running, ttl_sec). *)
  let parse_inspect_line line =
    parse_inspect_line line
    |> Result.map (fun (ic : inspected_container) ->
           (ic.owner_pid, ic.started_at, ic.running, ic.ttl_sec))
end
