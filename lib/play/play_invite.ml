(* Invites to the shared machine (RFC play-link-for-the-shared-machine §2.4). *)

let max_name_length = 32

module Name = struct
  type t = string

  let is_lower c = c >= 'a' && c <= 'z'
  let is_digit c = c >= '0' && c <= '9'

  let of_string raw =
    let length = String.length raw in
    if length = 0 then Error "an invite name is empty"
    else if length > max_name_length then
      Error (Printf.sprintf "an invite name is at most %d characters" max_name_length)
    else if not (is_lower raw.[0]) then
      Error "an invite name starts with a lowercase letter (a-z)"
    else if not (String.for_all (fun c -> is_lower c || is_digit c) raw) then
      Error "an invite name holds only lowercase letters and digits (a-z, 0-9)"
    else Ok raw

  let to_string name = name
end

type readiness_gap =
  | Auth_disabled
  | Token_not_required
  | No_public_base_url

let readiness_gap_to_string = function
  | Auth_disabled -> "auth_disabled"
  | Token_not_required -> "token_not_required"
  | No_public_base_url -> "no_public_base_url"

type taken_by =
  | Keeper
  | Credential

let taken_by_to_string = function
  | Keeper -> "keeper"
  | Credential -> "credential"

type issue_error =
  | Not_ready of readiness_gap list
  | Name_taken of taken_by
  | Keeper_names_unreadable of string
  | Hours_out_of_range of int
  | Credential_not_saved of Masc_domain.masc_error

type issued =
  { name : Name.t
  ; expires_at : string
  ; link : string
  }

let play_path = "/play"
let agent_guide_path = play_path ^ "/agent.md"

(* Every gap at once, so the operator fixes the setup in one pass. *)
let readiness ~(auth_config : Masc_domain.auth_config) ~public_base_url =
  let auth_gaps =
    List.filter_map
      (fun (gap, missing) -> if missing then Some gap else None)
      [ Auth_disabled, not auth_config.enabled
      ; Token_not_required, not auth_config.require_token
      ]
  in
  match auth_gaps, public_base_url with
  | [], Some base -> Ok base
  | gaps, None -> Error (gaps @ [ No_public_base_url ])
  | (_ :: _ as gaps), Some _ -> Error gaps

(* A keeper's credential lives at its name through [Common.safe_filename],
   which lowercases, and keeper names may hold capitals. "Minsu" and "minsu"
   share agents/minsu.json, so the keeper booting later would overwrite the
   invite's credential. Compared as file names, not as strings. *)
let is_keeper_name ~keepers name =
  List.exists (fun keeper -> String.equal (Common.safe_filename keeper) name) keepers

let issue ~base_path ~public_base_url ~keeper_names ~name ~hours =
  let ( let* ) = Result.bind in
  let* base =
    readiness ~auth_config:(Auth.load_auth_config base_path) ~public_base_url
    |> Result.map_error (fun gaps -> Not_ready gaps)
  in
  let* () =
    if hours >= Masc_domain.min_token_expiry_hours && hours <= Masc_domain.max_token_expiry_hours
    then Ok ()
    else Error (Hours_out_of_range hours)
  in
  let* keepers = Result.map_error (fun detail -> Keeper_names_unreadable detail) keeper_names in
  let* () =
    if is_keeper_name ~keepers name then Error (Name_taken Keeper)
    else Ok ()
  in
  match Auth.create_token_expiring_in_if_absent base_path ~agent_name:name ~role:Masc_domain.Player ~hours with
  | Error Auth.Credential_name_taken -> Error (Name_taken Credential)
  | Error (Auth.Credential_not_created err) -> Error (Credential_not_saved err)
  | Ok (_, { Masc_domain.expires_at = None; _ }) ->
    (* The record type allows no expiry, though [create_token_expiring_in_if_absent]
       always sets one. An invite that never ends is not handed out. *)
    Error
      (Credential_not_saved
         (Masc_domain.System
            (Masc_domain.System_error.IoError "the invite credential was saved without an expiry")))
  | Ok (raw_token, { Masc_domain.expires_at = Some expires_at; _ }) ->
    Ok { name; expires_at; link = base ^ play_path ^ "#" ^ raw_token }

type invite =
  { invite_name : string
  ; expires_at : string option
  ; expired : bool
  }

let expired ~now (cred : Masc_domain.agent_credential) =
  match cred.expires_at with
  | Some expires_at -> String.compare (Masc_domain.iso8601_of_unix_seconds now) expires_at > 0
  | None -> false

let list ~base_path ~now =
  Auth.list_credentials base_path
  |> List.filter_map (fun (cred : Masc_domain.agent_credential) ->
    match cred.role with
    | Masc_domain.Player ->
      Some { invite_name = cred.agent_name; expires_at = cred.expires_at; expired = expired ~now cred }
    | Masc_domain.Worker | Masc_domain.Admin -> None)
  |> List.sort (fun a b -> String.compare a.invite_name b.invite_name)

type revoked =
  | Deleted
  | Already_gone

type revoke_error =
  | Not_an_invite of Masc_domain.agent_role
  | Credential_not_deleted of Masc_domain.masc_error
  | Credential_unreadable
  | Credential_identity_mismatch of string

let revoke ~base_path ~name ~after_revoke =
  Auth.with_credential_transaction base_path (fun transaction ->
    match Auth.credential_exists_in_transaction transaction name with
    | Error error -> Error (Credential_not_deleted error)
    | Ok false -> Ok (after_revoke Already_gone)
    | Ok true ->
      let credential =
        try Auth.load_credential base_path name with
        | Sys_error _ | Unix.Unix_error _ | Eio.Io _ -> None
      in
      (match credential with
       | None -> Error Credential_unreadable
       | Some { Masc_domain.agent_name; _ } when not (String.equal agent_name name) ->
         Error (Credential_identity_mismatch agent_name)
       | Some { Masc_domain.role = Masc_domain.Player; _ } ->
         Auth.delete_credential_in_transaction transaction name
         |> Result.map_error (fun error -> Credential_not_deleted error)
         |> Result.map (fun () -> after_revoke Deleted)
       | Some { Masc_domain.role = (Masc_domain.Worker | Masc_domain.Admin) as role; _ } ->
         Error (Not_an_invite role)))
  |> Result.map_error (fun error -> Credential_not_deleted error)
  |> Result.join
