type status = Running | Complete of Runtime_setup_login_client.observation
  | Failed | Cancelled | Interrupted
type t = {
  login_id : string;
  integration_id : string;
  account_ref : Runtime_setup_accounts.reference option;
  status : status;
}
type error = Not_found | Unavailable
let ( let* ) = Result.bind

let observation_name = function
  | Runtime_setup_login_client.Authenticated -> "authenticated"
  | Login_completed -> "login_completed"
  | Credential_captured -> "credential_captured"

let to_json t =
  let status, authentication = match t.status with
    | Running -> "running", []
    | Complete observed -> "complete", ["authentication", `String (observation_name observed)]
    | Failed -> "failed", []
    | Cancelled -> "cancelled", []
    | Interrupted -> "interrupted", [] in
  let reference = match t.account_ref with
    | None -> []
    | Some reference -> ["account_ref", `String (Runtime_setup_accounts.reference_to_string reference)] in
  `Assoc (["login_id", `String t.login_id; "integration_id", `String t.integration_id;
    "status", `String status; "invocation_verified", `Bool false] @ reference @ authentication)

let scope ~workspace ~actor =
  let workspace = Unix.realpath workspace in
  Auth.sha256_hash (Yojson.Safe.to_string (`List [`String workspace; `String actor]))

let directory ~create path =
  if create then (try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let info = Unix.lstat path in
  if info.st_kind = Unix.S_DIR && info.st_uid = Unix.geteuid () && info.st_perm land 0o077 = 0
  then Ok () else Error Unavailable

let root ~create () =
  match Env_config_core.default_base_path_record_path_opt () with
  | None -> Error Unavailable
  | Some record ->
    let parent = Filename.dirname record in
    if Filename.is_relative parent then Error Unavailable else
    let credentials = Filename.concat parent "credentials" in
    let root = Filename.concat credentials "setup-logins" in
    if create then Fs_compat.mkdir_p parent;
    let* () = directory ~create credentials in
    let* () = directory ~create root in
    Ok (Unix.realpath root)

let filesystem action =
  try Eio_guard.run_in_systhread ~label:"setup-login-receipt" action with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Error Not_found
  | Unix.Unix_error _ | Sys_error _ -> Error Unavailable

let save ~workspace ~actor t = filesystem (fun () ->
  if not (Auth.is_generated_token_shape t.login_id) then Error Unavailable else
  let scope = scope ~workspace ~actor in
  let* root = root ~create:true () in
  let path = Filename.concat root (t.login_id ^ ".json") in
  Auth.save_private_text_file path
    (Yojson.Safe.to_string (`Assoc ["scope", `String scope; "receipt", to_json t]));
  Ok ())

let decode ~login_id = function
  | `Assoc fields when List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields))
      && List.for_all (fun (key, _) -> List.mem key
        ["login_id"; "integration_id"; "status"; "invocation_verified"; "account_ref"; "authentication"]) fields ->
    let* integration_id = match List.assoc_opt "login_id" fields, List.assoc_opt "integration_id" fields,
        List.assoc_opt "invocation_verified" fields with
      | Some (`String stored_id), Some (`String integration_id), Some (`Bool false)
        when String.equal stored_id login_id && String.trim integration_id <> "" -> Ok integration_id
      | _ -> Error Unavailable in
    let* account_ref = match List.assoc_opt "account_ref" fields with
      | None -> Ok None
      | Some (`String value) -> Runtime_setup_accounts.reference_of_string value
          |> Result.map Option.some |> Result.map_error (fun _ -> Unavailable)
      | Some _ -> Error Unavailable in
    let* status = match List.assoc_opt "status" fields, List.assoc_opt "authentication" fields with
      | Some (`String "running"), None -> Ok Running
      | Some (`String "failed"), None -> Ok Failed
      | Some (`String "cancelled"), None -> Ok Cancelled
      | Some (`String "interrupted"), None -> Ok Interrupted
      | Some (`String "complete"), Some (`String "authenticated") -> Ok (Complete Authenticated)
      | Some (`String "complete"), Some (`String "login_completed") -> Ok (Complete Login_completed)
      | Some (`String "complete"), Some (`String "credential_captured") -> Ok (Complete Credential_captured)
      | _ -> Error Unavailable in
    (match status, account_ref with
     | Complete _, None -> Error Unavailable
     | (Running | Complete _ | Failed | Cancelled | Interrupted), _ ->
       Ok {login_id; integration_id; account_ref; status})
  | _ -> Error Unavailable

let load ~workspace ~actor ~login_id = filesystem (fun () ->
  if not (Auth.is_generated_token_shape login_id) then Error Not_found else
  let scope = scope ~workspace ~actor in
  let* root = root ~create:false () in
  let* contents = match Fs_compat.load_owned_regular_file_with_snapshot ~ownership_root:root
      (Filename.concat root (login_id ^ ".json")) with
    | Ok None -> Error Not_found
    | Ok (Some file) when file.snapshot.owner_uid = Unix.geteuid ()
        && file.snapshot.permissions land 0o077 = 0 -> Ok file.content
    | Ok (Some _) | Error _ -> Error Unavailable in
  try match Yojson.Safe.from_string contents with
    | `Assoc fields when List.sort String.compare (List.map fst fields) = ["receipt"; "scope"] ->
      (match List.assoc "scope" fields with
       | `String value when Eqaf.equal value scope -> decode ~login_id (List.assoc "receipt" fields)
       | `String _ -> Error Not_found
       | _ -> Error Unavailable)
    | _ -> Error Unavailable
  with Yojson.Json_error _ -> Error Unavailable)
