(** MASC Environment Configuration

    Centralized environment variable management following 12-Factor App principles.
    All env vars use MASC_* prefix for consistency.

    Functions ending in [_result] return [(string, string) result] and are
    the preferred API.  Convenience functions without [_result] suffix raise
    {!Config_error} on missing/invalid environment variables.

    Usage:
      let threshold = Env_config.Zombie.threshold_seconds
      let lock_timeout = Env_config.Lock.timeout_seconds
*)

(** Raised by convenience functions ([me_root], [sb_path],
    [masc_http_base_url]) when a required environment variable is missing.
    Prefer the [_result] variants for structured error handling. *)
exception Config_error of string

let () = Printexc.register_printer (function
  | Config_error msg -> Some (Printf.sprintf "Env_config_core.Config_error: %s" msg)
  | _ -> None)

(** Safe getters with defaults *)
let get_string ~default name =
  match Sys.getenv_opt name with
  | Some v -> v
  | None -> default

let get_int ~default name =
  match Sys.getenv_opt name with
  | Some v -> Safe_ops.int_of_string_with_default ~default v
  | None -> default

let get_float ~default name =
  match Sys.getenv_opt name with
  | Some v -> Safe_ops.float_of_string_with_default ~default v
  | None -> default

let get_bool ~default name =
  match Sys.getenv_opt name with
  | Some v ->
      (match String.lowercase_ascii v with
       | "true" | "1" | "yes" -> true
       | "false" | "0" | "no" -> false
       | _ -> default)
  | None -> default

let trim_opt = function
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

let strip_trailing_slashes value =
  let rec loop idx =
    if idx <= 0 then ""
    else if value.[idx - 1] = '/' then loop (idx - 1)
    else String.sub value 0 idx
  in
  loop (String.length value)

let existing_dir path =
  Sys.file_exists path && Sys.is_directory path

let existing_file path =
  Sys.file_exists path && not (Sys.is_directory path)

let home_dir_opt () =
  Sys.getenv_opt "HOME" |> trim_opt

let me_root_opt () =
  match Sys.getenv_opt "MASC_WORKSPACE_ROOT" |> trim_opt with
  | Some path -> Some path
  | None -> (
      match Sys.getenv_opt "ME_ROOT" |> trim_opt with
      | Some path -> Some path
      | None -> Sys.getenv_opt "DUNE_SOURCEROOT" |> trim_opt)

let me_root_result () =
  match me_root_opt () with
  | Some path -> Ok path
  | None ->
      Error
        "MASC_WORKSPACE_ROOT or ME_ROOT is required (tests may use DUNE_SOURCEROOT)"

let me_root () =
  match me_root_result () with
  | Ok path -> path
  | Error msg -> raise (Config_error msg)

(** Log a deprecation warning when a legacy env var is set.
    Called once per legacy var at startup/first-read. *)
let deprecation_warned = Hashtbl.create 8

let warn_deprecated ~old_name ~new_name =
  if not (Hashtbl.mem deprecation_warned old_name) then begin
    Hashtbl.replace deprecation_warned old_name true;
    Printf.eprintf
      "[WARN] env %s is deprecated; use %s instead. Support will be removed in a future release.\n%!"
      old_name new_name
  end

let deprecated_opt ~old_name ~new_name =
  match Sys.getenv_opt old_name |> trim_opt with
  | Some value ->
      warn_deprecated ~old_name ~new_name;
      Some value
  | None -> None

let sb_path_opt () =
  match deprecated_opt ~old_name:"MASC_SB_PATH"
          ~new_name:"MASC_WORKSPACE_ROOT or ME_ROOT" with
  | Some path -> Some path
  | None -> (
      match me_root_opt () with
      | Some root ->
          let path = Filename.concat root "scripts/sb" in
          if existing_file path then Some path else None
      | None -> None)

let sb_path_result () =
  match sb_path_opt () with
  | Some path -> Ok path
  | None ->
      Error
        "Unable to resolve scripts/sb. Set MASC_WORKSPACE_ROOT or ME_ROOT."

let sb_path () =
  match sb_path_result () with
  | Ok path -> path
  | Error msg -> raise (Config_error msg)

let masc_http_port () =
  match Sys.getenv_opt "MASC_HTTP_PORT" |> trim_opt with
  | Some port -> port
  | None -> (
      match Sys.getenv_opt "MASC_PORT" |> trim_opt with
      | Some port ->
          warn_deprecated ~old_name:"MASC_PORT" ~new_name:"MASC_HTTP_PORT";
          port
      | None -> "8935")

let masc_http_port_int () =
  Safe_ops.int_of_string_with_default ~default:8935 (masc_http_port ())

let masc_host_opt () =
  match Sys.getenv_opt "MASC_HOST" |> trim_opt with
  | Some host -> Some host
  | None -> deprecated_opt ~old_name:"MASC_HTTP_BIND_HOST" ~new_name:"MASC_HOST"

(** Centralized MASC_HOST reader.
    Reads MASC_HOST (primary) with MASC_HTTP_BIND_HOST (deprecated) fallback.
    Default: "127.0.0.1". *)
let masc_host () =
  match masc_host_opt () with
  | Some host -> host
  | None -> "127.0.0.1"

(** Centralized MASC_ASSETS_DIR reader.
    Reads MASC_ASSETS_DIR (primary) with MASC_ASSETS_ROOT (deprecated) fallback.
    Returns None when neither is set. *)
let assets_dir_opt () =
  match Sys.getenv_opt "MASC_ASSETS_DIR" |> trim_opt with
  | Some dir -> Some dir
  | None ->
      deprecated_opt ~old_name:"MASC_ASSETS_ROOT" ~new_name:"MASC_ASSETS_DIR"

let cluster_name_opt () =
  Sys.getenv_opt "MASC_CLUSTER_NAME" |> trim_opt

(** Centralized MASC_CLUSTER_NAME reader.
    Default: "default". All call sites should use this instead of
    reading Sys.getenv_opt "MASC_CLUSTER_NAME" directly. *)
let cluster_name () =
  match cluster_name_opt () with
  | Some name -> name
  | None -> "default"

let rec masc_http_base_url () =
  match masc_http_base_url_result () with
  | Ok base -> base
  | Error msg -> raise (Config_error msg)

and masc_http_base_url_result () =
  match Sys.getenv_opt "MASC_HTTP_BASE_URL" |> trim_opt with
  | Some base -> Ok (strip_trailing_slashes base)
  | None ->
      let host =
        match masc_host_opt () with
        | Some value -> Ok value
        | None ->
            Error
              "MASC_HTTP_BASE_URL is required (or set MASC_HOST with MASC_HTTP_PORT)"
      in
      Result.map
        (fun host -> Printf.sprintf "http://%s:%s" host (masc_http_port ()))
        host

let libdatachannel_path_candidates () =
  let env_path =
    Sys.getenv_opt "LIBDATACHANNEL_PATH" |> trim_opt |> Option.to_list
  in
  let common =
    [
      "/usr/local/lib/libdatachannel.dylib";
      "/opt/homebrew/lib/libdatachannel.dylib";
      "/usr/lib/libdatachannel.dylib";
      "/usr/local/lib/libdatachannel.so";
      "/usr/lib/libdatachannel.so";
    ]
  in
  let home_local =
    match home_dir_opt () with
    | Some home -> [ Filename.concat home "local/lib/libdatachannel.dylib" ]
    | None -> []
  in
  env_path @ common @ home_local

let libdatachannel_path_opt () =
  libdatachannel_path_candidates ()
  |> List.find_opt existing_file

(** {1 Zombie Detection / Cleanup Configuration} *)
