type status = Running | Complete of Runtime_setup_login_client.observation
  | Failed | Cancelled | Interrupted
type account =
  | Unselected
  | Published of Runtime_setup_accounts.reference
  | Linked
type t = {
  login_id : string;
  integration_id : string;
  account : account;
  status : status;
}
type error = Not_found | Unavailable
open Result.Syntax

let observation_name = function
  | Runtime_setup_login_client.Authenticated -> "authenticated"
  | Login_completed -> "login_completed"
  | Credential_captured -> "credential_captured"

let linked_label = "linked"

let to_json t =
  let status, authentication = match t.status with
    | Running -> "running", []
    | Complete observed -> "complete", ["authentication", `String (observation_name observed)]
    | Failed -> "failed", []
    | Cancelled -> "cancelled", []
    | Interrupted -> "interrupted", [] in
  let account = match t.account with
    | Unselected -> []
    | Published reference -> ["account_ref", `String (Runtime_setup_accounts.reference_to_string reference)]
    | Linked -> ["account", `String linked_label] in
  `Assoc (["login_id", `String t.login_id; "integration_id", `String t.integration_id;
    "status", `String status; "invocation_verified", `Bool false] @ account @ authentication)

(* An agent's scope digests two strings, as before plan D1-4, and a person's
   three, so the JSON of one is never the JSON of the other. *)
let person_scope_label = "person"

let scope ~workspace ~actor =
  let workspace = Unix.realpath workspace in
  let actor = match (actor : Runtime_setup_login_session.actor) with
    | Agent name -> [`String name]
    | Person user_id -> [`String person_scope_label; `String user_id] in
  Auth.sha256_hash (Yojson.Safe.to_string (`List (`String workspace :: actor)))

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
        ["login_id"; "integration_id"; "status"; "invocation_verified"; "account_ref"; "account";
         "authentication"]) fields ->
    let* integration_id = match List.assoc_opt "login_id" fields, List.assoc_opt "integration_id" fields,
        List.assoc_opt "invocation_verified" fields with
      | Some (`String stored_id), Some (`String integration_id), Some (`Bool false)
        when String.equal stored_id login_id && String.trim integration_id <> "" -> Ok integration_id
      | _ -> Error Unavailable in
    let* account = match List.assoc_opt "account_ref" fields, List.assoc_opt "account" fields with
      | None, None -> Ok Unselected
      | Some (`String value), None -> Runtime_setup_accounts.reference_of_string value
          |> Result.map (fun reference -> Published reference) |> Result.map_error (fun _ -> Unavailable)
      | None, Some (`String label) when String.equal label linked_label -> Ok Linked
      | _ -> Error Unavailable in
    let* status = match List.assoc_opt "status" fields, List.assoc_opt "authentication" fields with
      | Some (`String "running"), None -> Ok Running
      | Some (`String "failed"), None -> Ok Failed
      | Some (`String "cancelled"), None -> Ok Cancelled
      | Some (`String "interrupted"), None -> Ok Interrupted
      | Some (`String "complete"), Some (`String "authenticated") -> Ok (Complete Authenticated)
      | Some (`String "complete"), Some (`String "login_completed") -> Ok (Complete Login_completed)
      | Some (`String "complete"), Some (`String "credential_captured") -> Ok (Complete Credential_captured)
      | _ -> Error Unavailable in
    (match status, account with
     | Complete _, Unselected -> Error Unavailable
     | (Running | Failed | Cancelled | Interrupted), Linked -> Error Unavailable
     | Complete _, (Published _ | Linked)
     | (Running | Failed | Cancelled | Interrupted), (Unselected | Published _) ->
       Ok {login_id; integration_id; account; status})
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
