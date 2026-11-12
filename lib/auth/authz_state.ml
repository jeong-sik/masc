(* HIGH-RISK-UNREVIEWED: see the interface. *)

module C = Authz_external_store.Change
module K = Authz_record.Kind
module R = Authz_record

type held =
  { aborted : R.Hash.t
  ; event : C.authz_event
  ; subject : Authz_records.Subject.t
  }

let held_of_intent (intent : Authz_external_store.intent) =
  match intent.Authz_external_store.change with
  | C.Authz { event; subject } when C.is_reduction intent.Authz_external_store.change ->
    Some { aborted = intent.Authz_external_store.intended_next_record_digest; event; subject }
  | C.Authz _ | C.Mode _ -> None
;;

type t =
  { mode : Authz_mode_state.t
  ; invites : Authz_invite_state.t
  ; principals : Authz_principal_state.t
  ; registrations : Authz_registration_state.t
  ; sessions : Authz_session_state.t
  ; pats : Authz_pat_state.t
  ; service_credentials : Authz_service_credential_state.t
  ; provider_accounts : Authz_provider_account_state.t
  ; runtimes : Authz_runtime_state.t
  ; keepers : Authz_keeper_state.t
  ; purges : Authz_purge_state.t
  ; revocation_pending : held list
  ; latest_at_ms : int option
  }

let empty =
  { mode = Authz_mode_state.empty
  ; invites = Authz_invite_state.empty
  ; principals = Authz_principal_state.empty
  ; registrations = Authz_registration_state.empty
  ; sessions = Authz_session_state.empty
  ; pats = Authz_pat_state.empty
  ; service_credentials = Authz_service_credential_state.empty
  ; provider_accounts = Authz_provider_account_state.empty
  ; runtimes = Authz_runtime_state.empty
  ; keepers = Authz_keeper_state.empty
  ; purges = Authz_purge_state.empty
  ; revocation_pending = []
  ; latest_at_ms = None
  }

let is_pending state subject =
  List.exists (fun held -> Authz_records.Subject.equal subject held.subject) state.revocation_pending
;;

let revocation state subject =
  if is_pending state subject
  then Authz_records.Revocation_state.Pending
  else Authz_records.Revocation_state.Not_pending
;;

let hold_revocations state helds =
  let revocation_pending =
    List.fold_left
      (fun pending held ->
        if List.exists (fun other -> R.Hash.equal other.aborted held.aborted) pending
        then pending
        else held :: pending)
      state.revocation_pending
      helds
  in
  { state with revocation_pending }
;;

