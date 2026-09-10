type t = Runtime_antigravity_home.t
type error = Private_home_unavailable | Sign_in_required | Unsafe_credential
  | Command_failed | Invalid_catalog | Keychain_unavailable
let error_message = function
  | Private_home_unavailable -> "Antigravity's private account directory is unavailable."
  | Sign_in_required -> "Sign in with the official Antigravity CLI, then continue setup."
  | Unsafe_credential -> "The selected Antigravity credential is not a private owned file."
  | Command_failed -> "The official Antigravity account command did not complete."
  | Invalid_catalog -> "The official Antigravity model catalog has an unsupported response format."
  | Keychain_unavailable -> "The selected Antigravity keychain could not be read or its private account could not be switched. Unlock that account and retry; no fallback account was selected."
let ( let* ) = Result.bind
let prepare ~runtime_root ~account_id =
  Runtime_antigravity_home.prepare_for_login ~runtime_root ~owner_leaf:account_id
  |> Result.map_error (fun _ -> Private_home_unavailable)
let prepare_from_credential_file ~runtime_root ~account_id ~oauth_source =
  Runtime_antigravity_home.prepare ~runtime_root ~owner_leaf:account_id ~oauth_source
  |> Result.map_error (fun _ -> Unsafe_credential)
let home_dir = Runtime_antigravity_home.home_dir
let environment home = Runtime_antigravity.official_client_environment ~home_dir:(home_dir home) ()
let private_file path =
  match Fs_compat.load_owned_regular_file_with_snapshot ~ownership_root:(Filename.dirname path) path with
  | Error _ -> Error Unsafe_credential
  | Ok None -> Ok None
  | Ok (Some file) when file.snapshot.owner_uid <> Unix.geteuid () || file.snapshot.permissions <> 0o600 ->
    Error Unsafe_credential
  | Ok (Some file) when String.trim file.content = "" -> Ok None
  | Ok (Some file) -> Ok (Some file.content)
let canonical_file home = Filename.concat home ".gemini/antigravity-cli/antigravity-oauth-token"
let keychain_path home = Filename.concat home "Library/Keychains/login.keychain-db"
let keychain_present path =
  try
    let stat = Unix.lstat path in
    if stat.st_kind = Unix.S_REG && stat.st_uid = Unix.geteuid () then Ok true
    else Error Unsafe_credential
  with Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
     | Unix.Unix_error _ -> Error Unsafe_credential
let import_with ~read_keychain ~clear_keychain ~source_home home =
  if Filename.is_relative source_home then Error Unsafe_credential else
  let source_keychain = keychain_path source_home in
  let* exists = keychain_present source_keychain in
  let selected = if exists then read_keychain ~path:source_keychain else Apple_keychain.Missing in
  let* contents = match selected with
    | Apple_keychain.Found contents -> Ok contents
    | Unavailable -> Error Keychain_unavailable
    | Missing | Unsupported ->
      let* file = private_file (canonical_file source_home) in
      (match file with Some contents -> Ok contents | None -> Error Sign_in_required) in
  (* Capture the selected account first, including capture_login where source and
     destination are identical. Clear only the managed destination's exact item;
     otherwise keyring-first CLI reads would ignore the newly copied fallback. *)
  let destination_keychain = keychain_path (home_dir home) in
  let* destination_exists = keychain_present destination_keychain in
  let* () = if not destination_exists then Ok () else
    clear_keychain ~path:destination_keychain |> Result.map_error (fun () -> Keychain_unavailable) in
  try Auth.save_private_text_file (Runtime_antigravity_home.oauth_path home) contents; Ok ()
  with Sys_error _ | Unix.Unix_error _ -> Error Private_home_unavailable
let import_signed_in ~source_home home =
  import_with ~read_keychain:Apple_keychain.read ~clear_keychain:Apple_keychain.clear ~source_home home
module For_testing = struct
  let import_with = import_with
end
let capture_login home = import_signed_in ~source_home:(home_dir home) home
let credential_reference home =
  let path = Runtime_antigravity_home.oauth_path home in
  let* contents = private_file path in
  match contents with None -> Error Sign_in_required | Some _ -> Ok (Runtime_schema.File path)

type model = { id : string; label : string }
let parse_models body =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string body in
    if json |> member "status" <> `String "SUCCESS"
      || json |> member "num_turns" <> `Int 0
      || json |> member "usage" |> member "total_tokens" <> `Int 0
      || json |> member "command" |> member "name" <> `String "models"
    then Error Invalid_catalog else
    let rows = json |> member "command" |> member "data" |> member "models" |> to_list in
    let rec decode seen rows = match rows with
      | [] -> Ok (List.rev seen)
      | row :: rest ->
        let id = row |> member "id" |> to_string in
        let label = row |> member "label" |> to_string in
        if String.trim id = "" || String.trim label = "" || List.exists (fun model -> model.id = id) seen
        then Error Invalid_catalog else decode ({id;label} :: seen) rest in
    decode [] rows
  with Yojson.Json_error _ | Type_error _ -> Error Invalid_catalog
let discover_models ~cli_path ~timeout_s home =
  match Process_eio.run_argv_with_status_split_or_refusal ~timeout_sec:timeout_s
    ~env:(environment home) ~cwd:(home_dir home)
    [cli_path; "--output-format"; "json"; "models"] with
  | Ok (Unix.WEXITED 0, body, _) -> parse_models body
  | Ok _ | Error _ -> Error Command_failed
let models_json models = `Assoc [
  "source", `String "antigravity_cli_models";
  "account_availability_verified", `Bool false;
  "models", `List (List.map (fun model -> `Assoc [
    "id", `String model.id; "label", `String model.label;
    "effective_context", `Null; "account_availability_verified", `Bool false]) models)]

type context_observation = Unknown_context | Observed_context of int
let parse_context ~model ~cli_version body =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string body in
    let context = json |> member "context_window" in
    let actual_model = json |> member "model" in
    if json |> member "version" <> `String cli_version
      || context |> member "total_input_tokens" <> `Int 0
      || context |> member "total_output_tokens" <> `Int 0
      || context |> member "current_usage" <> `Null
    then Error Invalid_catalog
    else if actual_model = `Null then Ok Unknown_context
    else
      let actual_id = actual_model |> member "id" |> to_string in
      let actual_label = actual_model |> member "display_name" |> to_string in
      if not ((actual_id = model.id || actual_id = model.label) && actual_label = model.label)
      then Error Invalid_catalog
      else match context |> member "context_window_size" with
        | `Int size when size > 0 -> Ok (Observed_context size)
        | `Int 0 | `Null -> Ok Unknown_context
        | _ -> Error Invalid_catalog
  with Yojson.Json_error _ | Type_error _ -> Error Invalid_catalog
