(** Shared startup guard for server runtime base paths. *)

type resolution_source =
  | Explicit_cli
  | Explicit_env
  | Implicit_default

type resolved = {
  raw_base_path : string;
  normalized_base_path : string;
  resolution_source : resolution_source;
}

type repo_marker =
  | Git_metadata
  | Dune_project
  | Masc_opam

type violation =
  | Implicit_base_path of resolved
  | Source_repo_base_path of {
      base_path : string;
      executable : string option;
      markers : repo_marker list;
    }

let resolution_source_label = function
  | Explicit_cli -> "explicit_cli"
  | Explicit_env -> "explicit_env"
  | Implicit_default -> "implicit_base_path"

let repo_marker_path = function
  | Git_metadata -> ".git"
  | Dune_project -> "dune-project"
  | Masc_opam -> "masc.opam"

let non_blank value =
  match value with
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

let normalize raw =
  Env_config.normalize_masc_base_path_input raw

let resolve_startup_base_path ?(getenv = Sys.getenv_opt) ~cli_base_path
    ~default_base_path () =
  let raw_base_path, resolution_source =
    match non_blank cli_base_path with
    | Some raw -> raw, Explicit_cli
    | None -> (
        match non_blank (getenv "MASC_BASE_PATH") with
        | Some raw -> raw, Explicit_env
        | None -> default_base_path (), Implicit_default)
  in
  { raw_base_path;
    normalized_base_path = normalize raw_base_path;
    resolution_source;
  }

let realpath_opt path =
  try Some (Unix.realpath path) with Unix.Unix_error _ -> None

let realpath_or_input path =
  match realpath_opt path with
  | Some path -> path
  | None -> path

let path_exists base marker =
  Sys.file_exists (Filename.concat base (repo_marker_path marker))

let source_repo_markers base_path =
  let markers = [ Git_metadata; Dune_project; Masc_opam ] in
  if List.for_all (path_exists base_path) markers then markers else []

let executable_under_base_build base_path =
  match realpath_opt Sys.executable_name with
  | None -> None
  | Some executable ->
      let build_prefix = Filename.concat (realpath_or_input base_path) "_build" ^ "/" in
      if String.starts_with ~prefix:build_prefix executable then Some executable else None

let enforce resolved =
  match resolved.resolution_source with
  | Implicit_default -> Error (Implicit_base_path resolved)
  | Explicit_cli | Explicit_env ->
      let base_path = resolved.normalized_base_path in
      let markers = source_repo_markers base_path in
      let executable = executable_under_base_build base_path in
      if markers <> [] || Option.is_some executable then
        Error (Source_repo_base_path { base_path; executable; markers })
      else
        Ok ()

let format_marker marker = repo_marker_path marker

let format_violation = function
  | Implicit_base_path resolved ->
      Printf.sprintf
        "[FATAL] Server refused to start with an implicit base path.\n\
         Resolution source: %s\n\
         Resolved path: %s\n\n\
         Start the server with an explicit base path:\n\
         --base-path /path/to/workspace     (CLI flag)\n\
         MASC_BASE_PATH=/path/to/workspace  (environment variable)\n\n\
         Use a workspace root, not the repository checkout or $HOME directly.\n"
        (resolution_source_label resolved.resolution_source)
        resolved.normalized_base_path
  | Source_repo_base_path { base_path; executable; markers } ->
      let marker_text =
        match markers with
        | [] -> "(executable is under _build)"
        | markers -> String.concat ", " (List.map format_marker markers)
      in
      let executable_text =
        match executable with
        | Some executable -> executable
        | None -> "(not under base _build)"
      in
      Printf.sprintf
        "[FATAL] --base-path points to the MASC source repo: %s\n\
         Source markers: %s\n\
         Executable: %s\n\
         Runtime state would pollute the repo. Use a workspace root instead:\n\
         --base-path $MASC_BASE_PATH    (recommended)\n\
         --base-path /path/to/workspace (explicit workspace root)\n\
         Or start via: sb mcp masc start\n"
        base_path marker_text executable_text

let exit_on_violation = function
  | Ok () -> ()
  | Error violation ->
      Printf.eprintf "%s" (format_violation violation);
      exit 1
