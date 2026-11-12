(* HIGH-RISK-UNREVIEWED: see the interface. *)

module B = Authz_boot_mode
module E = Authz_invite_event
module I = Authz_install_record
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
  | Turned_off
  | Boot_stops of string * string list
  | Workspace_id_not_built of Authz_id.error
  | Bootstrap_failed of Authz_bootstrap.error
  | Invitation_not_written of invitation_error

let invitation_error_to_string = function
  | Invite_id_not_built error -> "the invite id was refused: " ^ Authz_id.error_to_string error
  | Body_not_built error -> "the invitation was refused: " ^ Authz_body.error_to_string error
  | Zone_not_opened error -> "the zone was not opened: " ^ Z.open_error_to_string error
  | Commit_failed error -> Z.error_detail error
;;

(* Design 10.5: after Off, a boot starts a single user that keeps the records of
   the accounts read-only, and reactivation needs the recovery procedure. *)
let turned_off_text =
  "the accounts of this installation were turned off, so a boot starts a single user that \
   keeps their records read-only; turning them on again is not in this build"
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
     installation is already activated, and masc auth invite writes one more Admin invitation"
  | Turned_off -> turned_off_text
  | Boot_stops (first, rest) ->
    "a boot stops on this installation, and an activation would not change that: "
    ^ String.concat "; " (first :: rest)
  | Workspace_id_not_built error -> "the workspace id was refused: " ^ Authz_id.error_to_string error
  | Bootstrap_failed error -> "the bootstrap failed: " ^ Authz_bootstrap.error_to_string error
  | Invitation_not_written error ->
    "the installation is bootstrapped and holds no Admin invitation; masc auth invite writes \
     one while no server runs: "
    ^ invitation_error_to_string error
;;

(* Design 5.1: the one row where a boot opens the host-local bootstrap. *)
let asked ~base_path ~config_dir ~anonymous_mutations =
  let input = M.input ~base_path ~config_dir ~anonymous_mutations in
  match M.decide input with
  | M.Stop M.Activation_requested -> Ok ()
  | M.Boot_after_off (_ : Authz_state.t) -> Error Turned_off
  | M.Boot_single_user ->
    (match input.B.settings with
     | B.Settings_read _ -> Error Not_asked
     | B.Settings_unreadable detail -> Error (Config_unreadable detail))
  | M.Boot_multi_account -> Error Already_active
  | M.Stop ((M.Refuse _ | M.Authorization_uncertain) as stop) ->
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

type invite_error =
  | Not_activated
  | Accounts_turned_off
  | Not_served_as_active of string * string list
  | Store_not_located of string
  | Invite_not_written of invitation_error

let invite_error_to_string = function
  | Not_activated ->
    "no installation is active for multi-account use here: activate it with masc auth bootstrap"
  | Accounts_turned_off -> turned_off_text
  | Not_served_as_active (first, rest) ->
    "a boot stops on this installation, and not on an active one: " ^ String.concat "; " (first :: rest)
  | Store_not_located detail -> "the external store is not located: " ^ detail
  | Invite_not_written error -> "the Admin invitation was not written: " ^ invitation_error_to_string error
;;

(* Design 5.1: an installation that a boot finds in Multi_account, with an
   external store that matches the log. *)
let active ~base_path ~config_dir ~anonymous_mutations =
  let input = M.input ~base_path ~config_dir ~anonymous_mutations in
  match M.decide input with
  | M.Boot_multi_account -> Ok ()
  | M.Boot_single_user | M.Stop M.Activation_requested -> Error Not_activated
  | M.Boot_after_off (_ : Authz_state.t) -> Error Accounts_turned_off
  | M.Stop ((M.Refuse _ | M.Authorization_uncertain) as stop) ->
    let first, rest = M.messages input stop in
    Error (Not_served_as_active (first, rest))
;;

let located_store ~config_dir ~base_path =
  match I.locate ~config_dir ~base_path with
  | Error error -> Error (Store_not_located (I.locate_error_to_string error))
  | Ok located ->
    (match I.read located with
     | Error error -> Error (Store_not_located (I.read_error_to_string error))
     | Ok None -> Error (Store_not_located "the install record names no external store")
     | Ok (Some store) -> Ok (store : I.Store_path.t :> string))
;;

let active_store ~base_path ~config_dir ~anonymous_mutations =
  let* () = active ~base_path ~config_dir ~anonymous_mutations in
  located_store ~config_dir ~base_path
;;

let invite ~base_path ~config_dir ~anonymous_mutations ~now_ms =
  let* external_store = active_store ~base_path ~config_dir ~anonymous_mutations in
  Result.map_error
    (fun error -> Invite_not_written error)
    (write_invitation ~base_path ~external_store ~now_ms)
;;