let closable state change =
  if C.is_reduction change
  then
    List.filter_map
      (fun held ->
        if C.equal (C.Authz { event = held.event; subject = held.subject }) change
        then Some held.aborted
        else None)
      state.revocation_pending
  else []
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
  | Principal_unreadable of Authz_principal_event.error
  | Principal_event of Authz_principal_state.principal_refusal
  | Author_inactive of Authz_types.User_id.t
  | Accounts_off of K.t
  | Kind_not_read of K.t
  | Admission_behind_log of
      { at_ms : int
      ; latest_at_ms : int
      }
  | Closes_without_reduction
  | Closes_not_held of R.Hash.t
  | Cancel_unreadable of Authz_cancel_event.error
  | Canceller_is_not_an_admin of Authz_records.Author.t
  | Cancel_not_held of R.Hash.t
  | Cancel_subject_differs of
      { aborted : R.Hash.t
      ; named : Authz_records.Subject.t
      ; held : Authz_records.Subject.t
      }
  | Canceller_owns_the_subject of Authz_records.Subject.t
  | Cancel_owner_unknown of Authz_records.Subject.t
  | Registration_unreadable of Authz_registration_event.error
  | Registration of Authz_registration_state.refusal
  | Session_unreadable of Authz_session_event.error
  | Session of Authz_session_state.refusal
  | Pat_unreadable of Authz_pat_event.error
  | Pat of Authz_pat_state.refusal
  | Service_credential_unreadable of Authz_service_credential_event.error
  | Service_credential of Authz_service_credential_state.refusal
  | Provider_account_unreadable of Authz_provider_account_event.error
  | Provider_account of Authz_provider_account_state.refusal
  | Runtime_unreadable of Authz_runtime_event.error
  | Runtime of Authz_runtime_state.refusal
  | Keeper_unreadable of Authz_keeper_event.error
  | Keeper of Authz_keeper_state.refusal
  | Purge_unreadable of Authz_purge_event.error
  | Purge of Authz_purge_state.refusal

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
  | Principal_unreadable error ->
    "the principal record cannot be read: " ^ Authz_principal_event.error_to_string error
  | Principal_event refusal -> Authz_principal_state.principal_refusal_to_string refusal
  | Author_inactive user_id ->
    Printf.sprintf
      "the principal %s is disabled or deleted, and writes nothing"
      (Authz_types.User_id.to_string user_id)
  | Accounts_off kind ->
    Printf.sprintf "the accounts are off, and no %s record is written while they are" (K.to_string kind)
  | Kind_not_read kind -> Printf.sprintf "no layer of this build reads %s records" (K.to_string kind)
  | Admission_behind_log { at_ms; latest_at_ms } ->
    Printf.sprintf
      "the admission is at %d ms, before a record of the log at %d ms: the clock went back"
      at_ms
      latest_at_ms
  | Closes_without_reduction -> "the record closes given-up reductions but reduces nothing"
  | Closes_not_held aborted ->
    Printf.sprintf
      "the record closes %s, which is not a given-up reduction of the change it makes"
      (R.Hash.to_hex aborted)
  | Cancel_unreadable error ->
    "the revocation cancel cannot be read: " ^ Authz_cancel_event.error_to_string error
  | Canceller_is_not_an_admin (_ : Authz_records.Author.t) ->
    "only an active Admin cancels a block, and the author of this cancel is not one"
  | Cancel_not_held aborted ->
    Printf.sprintf "no given-up reduction %s is blocked" (R.Hash.to_hex aborted)
  | Cancel_subject_differs { aborted; named; held } ->
    Printf.sprintf
      "the given-up reduction %s is of %s, and the cancel names %s"
      (R.Hash.to_hex aborted)
      (Authz_records.Subject.to_string held)
      (Authz_records.Subject.to_string named)
  | Canceller_owns_the_subject subject ->
    Printf.sprintf
      "the canceller issued the invitation or wrote the registration behind %s, so another \
       Admin cancels its block"
      (Authz_records.Subject.to_string subject)
  | Cancel_owner_unknown subject ->
    Printf.sprintf
      "no invitation or registration stands behind %s, so no Admin is known to be eligible \
       to cancel its block"
      (Authz_records.Subject.to_string subject)
  | Registration_unreadable error ->
    "the registration record cannot be read: " ^ Authz_registration_event.error_to_string error
  | Registration refusal -> Authz_registration_state.refusal_to_string refusal
  | Session_unreadable error ->
    "the session record cannot be read: " ^ Authz_session_event.error_to_string error
  | Session refusal -> Authz_session_state.refusal_to_string refusal
  | Pat_unreadable error -> "the PAT record cannot be read: " ^ Authz_pat_event.error_to_string error
  | Pat refusal -> Authz_pat_state.refusal_to_string refusal
  | Service_credential_unreadable error ->
    "the Service credential record cannot be read: "
    ^ Authz_service_credential_event.error_to_string error
  | Service_credential refusal -> Authz_service_credential_state.refusal_to_string refusal
  | Provider_account_unreadable error ->
    "the provider account record cannot be read: "
    ^ Authz_provider_account_event.error_to_string error
  | Provider_account refusal -> Authz_provider_account_state.refusal_to_string refusal
  | Runtime_unreadable error ->
    "the Runtime record cannot be read: " ^ Authz_runtime_event.error_to_string error
  | Runtime refusal -> Authz_runtime_state.refusal_to_string refusal
  | Keeper_unreadable error ->
    "the Keeper record cannot be read: " ^ Authz_keeper_event.error_to_string error
  | Keeper refusal -> Authz_keeper_state.refusal_to_string refusal
  | Purge_unreadable error ->
    "the purge record cannot be read: " ^ Authz_purge_event.error_to_string error
  | Purge refusal -> Authz_purge_state.refusal_to_string refusal
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

