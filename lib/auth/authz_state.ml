(* HIGH-RISK-UNREVIEWED: see the interface. *)

module K = Authz_record.Kind
module R = Authz_record

type t =
  { mode : Authz_mode_state.t
  ; invites : Authz_invite_state.t
  ; principals : Authz_principal_state.t
  ; revocation_pending : Authz_records.Subject.t list
  }

let empty =
  { mode = Authz_mode_state.empty
  ; invites = Authz_invite_state.empty
  ; principals = Authz_principal_state.empty
  ; revocation_pending = []
  }

let is_pending state subject = List.exists (Authz_records.Subject.equal subject) state.revocation_pending

let hold_revocations state subjects =
  let revocation_pending =
    List.fold_left
      (fun held subject -> if List.exists (Authz_records.Subject.equal subject) held then held else subject :: held)
      state.revocation_pending
      subjects
  in
  { state with revocation_pending }
;;

type refusal =
  | Before_bootstrap of K.t
  | Mode_event_unreadable of Authz_mode_event.error
  | Mode of Authz_mode_state.refusal
  | Invite_unreadable of Authz_invite_event.error
  | Invite of Authz_invite_state.refusal
  | Admission_unreadable of Authz_admission_event.error
  | Admission of Authz_principal_state.refusal
  | Revocation_pending of Authz_records.Subject.t
  | Admin_assignment_unreadable of Authz_admin_event.error
  | Admin_assignment of Authz_principal_state.revocation_refusal
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
  | Admission_unreadable error ->
    "the admission cannot be read: " ^ Authz_admission_event.error_to_string error
  | Admission refusal -> Authz_principal_state.refusal_to_string refusal
  | Revocation_pending subject ->
    Printf.sprintf
      "a revocation of %s was given up before it reached the log, so %s stays blocked"
      (Authz_records.Subject.to_string subject)
      (Authz_records.Subject.to_string subject)
  | Admin_assignment_unreadable error ->
    "the Admin assignment record cannot be read: " ^ Authz_admin_event.error_to_string error
  | Admin_assignment refusal -> Authz_principal_state.revocation_refusal_to_string refusal
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
    (match
       Authz_invite_state.apply
         state.invites
         ~author:record.R.author
         ~is_admin:(Authz_principal_state.is_admin state.principals)
         event
     with
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

(* An admission spends a token that opens once (design 5.1-3) and makes a
   principal; an Admin invitation also makes an Admin assignment, which raises
   the role epoch of that principal (design 8.1). A log restored from before the
   admission would open the token again, so every admission is a [Grant] on the
   principal it makes, and the restored log disagrees with the store. *)
let admission state (record : R.t) =
  match Authz_admission_event.of_body record.R.body with
  | Error error -> Error (Admission_unreadable error)
  | Ok event when is_pending state (Authz_records.Subject.Invite event.Authz_admission_event.invite_id) ->
    Error (Revocation_pending (Authz_records.Subject.Invite event.Authz_admission_event.invite_id))
  | Ok event ->
    (match
       Authz_principal_state.admit
         state.principals
         ~invites:state.invites
         ~author:record.R.author
         ~at_ms:record.R.at_ms
         event
     with
     | Error refusal -> Error (Admission refusal)
     | Ok { Authz_principal_state.principals; invites; role = _ } ->
       Ok
         { state = { state with principals; invites }
         ; high_water =
             Some
               (Authz_external_store.Change.Authz
                  { event = Authz_external_store.Change.Grant
                  ; subject =
                      Authz_records.Subject.Principal
                        (Authz_types.Principal.Human event.Authz_admission_event.user_id)
                  })
         })
;;

(* An Admin assignment that ends lowers the role epoch of its principal
   (design 8.1), so the store takes a [Revoke] on that principal. *)
let admin_assignment state (record : R.t) =
  match Authz_admin_event.of_body record.R.body with
  | Error error -> Error (Admin_assignment_unreadable error)
  | Ok (Authz_admin_event.Revoked { user_id; cause = _ } as event) ->
    (match Authz_principal_state.revoke_admin state.principals ~author:record.R.author event with
     | Error refusal -> Error (Admin_assignment refusal)
     | Ok principals ->
       Ok
         { state = { state with principals }
         ; high_water =
             Some
               (Authz_external_store.Change.Authz
                  { event = Authz_external_store.Change.Revoke
                  ; subject = Authz_records.Subject.Principal (Authz_types.Principal.Human user_id)
                  })
         })
;;

(* Every kind but a mode event is matched with the mode, so the branch of a
   kind says what a record of it means before the bootstrap, and a layer gets
   the workspace of the bootstrap only from a branch that has one. *)
let read state (record : R.t) =
  match record.R.kind, state.mode with
  | K.Mode_event, (Authz_mode_state.Not_bootstrapped | Multi_account _ | Off _) ->
    mode_event state record
  | K.Invite, Authz_mode_state.Multi_account _ -> invite state record
  | K.Invite, Authz_mode_state.Off _ -> Error (Accounts_off K.Invite)
  | K.Admission, Authz_mode_state.Multi_account _ -> admission state record
  | K.Admission, Authz_mode_state.Off _ -> Error (Accounts_off K.Admission)
  | K.Admin_assignment, Authz_mode_state.Multi_account _ -> admin_assignment state record
  | K.Admin_assignment, Authz_mode_state.Off _ -> Error (Accounts_off K.Admin_assignment)
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
      | K.Admission
      | K.Admin_assignment ) as kind )
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
      | K.Local_recovery ) as kind )
    , (Authz_mode_state.Multi_account _ | Off _) -> Error (Kind_not_read kind)
;;

(* A principal whose revocation the store gave up writes nothing (design 8.3):
   an Admin whose assignment was being revoked neither invites nor revokes
   another Admin while the block stands. *)
let blocked_author state (author : Authz_records.Author.t) =
  match author with
  | Authz_records.Author.Authenticated principal ->
    let subject = Authz_records.Subject.Principal principal in
    if is_pending state subject then Some subject else None
  | Authz_records.Author.Local_operator
  | Authz_records.Author.System_cron
  | Authz_records.Author.System_maintenance
  | Authz_records.Author.System_migration -> None
;;

let apply state (record : R.t) =
  match blocked_author state record.R.author with
  | Some subject -> Error (Revocation_pending subject)
  | None -> read state record
;;

let step state record =
  match apply state record with
  | Ok { state; high_water = _ } -> Ok state
  | Error refusal -> Error refusal
;;
