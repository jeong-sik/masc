(* HIGH-RISK-UNREVIEWED: see the interface. *)

module B = Authz_boot_mode
module E = Authz_invite_event
module M = Authz_boot_mode_read
module Z = Authz_zone

let ( let* ) = Result.bind
let admin_invitation_lifetime_ms = 24 * 60 * 60 * 1000

(* 128 bits, as design 4.1 asks of a user id. *)
let id_bytes = 16
let token_bytes = 32

type invitation =
  { invite_id : Authz_types.Invite_id.t
  ; token : string
  ; expires_at_ms : int
  }

let invite_id invitation = invitation.invite_id
let expires_at_ms invitation = invitation.expires_at_ms
let invitation_path = "/accounts/invite"
let link ~base_url invitation = base_url ^ invitation_path ^ "#" ^ invitation.token

type activated =
  { workspace_id : Authz_types.Workspace_id.t
  ; invitation : invitation
  }

type invitation_error =
  | Invite_id_not_built of Authz_id.error
  | Body_not_built of Authz_body.error
  | Zone_not_opened of Z.open_error
  | Commit_failed of Z.error

type error =
  | Not_asked
  | Config_unreadable of string
  | Already_active
  | Boot_stops of string * string list
  | Workspace_id_not_built of Authz_id.error
  | Bootstrap_failed of Authz_bootstrap.error
  | Invitation_not_written of invitation_error

let id_error_to_string = function
  | Authz_id.Empty -> "it is empty"
  | Authz_id.Too_long -> "it is too long"
  | Authz_id.Invalid_byte { index } -> Printf.sprintf "byte %d is outside its alphabet" index
  | Authz_id.Path_segment -> "it is a path segment"
;;

let invitation_error_to_string = function
  | Invite_id_not_built error -> "the invite id was refused: " ^ id_error_to_string error
  | Body_not_built error -> "the invitation was refused: " ^ Authz_body.error_to_string error
  | Zone_not_opened error -> "the zone was not opened: " ^ Z.open_error_to_string error
  | Commit_failed error -> Z.error_to_string error
;;

let error_to_string = function
  | Not_asked ->
    "config.json does not ask for Multi_account, so a boot starts a single user and there is \
     nothing to activate"
  | Config_unreadable detail ->
    "config.json cannot be read in full, so a boot starts a single user and there is nothing \
     to activate: "
    ^ detail
  | Already_active ->
    "the authorization log made Multi_account and the external store matches it: this \
     installation is already activated"
  | Boot_stops (first, rest) ->
    "a boot stops on this installation, and an activation would not change that: "
    ^ String.concat "; " (first :: rest)
  | Workspace_id_not_built error -> "the workspace id was refused: " ^ id_error_to_string error
  | Bootstrap_failed error -> "the bootstrap failed: " ^ Authz_bootstrap.error_to_string error
  | Invitation_not_written error ->
    "the installation is bootstrapped and holds no Admin invitation: "
    ^ invitation_error_to_string error
;;

(* Design 5.1: the one row where a boot opens the host-local bootstrap. *)
let asked ~base_path ~config_dir ~anonymous_mutations =
  let input = M.input ~base_path ~config_dir ~anonymous_mutations in
  match M.decide input with
  | M.Stop M.Multi_account_not_activatable -> Ok ()
  | M.Boot_single_user ->
    (match input.B.settings with
     | B.Settings_read _ -> Error Not_asked
     | B.Settings_unreadable detail -> Error (Config_unreadable detail))
  | M.Stop (M.Multi_account_not_served B.Multi_account) -> Error Already_active
  | M.Stop
      ((M.Refuse _
       | M.Multi_account_not_served
           (B.Single_user | B.Activation_requested | B.Multi_account_uncertain)) as stop) ->
    let first, rest = M.messages input stop in
    Error (Boot_stops (first, rest))
;;

let write_invitation ~base_path ~external_store ~now_ms =
  let* invite_id =
    Result.map_error
      (fun error -> Invite_id_not_built error)
      (Authz_types.Invite_id.of_string (Random_id.hex ~bytes:id_bytes))
  in
  let token = Random_id.hex ~bytes:token_bytes in
  let expires_at_ms = now_ms () + admin_invitation_lifetime_ms in
  let* body =
    Result.map_error
      (fun error -> Body_not_built error)
      (E.to_body
         (E.Issued
            { invite_id; token_digest = E.Token_digest.of_token token; expires_at_ms; role = E.Admin }))
  in
  let* zone =
    Result.map_error
      (fun error -> Zone_not_opened error)
      (Z.open_at_start
         ~now_ms
         ~log_path:(Authz_log.path_of_base_path ~base_path)
         ~store_path:external_store)
  in
  let* (_ : Z.committed) =
    Result.map_error
      (fun error -> Commit_failed error)
      (Z.commit
         zone
         { Z.author = Authz_records.Author.Local_operator; kind = Authz_record.Kind.Invite; body })
  in
  Ok { invite_id; token; expires_at_ms }
;;

let activate ~base_path ~config_dir ~external_store ~anonymous_mutations ~now_ms =
  let* () = asked ~base_path ~config_dir ~anonymous_mutations in
  let* workspace_id =
    Result.map_error
      (fun error -> Workspace_id_not_built error)
      (Authz_types.Workspace_id.of_string (Random_id.hex ~bytes:id_bytes))
  in
  let* (_ : Authz_bootstrap.completed) =
    Result.map_error
      (fun error -> Bootstrap_failed error)
      (Authz_bootstrap.fresh_bootstrap
         { Authz_bootstrap.base_path; config_dir; external_store; workspace_id; now_ms })
  in
  let* invitation =
    Result.map_error
      (fun error -> Invitation_not_written error)
      (write_invitation ~base_path ~external_store ~now_ms)
  in
  Ok { workspace_id; invitation }
;;