(* A registration raises no scoped epoch, so the external store takes no intent
   for it: a log restored from before it loses the entry, which is the side that
   keeps the identity out. Its removal closes what the entry opens, so it is a
   [Revoke] intent, as the revocation of an invitation is (plan C2d): a log
   restored from before it then disagrees with the store, and the entry does not
   come back open. *)
let registration state (record : R.t) =
  match Authz_registration_event.of_body record.R.body with
  | Error error -> Error (Registration_unreadable error)
  | Ok event ->
    (match
       Authz_registration_state.apply
         state.registrations
         ~author:record.R.author
         ~is_admin:(Authz_principal_state.is_admin state.principals)
         ~is_bound:(fun identity ->
           Option.is_some (Authz_principal_state.find_identity state.principals identity))
         event
     with
     | Ok registrations ->
       let high_water =
         match event with
         | Authz_registration_event.Registered _ -> None
         | Authz_registration_event.Removed { registration_id } ->
           Some
             (Authz_external_store.Change.Authz
                { event = Authz_external_store.Change.Revoke
                ; subject = Authz_records.Subject.Registration registration_id
                })
       in
       Ok { state = { state with registrations }; high_water }
     | Error refusal -> Error (Registration refusal))
;;

(* The latest time of the log, when [record] comes before it. An admission is
   judged against the expiry of its invitation with its own time, so a time
   before a record already read would let a clock set back spend an invitation
   that the log shows had expired. *)
let latest_after state (record : R.t) =
  match state.latest_at_ms with
  | Some latest_at_ms when record.R.at_ms < latest_at_ms -> Some latest_at_ms
  | Some (_ : int) | None -> None
;;

(* The subject whose given-up revocation keeps an admission out: the invitation
   or the registration it spends (design 4.5). *)
let subject_of_through = function
  | Authz_admission_event.Invite invite_id -> Authz_records.Subject.Invite invite_id
  | Authz_admission_event.Registration registration_id ->
    Authz_records.Subject.Registration registration_id
;;

(* An admission spends a token or an allowlist entry that opens once (design
   5.1-3) and makes a principal; an Admin invitation also makes an Admin
   assignment, which raises the role epoch of that principal (design 8.1). A log
   restored from before the admission would open what it spent again, so every
   admission is a [Grant] on the principal it makes, and the restored log
   disagrees with the store. *)
