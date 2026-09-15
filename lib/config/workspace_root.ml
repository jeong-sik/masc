type source =
  | Flag
  | Environment
  | Current_directory
  | Recorded of { record : string }

type t =
  { root : string
  ; requested : string
  ; source : source
  }

type recorded =
  | No_record
  | Record of { record : string; path : string }

type observation =
  { flag : string option
  ; environment : string option
  ; cwd : string option
  ; recorded : recorded
  ; is_workspace : string -> bool
  ; realpath : string -> string option
  }

type error =
  | No_workspace of
      { cwd : string option
      ; stale_record : (string * string) option
      }

let present value =
  match value with
  | None -> None
  | Some raw ->
    let trimmed = String.trim raw in
    if String.equal trimmed "" then None else Some trimmed

let absolute ~cwd path =
  if not (Filename.is_relative path) then path
  else
    match cwd with
    | Some cwd -> Filename.concat cwd path
    | None -> path

let root_of observation raw =
  let normalized =
    Env_config_core.normalize_masc_base_path_input
      (absolute ~cwd:observation.cwd raw)
  in
  match observation.realpath normalized with
  | Some canonical -> canonical
  | None -> normalized

let chosen observation source raw =
  Ok { root = root_of observation raw; requested = raw; source }

let inferred_recorded observation =
  match observation.recorded with
  | No_record ->
    Error (No_workspace { cwd = observation.cwd; stale_record = None })
  | Record { record; path } ->
    if (not (Filename.is_relative path)) && observation.is_workspace path
    then chosen observation (Recorded { record }) path
    else
      Error
        (No_workspace { cwd = observation.cwd; stale_record = Some (record, path) })

let inferred observation =
  match observation.cwd with
  | Some cwd when observation.is_workspace cwd ->
    chosen observation Current_directory cwd
  | Some _ | None -> inferred_recorded observation

let resolve observation =
  match present observation.flag with
  | Some raw -> chosen observation Flag raw
  | None ->
    (match present observation.environment with
     | Some raw -> chosen observation Environment raw
     | None -> inferred observation)

let directory_exists path =
  try Sys.is_directory path with
  | Sys_error _ -> false

let holds_config dir =
  directory_exists
    (Filename.concat (Filename.concat dir Common.masc_dirname) "config")

let realpath path =
  try Some (Unix.realpath path) with
  | Unix.Unix_error _ -> None

let recorded_now () =
  match Env_config_core.persisted_default_base_path () with
  | Env_config_core.Usable { record; base_path } -> Record { record; path = base_path }
  | Env_config_core.Stale { record; recorded_path } -> Record { record; path = recorded_path }
  | Env_config_core.No_record | Env_config_core.Unread_under_test _ -> No_record

let observe ~flag () =
  { flag
  ; environment = Env_config_core.raw_value_opt Env_config_core.base_path_env_key
  ; cwd = (try Some (Sys.getcwd ()) with Sys_error _ -> None)
  ; recorded = recorded_now ()
  ; is_workspace = holds_config
  ; realpath
  }

let resolve_current ~flag = resolve (observe ~flag ())

(* The first three keep the labels the server has always exported, so the
   health diagnostics that read MASC_BASE_PATH_RESOLUTION_SOURCE are unchanged. *)
let source_label = function
  | Flag -> "explicit_cli"
  | Environment -> "explicit_env"
  | Recorded _ -> "persisted_default"
  | Current_directory -> "current_directory"

let error_message (No_workspace { cwd; stale_record }) =
  let config = Filename.concat Common.masc_dirname "config" in
  let cwd_line =
    match cwd with
    | Some cwd -> Printf.sprintf "The current directory %s holds no %s." cwd config
    | None -> "The current directory could not be read."
  in
  let record_line =
    match stale_record with
    | Some (record, path) ->
      [ Printf.sprintf
          "The default recorded in %s names %s, which is not an absolute path \
           holding %s, so it was ignored."
          record path config ]
    | None -> []
  in
  String.concat "\n"
    ([ "No MASC workspace was found."; cwd_line ]
     @ record_line
     @ [ "Choose one:"
       ; "  masc <command> --base-path <workspace>"
       ; "  MASC_BASE_PATH=<workspace> masc <command>"
       ; Printf.sprintf "  run the command inside a workspace (a directory holding %s)" config
       ; "`masc init --base-path <workspace> --record-default` makes that workspace the default."
       ])
