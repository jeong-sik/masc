(* HIGH-RISK-UNREVIEWED: see the interface. *)

module K = Authz_record.Kind
module R = Authz_record

type t =
  { mode : Authz_mode_state.t
  ; invites : Authz_invite_state.t
  }

let empty = { mode = Authz_mode_state.empty; invites = Authz_invite_state.empty }

type refusal =
  | Before_bootstrap of K.t
  | Mode_event_unreadable of Authz_mode_event.error
  | Mode of Authz_mode_state.refusal
  | Invite_unreadable of Authz_invite_event.error
  | Invite of Authz_invite_state.refusal
  | Accounts_off of K.t
  | Kind_not_read of K.t

let refusal_to_string = function
  | Before_bootstrap kind ->
    Printf.sprintf "a %s record comes before the bootstrap of the log" (K.to_string kind)
  | Mode_event_unreadable error ->
    "the mode event cannot be read: " ^ Authz_mode_event.error_to_string error
  | Mode refusal -> Authz_mode_state.refusal_to_string refusal
  | Invite_unreadable error ->
    "the invite record cannot be read: " ^ Authz_invite_event.error_to_string error
  | Invite refusal -> Authz_invite_state.refusal_to_string refusal
  | Accounts_off kind ->
    Printf.sprintf "the accounts are off, and no %s record is written while they are" (K.to_string kind)
  | Kind_not_read kind -> Printf.sprintf "no layer of this server reads %s records" (K.to_string kind)
;;

type applied =
  { state : t
  ; high_water : Authz_external_store.Change.t option
  }

(* A mode event is an intent of the external store (design 8.2). *)
let mode_event state (record : R.t) =
  match Authz_mode_event.of_body record.R.body with
  | Error error -> Error (Mode_event_unreadable error)
  | Ok ({ Authz_mode_event.event; workspace_id } as mode_event) ->
    (match Authz_mode_state.apply state.mode mode_event with
     | Ok mode ->
       Ok
         { state = { state with mode }
         ; high_water = Some (Authz_external_store.Change.Mode { event; workspace_id })
         }
     | Error refusal -> Error (Mode refusal))
;;

(* An invitation raises no scoped epoch (design 8.1), so the external store
   takes no intent for its issue. Its revocation closes what the token opens
   (design 5.1-4), so it is a [Revoke] intent: a log restored from before it
   then disagrees with the store, and the invitation does not come back open. *)
let invite state (record : R.t) =
  match Authz_invite_event.of_body record.R.body with
  | Error error -> Error (Invite_unreadable error)
  | Ok event ->
    (match Authz_invite_state.apply state.invites ~author:record.R.author event with
     | Ok invites ->
       let high_water =
         match event with
         | Authz_invite_event.Issued _ -> None
         | Authz_invite_event.Revoked { invite_id } ->
           Some
             (Authz_external_store.Change.Authz
                { event = Authz_external_store.Change.Revoke
                ; subject = Authz_records.Subject.Invite invite_id
                })
       in
       Ok { state = { state with invites }; high_water }
     | Error refusal -> Error (Invite refusal))
;;

(* Every kind but a mode event is matched with the mode, so the branch of a
   kind says what a record of it means before the bootstrap, and a layer gets
   the workspace of the bootstrap only from a branch that has one. *)
let apply state (record : R.t) =
  match record.R.kind, state.mode with
  | K.Mode_event, (Authz_mode_state.Not_bootstrapped | Multi_account _ | Off _) ->
    mode_event state record
  | K.Invite, Authz_mode_state.Multi_account _ -> invite state record
  | K.Invite, Authz_mode_state.Off _ -> Error (Accounts_off K.Invite)
  | ( ( K.Runtime_grant
      | K.Delegate_policy
      | K.Principal
      | K.Internal_service_credential
      | K.Permission_revocation
      | K.Trigger_evidence
      | K.Lease_terminal_evidence
      | K.Preauthorized_expiry
      | K.Migration_diagnostic
      | K.Local_recovery
      | K.Invite
      | K.Admission ) as kind )
    , Authz_mode_state.Not_bootstrapped -> Error (Before_bootstrap kind)
  | ( ( K.Runtime_grant
      | K.Delegate_policy
      | K.Principal
      | K.Internal_service_credential
      | K.Permission_revocation
      | K.Trigger_evidence
      | K.Lease_terminal_evidence
      | K.Preauthorized_expiry
      | K.Migration_diagnostic
      | K.Local_recovery
      | K.Admission ) as kind )
    , (Authz_mode_state.Multi_account _ | Off _) -> Error (Kind_not_read kind)
;;

let step state record =
  match apply state record with
  | Ok { state; high_water = _ } -> Ok state
  | Error refusal -> Error refusal
;;
