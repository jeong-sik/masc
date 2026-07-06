(** Sidecar id, root, status, and script path helpers. *)

(** Whitelist of sidecars the backend will spawn or signal. Anything else
    short-circuits at the request boundary before any process dispatch can see
    an attacker-controlled id. *)
let known_ids = [ "discord"; "imessage"; "slack"; "telegram" ]

(** Pure whitelist check; exposed so unit tests can confirm shell-meta and
    path traversal in [name=] are rejected before any process dispatch is
    reached. *)
let validate_name = function
  | None -> Error "missing 'name' query parameter"
  | Some n when List.mem n known_ids -> Ok n
  | Some n -> Error (Printf.sprintf "unknown sidecar id: %s" n)
;;

let parse_name request = validate_name (Server_utils.query_param request "name")

let trim_opt = Env_config_core.trim_opt

let unresolved_runtime_base_path_message =
  Printf.sprintf
    "sidecar runtime base path is unresolved; pass the request workspace \
     base_path or set %s"
    Env_config_core.base_path_env_key
;;

let runtime_base_path_result ?base_path () =
  match trim_opt base_path with
  | Some path -> Ok path
  | None ->
    (match Config_dir_resolver.current_env_base_path_opt () with
     | Some path -> Ok (Config_dir_resolver.absolute_path path)
     | None -> Error unresolved_runtime_base_path_message)
;;

let runtime_base_path ?base_path () =
  match runtime_base_path_result ?base_path () with
  | Ok path -> path
  | Error msg -> invalid_arg msg
;;

let request_base_path state = (Mcp_server.workspace_config state).base_path
let dir_exists path = Sys.file_exists path && Sys.is_directory path

let project_root_from_executable () =
  let raw_exe =
    try Sys.executable_name with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> ""
  in
  let exe =
    if raw_exe = ""
    then ""
    else (
      try Unix.realpath raw_exe with
      | Unix.Unix_error _ | Sys_error _ | Invalid_argument _ -> raw_exe)
  in
  if exe = ""
  then None
  else (
    let rec walk dir =
      let parent = Filename.dirname dir in
      if String.equal parent dir
      then None
      else if String.equal (Filename.basename dir) "_build"
      then Some parent
      else walk parent
    in
    walk (Filename.dirname exe))
;;

let sidecar_root () = trim_opt (Sys.getenv_opt "MASC_SIDECAR_ROOT")

let sidecar_root_candidates ?sidecar_root ?project_root ~base_path () =
  [ sidecar_root; Some base_path; project_root ]
  |> List.filter_map (fun item -> item)
  |> Json_util.dedupe_keep_order
;;

let sidecar_dir_under root id =
  Filename.concat root (Printf.sprintf "sidecars/%s-bot" id)

let resolve_existing_sidecar_dir ?sidecar_root ?project_root ~base_path id =
  sidecar_root_candidates ?sidecar_root ?project_root ~base_path ()
  |> List.find_map (fun root ->
    let dir = sidecar_dir_under root id in
    if dir_exists dir then Some dir else None)
;;

let missing_sidecar_dir_message ?sidecar_root ?project_root ~base_path id =
  let searched =
    sidecar_root_candidates ?sidecar_root ?project_root ~base_path ()
    |> List.map (fun root -> sidecar_dir_under root id)
  in
  let searched_text =
    match searched with
    | [] -> "no candidate roots"
    | paths -> String.concat ", " paths
  in
  Printf.sprintf
    "sidecar directory not found for %s; looked under %s. Set \
     MASC_SIDECAR_ROOT=/path/to/masc or start the server with `start-masc.sh \
     --sidecar-root /path/to/masc`."
    id
    searched_text
;;

let today_yyyymmdd () =
  let tm = Unix.localtime (Unix.time ()) in
  Printf.sprintf "%04d%02d%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
;;

let legacy_status_rel id =
  Filename.concat Common.masc_dirname (Printf.sprintf "connectors/%s/status.json" id)
;;

type sidecar_status_config =
  { env_names : string list
  ; toml_keys : string list
  }

let sidecar_status_config = function
  | "discord" ->
    { env_names = [ "DISCORD_STATUS_PATH"; "discord_status_path" ]
    ; toml_keys = [ "discord_status_path"; "status_path" ]
    }
  | "imessage" ->
    { env_names = [ "IMESSAGE_STATUS_PATH"; "status_path" ]
    ; toml_keys = [ "status_path" ]
    }
  | "slack" ->
    { env_names = [ "SLACK_STATUS_PATH"; "MASC_SLACK_STATUS_PATH"; "status_path" ]
    ; toml_keys = [ "status_path" ]
    }
  | "telegram" ->
    { env_names = [ "TELEGRAM_STATUS_PATH"; "MASC_TELEGRAM_STATUS_PATH"; "status_path" ]
    ; toml_keys = [ "status_path" ]
    }
  | id -> invalid_arg (Printf.sprintf "unknown sidecar id: %s" id)
;;

let read_file path = Fs_compat.load_file path

let strip_matching_quotes value =
  let len = String.length value in
  if len >= 2
  then (
    let first = value.[0] in
    let last = value.[len - 1] in
    if (first = '"' && last = '"') || (first = '\'' && last = '\'')
    then String.sub value 1 (len - 2)
    else value)
  else value
;;

let parse_env_assignment line =
  let trimmed = String.trim line in
  if trimmed = "" || String.starts_with ~prefix:"#" trimmed
  then None
  else (
    let body =
      if String.starts_with ~prefix:"export " trimmed
      then String.sub trimmed 7 (String.length trimmed - 7) |> String.trim
      else trimmed
    in
    match String.index_opt body '=' with
    | None -> None
    | Some idx ->
      let key = String.sub body 0 idx |> String.trim in
      let raw_value =
        String.sub body (idx + 1) (String.length body - idx - 1) |> String.trim
      in
      trim_opt (Some key)
      |> Option.map (fun normalized_key ->
        normalized_key, strip_matching_quotes raw_value))