let admission state ~workspace_id (record : R.t) =
  match Authz_admission_event.of_body record.R.body, latest_after state record with
  | Error error, (_ : int option) -> Error (Admission_unreadable error)
  | Ok (_ : Authz_admission_event.t), Some latest_at_ms ->
    Error (Admission_behind_log { at_ms = record.R.at_ms; latest_at_ms })
  | Ok event, None
    when is_pending state (subject_of_through event.Authz_admission_event.through) ->
    Error (Revocation_pending (subject_of_through event.Authz_admission_event.through))
  | Ok event, None ->
    (match
       Authz_principal_state.admit
         state.principals
         ~invites:state.invites
         ~registrations:state.registrations
         ~workspace_id
         ~author:record.R.author
         ~at_ms:record.R.at_ms
         event
     with
     | Error refusal -> Error (Admission refusal)
     | Ok { Authz_principal_state.principals; invites; registrations; role = _ } ->
       Ok
         { state = { state with principals; invites; registrations }
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

(* A human whose revocation the store gave up (design 8.3). *)
let held state user_id =
  is_pending state (Authz_records.Subject.Principal (Authz_types.Principal.Human user_id))
;;

(* An Admin assignment that ends lowers the role epoch of its principal
   (design 8.1), so the store takes a [Revoke] on that principal. *)
let admin_assignment state (record : R.t) =
  match Authz_admin_event.of_body record.R.body with
  | Error error -> Error (Admin_assignment_unreadable error)
  | Ok (Authz_admin_event.Revoked { user_id; cause = _ } as event) ->
    (match
       Authz_principal_state.revoke_admin state.principals ~author:record.R.author ~held:(held state) event
     with
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

(* A disable and a deletion end what the principal may do, so each is an intent
   on the principal (design 8.1, principal_epoch). An enable gives back what a
   disable took, raises no epoch, and has none: a log restored from before it
   leaves the principal disabled. *)
let principal_event state (record : R.t) =
  match Authz_principal_event.of_body record.R.body with
  | Error error -> Error (Principal_unreadable error)
  | Ok event ->
    (match
       Authz_principal_state.apply_event state.principals ~author:record.R.author ~held:(held state) event
     with
     | Error refusal -> Error (Principal_event refusal)
     | Ok principals ->
       let subject =
         Authz_records.Subject.Principal
           (Authz_types.Principal.Human (Authz_principal_event.user_id event))
       in
       let change authz_event = Some (Authz_external_store.Change.Authz { event = authz_event; subject }) in
       let high_water =
         match event with
         | Authz_principal_event.Disabled _ -> change Authz_external_store.Change.Disable
         | Authz_principal_event.Deleted _ -> change Authz_external_store.Change.Delete
         | Authz_principal_event.Enabled _ -> None
       in
       Ok { state = { state with principals }; high_water })
;;

(* Who let in what a subject is about: the local operator, which is not an
   Admin, or an Admin, who is then not eligible to cancel its block. *)
type owner =
  | Local_operator_owned
  | Admin_owned of Authz_types.User_id.t

let owner_of_issuer = function
  | Authz_invite_state.Local_operator_issued -> Local_operator_owned
  | Authz_invite_state.Admin_issued user_id -> Admin_owned user_id
;;

(* Who stands behind a subject (design 4.1): the issuer of the invitation that
   is the subject and the Admin who wrote the registration that is the subject,
   their owners, or the issuer of the invitation or the writer of the
   registration a human principal joined through, its original approver. An
   admission through an invitation also spends the open registration of the
   identity, so the invitation is read first: it is the way the person came
   in. The first stage has no manager, and the beneficiary is the subject or
   the person an open invitation or registration is for, who has not joined
   and writes nothing. Nobody stands behind any other subject yet.

   Nobody cancels the block of a session (plan C3): the session does not act
   while it is blocked, its owner closes the block by signing out again, and a
   new sign-in of the browser closes it by ending the session. Lifting it would
   only bring back a session that its owner meant to end. Nor the block of a
   Keeper conversation whose purge was given up (plan S1b-3c): it is not read
   while blocked, and its owner closes the block by asking for the purge
   again. Lifting it would only bring back what its owner meant to delete. *)
let owner_behind state = function
  | Authz_records.Subject.Invite invite_id ->
    Option.map
      (fun (invitation : Authz_invite_state.invitation) ->
        owner_of_issuer invitation.Authz_invite_state.issuer)
      (Authz_invite_state.find state.invites invite_id)
  | Authz_records.Subject.Registration registration_id ->
    Option.map
      (fun (registration : Authz_registration_state.registration) ->
        Admin_owned registration.Authz_registration_state.registrar)
      (Authz_registration_state.find state.registrations registration_id)
  | Authz_records.Subject.Principal (Authz_types.Principal.Human user_id) ->
    (match Authz_invite_state.find_consumed_by state.invites user_id with
     | Some ((_ : Authz_types.Invite_id.t), invitation) ->
       Some (owner_of_issuer invitation.Authz_invite_state.issuer)
     | None ->
       Option.map
         (fun ((_ : Authz_types.Registration_id.t), (registration : Authz_registration_state.registration)) ->
           Admin_owned registration.Authz_registration_state.registrar)
         (Authz_registration_state.find_consumed_by state.registrations user_id))
  | Authz_records.Subject.Principal (Authz_types.Principal.Service _)
  | Authz_records.Subject.Grant _
  | Authz_records.Subject.Session _
  | Authz_records.Subject.Pat _
  | Authz_records.Subject.Service_credential _
  | Authz_records.Subject.Credential _
  | Authz_records.Subject.Runtime _
  | Authz_records.Subject.Keeper_conversation _ -> None
;;

(* An eligible Admin lifts one block (design 8.3). The canceller is never the
   subject: a principal whose reduction is held is an author that
   [author_refusal] refuses before this. A cancel raises no epoch, so the store
   takes no intent for it: a log cut back to before it brings the block back,
   which is the side that stops the subject. *)
let cancel state (record : R.t) =
  match Authz_cancel_event.of_body record.R.body with
  | Error error -> Error (Cancel_unreadable error)
  | Ok { Authz_cancel_event.aborted; subject } ->
    (match record.R.author with
     | Authz_records.Author.Authenticated (Authz_types.Principal.Human canceller)
       when Authz_principal_state.is_admin state.principals canceller ->
       (match List.find_opt (fun held -> R.Hash.equal held.aborted aborted) state.revocation_pending with
        | None -> Error (Cancel_not_held aborted)
        | Some held when not (Authz_records.Subject.equal held.subject subject) ->
          Error (Cancel_subject_differs { aborted; named = subject; held = held.subject })
        | Some (_ : held) ->
          (match owner_behind state subject with
           | None -> Error (Cancel_owner_unknown subject)
           | Some (Admin_owned owner) when Authz_types.User_id.equal owner canceller ->
             Error (Canceller_owns_the_subject subject)
           | Some (Admin_owned _ | Local_operator_owned) ->
             Ok
               { state =
                   { state with
                     revocation_pending =
                       List.filter
                         (fun held -> not (R.Hash.equal held.aborted aborted))
                         state.revocation_pending
                   }
               ; high_water = None
               }))
     | Authz_records.Author.Authenticated (Authz_types.Principal.Human _ | Authz_types.Principal.Service _)
     | Authz_records.Author.Local_operator
     | Authz_records.Author.System_cron
     | Authz_records.Author.System_maintenance
     | Authz_records.Author.System_migration -> Error (Canceller_is_not_an_admin record.R.author))
;;

(* A sign-out, and a sign-in that ends the session its browser held, end a
   session, which raises auth_binding_epoch (design 8.1). So each is a [Revoke]
   intent on the session it ends: a log restored from before it disagrees with
   the store, and the session does not act again. A sign-in that ends nothing
   takes no intent: cut back, the session is gone and its browser signs in
   again. *)
let session state (record : R.t) =
  match Authz_session_event.of_body record.R.body with
  | Error error -> Error (Session_unreadable error)
  | Ok event ->
    (match
       Authz_session_state.apply
         state.sessions
         ~author:record.R.author
         ~at_ms:record.R.at_ms
         ~is_active:(Authz_principal_state.is_active state.principals)
         event
     with
     | Error refusal -> Error (Session refusal)
     | Ok sessions ->
       let ended session_id =
         Some (C.Authz { event = C.Revoke; subject = Authz_records.Subject.Session session_id })
       in
       let high_water =
         match event with
         | Authz_session_event.Issued { replaces = Some replaced; _ } -> ended replaced
         | Authz_session_event.Issued { replaces = None; _ } -> None
         | Authz_session_event.Revoked { session_id } -> ended session_id
       in
       Ok { state = { state with sessions }; high_water })
;;

(* The revocation of a PAT or a Service credential raises auth_binding_epoch
   (design 8.1), so it is a [Revoke] intent on the credential: a log restored
   from before it disagrees with the store, and the credential does not act
   again. An issue takes no intent: cut back, the credential is gone and its
   token reads as no credential. *)
let pat state (record : R.t) =
  match Authz_pat_event.of_body record.R.body with
  | Error error -> Error (Pat_unreadable error)
  | Ok event ->
    (match
       Authz_pat_state.apply
         state.pats
         ~author:record.R.author
         ~at_ms:record.R.at_ms
         ~is_active:(Authz_principal_state.is_active state.principals)
         event
     with
     | Error refusal -> Error (Pat refusal)
     | Ok pats ->
       let high_water =
         match event with
         | Authz_pat_event.Issued _ -> None
         | Authz_pat_event.Revoked { pat_id } ->
           Some (C.Authz { event = C.Revoke; subject = Authz_records.Subject.Pat pat_id })
       in
       Ok { state = { state with pats }; high_water })
;;

let service_credential state (record : R.t) =
  match Authz_service_credential_event.of_body record.R.body with
  | Error error -> Error (Service_credential_unreadable error)
  | Ok event ->
    (match
       Authz_service_credential_state.apply
         state.service_credentials
         ~author:record.R.author
         ~at_ms:record.R.at_ms
         event
     with
     | Error refusal -> Error (Service_credential refusal)
     | Ok service_credentials ->
       let high_water =
         match event with
         | Authz_service_credential_event.Issued _ -> None
         | Authz_service_credential_event.Revoked { credential_id } ->
           Some
             (C.Authz
                { event = C.Revoke
                ; subject = Authz_records.Subject.Service_credential credential_id
                })
       in
       Ok { state = { state with service_credentials }; high_water })
;;

(* A link takes no intent: cut back to before it, the account has no owner,
   and no Runtime may spend it. *)
let provider_account state (record : R.t) =
  match Authz_provider_account_event.of_body record.R.body with
  | Error error -> Error (Provider_account_unreadable error)
  | Ok event ->
    (match
       Authz_provider_account_state.apply
         state.provider_accounts
         ~author:record.R.author
         ~is_active:(Authz_principal_state.is_active state.principals)
         event
     with
     | Error refusal -> Error (Provider_account refusal)
     | Ok provider_accounts -> Ok { state = { state with provider_accounts }; high_water = None })
;;

(* A Runtime takes no intent either: cut back to before it, the Runtime and its
   Self grant are not there, and no Keeper turn runs on it. *)
let runtime state (record : R.t) =
  match Authz_runtime_event.of_body record.R.body with
  | Error error -> Error (Runtime_unreadable error)
  | Ok event ->
    (match
       Authz_runtime_state.apply
         state.runtimes
         ~author:record.R.author
         ~is_active:(Authz_principal_state.is_active state.principals)
         ~account_owner:(Authz_provider_account_state.owner state.provider_accounts)
         event
     with
     | Error refusal -> Error (Runtime refusal)
     | Ok runtimes -> Ok { state = { state with runtimes }; high_water = None })
;;

(* A Keeper takes no intent either: cut back to before its record, the Keeper
   has no owner, or no Runtime its turns run on. *)
let keeper state (record : R.t) =
  match Authz_keeper_event.of_body record.R.body with
  | Error error -> Error (Keeper_unreadable error)
  | Ok event ->
    (match
       Authz_keeper_state.apply
         state.keepers
         ~author:record.R.author
         ~is_active:(Authz_principal_state.is_active state.principals)
         ~runtime_owner:(Authz_runtime_state.owner state.runtimes)
         event
     with
     | Error refusal -> Error (Keeper refusal)
     | Ok keepers -> Ok { state = { state with keepers }; high_water = None })
;;

(* The start of a purge takes its target out of reads (design 8.5-1 and
   8.5-2), so it is a [Purge] intent on the target: a log restored from before
   it disagrees with the store, and the target does not read again. Its end
   takes no intent: cut back to before it, the purge is pending again, and the
   maintenance deletes once more. *)
let purge state (record : R.t) =
  match Authz_purge_event.of_body record.R.body with
  | Error error -> Error (Purge_unreadable error)
  | Ok event ->
    (match
       Authz_purge_state.apply
         state.purges
         ~author:record.R.author
         ~is_active:(Authz_principal_state.is_active state.principals)
         event
     with
     | Error refusal -> Error (Purge refusal)
     | Ok purges ->
       let high_water =
         match event with
         | Authz_purge_event.Purge_pending { target } ->
           Some (C.Authz { event = C.Purge; subject = Authz_purge_event.subject target })
         | Authz_purge_event.Purged _ | Authz_purge_event.Purge_failed _ -> None
       in
       Ok { state = { state with purges }; high_water })
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
  | K.Admission, Authz_mode_state.Multi_account workspace_id -> admission state ~workspace_id record
  | K.Admission, Authz_mode_state.Off _ -> Error (Accounts_off K.Admission)
  | K.Admin_assignment, Authz_mode_state.Multi_account _ -> admin_assignment state record
  | K.Admin_assignment, Authz_mode_state.Off _ -> Error (Accounts_off K.Admin_assignment)
  | K.Principal, Authz_mode_state.Multi_account _ -> principal_event state record
  | K.Principal, Authz_mode_state.Off _ -> Error (Accounts_off K.Principal)
  | K.Revocation_cancel, Authz_mode_state.Multi_account _ -> cancel state record
  | K.Revocation_cancel, Authz_mode_state.Off _ -> Error (Accounts_off K.Revocation_cancel)
  | K.Registration, Authz_mode_state.Multi_account _ -> registration state record
  | K.Registration, Authz_mode_state.Off _ -> Error (Accounts_off K.Registration)
  | K.Session, Authz_mode_state.Multi_account _ -> session state record
  | K.Session, Authz_mode_state.Off _ -> Error (Accounts_off K.Session)
  | K.Pat, Authz_mode_state.Multi_account _ -> pat state record
  | K.Pat, Authz_mode_state.Off _ -> Error (Accounts_off K.Pat)
  | K.Internal_service_credential, Authz_mode_state.Multi_account _ -> service_credential state record
  | K.Internal_service_credential, Authz_mode_state.Off _ ->
    Error (Accounts_off K.Internal_service_credential)
  | K.Provider_account, Authz_mode_state.Multi_account _ -> provider_account state record
  | K.Provider_account, Authz_mode_state.Off _ -> Error (Accounts_off K.Provider_account)
  | K.Runtime, Authz_mode_state.Multi_account _ -> runtime state record
  | K.Runtime, Authz_mode_state.Off _ -> Error (Accounts_off K.Runtime)
  | K.Keeper, Authz_mode_state.Multi_account _ -> keeper state record
  | K.Keeper, Authz_mode_state.Off _ -> Error (Accounts_off K.Keeper)
  | K.Purge, Authz_mode_state.Multi_account _ -> purge state record
  | K.Purge, Authz_mode_state.Off _ -> Error (Accounts_off K.Purge)
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
      | K.Admin_assignment
      | K.Revocation_cancel
      | K.Registration
      | K.Session
      | K.Pat
      | K.Provider_account
      | K.Runtime
      | K.Keeper
      | K.Purge ) as kind )
    , Authz_mode_state.Not_bootstrapped -> Error (Before_bootstrap kind)
  | ( ( K.Runtime_grant
      | K.Delegate_policy
      | K.Permission_revocation
      | K.Trigger_evidence
      | K.Lease_terminal_evidence
      | K.Preauthorized_expiry
      | K.Migration_diagnostic
      | K.Local_recovery ) as kind )
    , (Authz_mode_state.Multi_account _ | Off _) -> Error (Kind_not_read kind)
;;

(* A deleted principal, or one that is there and not active. A person who has
   not joined yet is neither, and writes their own admission. *)
let inactive principals user_id =
  Authz_principal_state.is_deleted principals user_id
  || (Option.is_some (Authz_principal_state.find principals user_id)
      && not (Authz_principal_state.is_active principals user_id))
;;

(* A principal whose revocation the store gave up writes nothing (design 8.3):
   an Admin whose assignment was being revoked neither invites nor revokes
   another Admin while the block stands. A disabled or deleted principal writes
   nothing either (design 4.1). *)
let author_refusal state (author : Authz_records.Author.t) =
  match author with
  | Authz_records.Author.Authenticated principal ->
    let subject = Authz_records.Subject.Principal principal in
    if is_pending state subject
    then Some (Revocation_pending subject)
    else (
      match principal with
      | Authz_types.Principal.Human user_id when inactive state.principals user_id ->
        Some (Author_inactive user_id)
      | Authz_types.Principal.Human _ | Authz_types.Principal.Service _ -> None)
  | Authz_records.Author.Local_operator
  | Authz_records.Author.System_cron
  | Authz_records.Author.System_maintenance
  | Authz_records.Author.System_migration -> None
;;

(* Every record that is read moves the latest time, whatever its kind. *)
let later state (record : R.t) =
  match state.latest_at_ms with
  | Some latest_at_ms when latest_at_ms >= record.R.at_ms -> state
  | Some (_ : int) | None -> { state with latest_at_ms = Some record.R.at_ms }
;;

(* A record that makes a given-up reduction again closes its block (design
   8.3). The record names each block it closes, so a replay closes the same
   ones, and a log cut back to before it no longer closes them. *)
let close (applied : applied) (record : R.t) =
  match record.R.closes with
  | [] -> Ok applied.state
  | closes ->
    (match applied.high_water with
     | Some change when C.is_reduction change ->
       let held = closable applied.state change in
       (match List.find_opt (fun aborted -> not (List.exists (R.Hash.equal aborted) held)) closes with
        | Some aborted -> Error (Closes_not_held aborted)
        | None ->
          Ok
            { applied.state with
              revocation_pending =
                List.filter
                  (fun held -> not (List.exists (R.Hash.equal held.aborted) closes))
                  applied.state.revocation_pending
            })
     | Some (_ : C.t) | None -> Error Closes_without_reduction)
;;

let apply state (record : R.t) =
  match author_refusal state record.R.author with
  | Some refusal -> Error refusal
  | None ->
    let ( let* ) = Result.bind in
    let* applied = read state record in
    let* closed = close applied record in
    Ok { applied with state = later closed record }
;;

let closed_by (record : R.t) =
  match record.R.kind with
  | K.Revocation_cancel ->
    (match Authz_cancel_event.of_body record.R.body with
     | Ok { Authz_cancel_event.aborted; subject = _ } -> aborted :: record.R.closes
     | Error (_ : Authz_cancel_event.error) -> record.R.closes)
  | K.Runtime_grant
  | K.Delegate_policy
  | K.Principal
  | K.Internal_service_credential
  | K.Permission_revocation
  | K.Trigger_evidence
  | K.Lease_terminal_evidence
  | K.Preauthorized_expiry
  | K.Migration_diagnostic
  | K.Local_recovery
  | K.Mode_event
  | K.Invite
  | K.Admission
  | K.Admin_assignment
  | K.Registration
  | K.Session
  | K.Pat
  | K.Provider_account
  | K.Runtime
  | K.Keeper
  | K.Purge -> record.R.closes
;;
