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

type violation = Implicit_base_path of resolved

type canonicalization_error =
  { base_path : string
  ; cause : exn
  ; backtrace : Printexc.raw_backtrace
  }

let resolution_source_label = function
  | Explicit_cli -> "explicit_cli"
  | Explicit_env -> "explicit_env"
  | Implicit_default -> "implicit_base_path"

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

let enforce resolved =
  match resolved.resolution_source with
  | Implicit_default -> Error (Implicit_base_path resolved)
  | Explicit_cli | Explicit_env -> Ok ()

let canonicalize_existing base_path =
  match Unix.realpath base_path with
  | canonical -> Ok canonical
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception ((Unix.Unix_error _ | Sys_error _) as cause) ->
    Error
      { base_path
      ; cause
      ; backtrace = Printexc.get_raw_backtrace ()
      }
;;

let format_canonicalization_error { base_path; cause; backtrace = _ } =
  Printf.sprintf
    "[FATAL] Could not establish canonical BasePath identity for %S: %s"
    base_path
    (Printexc.to_string cause)
;;

let format_violation = function
  | Implicit_base_path resolved ->
      Printf.sprintf
        "[FATAL] Server refused to start with an implicit base path.\n\
         Resolution source: %s\n\
         Resolved path: %s\n\n\
         Start the server with an explicit base path:\n\
         --base-path /path/to/workspace     (CLI flag)\n\
         MASC_BASE_PATH=/path/to/workspace  (environment variable)\n\n\
         Choose the intended runtime root explicitly; no directory kind is inferred.\n"
        (resolution_source_label resolved.resolution_source)
        resolved.normalized_base_path

let exit_on_violation = function
  | Ok () -> ()
  | Error violation ->
      Printf.eprintf "%s" (format_violation violation);
      exit 1