;;

let env_file_lookup path names =
  if not (Sys.file_exists path)
  then None
  else (
    let pairs =
      read_file path |> String.split_on_char '\n' |> List.filter_map parse_env_assignment
    in
    names |> List.find_map (fun name -> List.assoc_opt name pairs |> trim_opt))
;;

let toml_lookup_result path keys =
  if not (Sys.file_exists path)
  then Ok None
  else (
    match Keeper_toml_loader.parse_toml (read_file path) with
    | Error msg -> Error msg
    | Ok doc ->
      keys
      |> List.find_map (fun key ->
        match List.assoc_opt key doc with
        | Some (Keeper_toml_loader.Toml_string value) -> trim_opt (Some value)
        | _ -> None))
      |> fun value -> Ok value
;;

let toml_lookup path keys =
  match toml_lookup_result path keys with
  | Ok value -> value
  | Error msg ->
    Log.Keeper.warn "sidecar TOML lookup failed path=%s: %s" path msg;
    None
;;

let resolve_relative_path ~roots raw_path =
  let path = String.trim raw_path in
  if path = ""
  then []
  else if Filename.is_relative path
  then roots |> List.map (fun root -> Filename.concat root path)
  else [ path ]
;;

let first_existing_or_first = function
  | [] -> None
  | candidates ->
    (match List.find_opt Sys.file_exists candidates with
     | Some path -> Some path
     | None ->
       (match candidates with
        | first :: _ -> Some first
        | [] -> None))
;;

let runtime_toml_path ~base_path id =
  Filename.concat base_path (Printf.sprintf ".gate/runtime/%s/config.toml" id)
;;

let status_file_candidates ?sidecar_root ?project_root ?sidecar_dir ~base_path id =
  let roots = sidecar_root_candidates ?sidecar_root ?project_root ~base_path () in
  let cfg = sidecar_status_config id in
  let env_paths =
    cfg.env_names
    |> List.find_map (fun name -> trim_opt (Sys.getenv_opt name))
    |> Option.map (resolve_relative_path ~roots)
    |> Option.value ~default:[]
  in
  let dotenv_paths =
    match sidecar_dir with
    | None -> []
    | Some dir ->
      env_file_lookup (Filename.concat dir ".env") cfg.env_names
      |> Option.map (resolve_relative_path ~roots)
      |> Option.value ~default:[]
  in
  let toml_paths =
    roots
    |> List.filter_map (fun root ->
      toml_lookup (runtime_toml_path ~base_path:root id) cfg.toml_keys
      |> Option.map (fun raw -> resolve_relative_path ~roots:[ root ] raw))
    |> List.concat
  in
  let default_paths =
    resolve_relative_path ~roots (Printf.sprintf ".gate/runtime/%s/status.json" id)
  in
  let legacy_paths = resolve_relative_path ~roots (legacy_status_rel id) in
  Json_util.dedupe_keep_order (env_paths @ dotenv_paths @ toml_paths @ default_paths @ legacy_paths)
;;

let status_file ?sidecar_root ?project_root ?sidecar_dir ~base_path id =
  status_file_candidates ?sidecar_root ?project_root ?sidecar_dir ~base_path id
  |> first_existing_or_first
  |> Option.value ~default:(Filename.concat base_path (legacy_status_rel id))
;;

let log_file_candidates ?sidecar_root ?project_root ~base_path id =
  let roots = sidecar_root_candidates ?sidecar_root ?project_root ~base_path () in
  roots
  |> List.map (fun root ->
    Filename.concat
      (Common.masc_dir_from_base_path ~base_path:root)
      (Printf.sprintf "logs/%s-sidecar-%s.log" id (today_yyyymmdd ())))
  |> Json_util.dedupe_keep_order
;;

let today_log_file ?sidecar_root ?project_root ~base_path id =
  log_file_candidates ?sidecar_root ?project_root ~base_path id
  |> first_existing_or_first
  |> Option.value
       ~default:
         (Filename.concat
            (Common.masc_dir_from_base_path ~base_path)
            (Printf.sprintf "logs/%s-sidecar-%s.log" id (today_yyyymmdd ())))
;;

let runtime_sidecar_dir_result ?base_path id =
  match runtime_base_path_result ?base_path () with
  | Error _ as error -> error
  | Ok runtime_base_path ->
    let configured_sidecar_root = sidecar_root () in
    let project_root = project_root_from_executable () in
    (match
       resolve_existing_sidecar_dir
         ?sidecar_root:configured_sidecar_root
         ?project_root
         ~base_path:runtime_base_path
         id
     with
     | Some dir -> Ok dir
     | None ->
       Error
         (missing_sidecar_dir_message
            ?sidecar_root:configured_sidecar_root
            ?project_root
            ~base_path:runtime_base_path
            id))
;;

let runtime_sidecar_script_result ?base_path id =
  match runtime_sidecar_dir_result ?base_path id with
  | Error _ as error -> error
  | Ok dir ->
    let script = Filename.concat dir "run.sh" in
    if Sys.file_exists script
    then Ok script
    else
      Error
        (Printf.sprintf
           "sidecar run.sh not found for %s at %s. Set \
            MASC_SIDECAR_ROOT=/path/to/masc or start the server with \
            `start-masc.sh --sidecar-root /path/to/masc`."
           id
           script)
;;
