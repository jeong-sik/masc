(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module Principals = Authz_principal_state

let ( let* ) = Result.bind

type outcome =
  | Signed_in of User_id.t
  | Admitted of
      { user_id : User_id.t
      ; role : Authz_invite_event.role
      ; previously_deleted : bool
      }

type refusal =
  | Not_invited
  | Disabled of User_id.t
  | Blocked of User_id.t
  | Uncertain
  | Already_joined of User_id.t
  | Invitation_unknown
  | Admission_refused of Principals.refusal
  | Not_bootstrapped
  | Id_not_drawn of Authz_id.error
  | Body_not_built of Authz_body.error
  | Commit_failed of Authz_zone.error

let refusal_to_string = function
  | Not_invited ->
    "this identity has no principal, came with no invitation, and has no open allowlist entry"
  | Disabled user_id -> Printf.sprintf "the principal %s is disabled" (User_id.to_string user_id)
  | Blocked user_id ->
    Printf.sprintf "a revocation of %s was given up and still blocks it" (User_id.to_string user_id)
  | Uncertain -> "the authorization log cannot be trusted now, so nobody signs in"
  | Already_joined user_id ->
    Printf.sprintf "this identity already joined as %s, so the invitation is left open" (User_id.to_string user_id)
  | Invitation_unknown -> "no invitation has this token"
  | Admission_refused refusal -> Principals.refusal_to_string refusal
  | Not_bootstrapped -> "the installation has no workspace yet"
  | Id_not_drawn error -> "a drawn id was refused: " ^ Authz_id.error_to_string error
  | Body_not_built error -> "the admission body was not built: " ^ Authz_body.error_to_string error
  | Commit_failed error -> Authz_zone.error_to_string error
;;

let is_conflict = function
  | Already_joined _ -> true
  | Admission_refused refusal ->
    (match refusal with
     | Principals.Invitation consume ->
       (match consume with
        | Authz_invite_state.Invitation_consumed _ -> true
        | Authz_invite_state.Invitation_not_issued _
        | Authz_invite_state.Invitation_revoked _
        | Authz_invite_state.Invitation_expired _ -> false)
     | Principals.Registration consume ->
       (match consume with
        | Authz_registration_state.Registration_consumed _ -> true
        | Authz_registration_state.Registration_not_found _
        | Authz_registration_state.Registration_removed _
        | Authz_registration_state.Identity_differs _ -> false)
     | Principals.Identity_bound _ -> true
     | Principals.Author_is_not_the_person _
     | Principals.User_id_taken _
     | Principals.Workspace_differs _
     | Principals.Namespace_taken _ -> false)
  | Not_invited
  | Disabled _
  | Blocked _
  | Uncertain
  | Invitation_unknown
  | Not_bootstrapped
  | Id_not_drawn _
  | Body_not_built _
  | Commit_failed _ -> false
;;

let attempts = 3

let signed_in (state : Authz_state.t) user_id =
  match Authz_state.revocation state (Subject.Principal (Principal.Human user_id)) with
  | Revocation_state.Not_pending -> Ok (Signed_in user_id)
  | Revocation_state.Pending -> Error (Blocked user_id)
;;

let drawn of_string draw = Result.map_error (fun error -> Id_not_drawn error) (of_string (draw ()))

(* One try: draw the ids, check the admission on [snapshot], then commit it.
   [`Again] is a refusal that a new draw or a new snapshot can lift. *)
let try_admission zone ~(snapshot : Authz_zone.snapshot) ~now_ms ~draw ~identity ~through ~workspace_id =
  let state = snapshot.state in
  let* user_id = drawn User_id.of_string draw in
  let* account_home_namespace = drawn Account_home_namespace.of_string draw in
  let event =
    { Authz_admission_event.user_id
    ; identity
    ; through
    ; membership = { workspace_id; account_home_namespace }
    }
  in
  let author = Author.Authenticated (Principal.Human user_id) in
  match
    Principals.admit
      state.principals
      ~invites:state.invites
      ~registrations:state.registrations
      ~workspace_id
      ~author
      ~at_ms:(now_ms ())
      event
  with
  | Error ((Principals.User_id_taken _ | Principals.Namespace_taken _) as refusal) ->
    Ok (`Again (Admission_refused refusal))
  | Error
      ((Principals.Author_is_not_the_person _
       | Principals.Invitation _
       | Principals.Registration _
       | Principals.Identity_bound _
       | Principals.Workspace_differs _) as refusal) -> Error (Admission_refused refusal)
  | Ok { Principals.role; _ } ->
    let* body = Result.map_error (fun error -> Body_not_built error) (Authz_admission_event.to_body event) in
    (match Authz_zone.commit zone { Authz_zone.author; kind = Authz_record.Kind.Admission; body } with
     | Ok committed ->
       Ok
         (`Done
             (Admitted
                { user_id
                ; role
                ; previously_deleted = Principals.was_deleted committed.snapshot.state.principals identity
                }))
     | Error error ->
       let moved =
         Authz_record.next_seq (Authz_zone.snapshot zone).head <> Authz_record.next_seq snapshot.head
       in
       if moved then Ok (`Again (Commit_failed error)) else Error (Commit_failed error))
;;

(* The way in, read from each snapshot: the invitation whose token came with
   the login, or the open allowlist entry of the identity (plan C2d). *)
let through_invitation invite (state : Authz_state.t) =
  match Authz_invite_state.find_by_token_digest state.invites invite with
  | None -> Error Invitation_unknown
  | Some (invite_id, _) -> Ok (Authz_admission_event.Invite invite_id)
;;

let through_registration identity (state : Authz_state.t) =
  match Authz_registration_state.find_open state.registrations identity with
  | None -> Error Not_invited
  | Some (registration_id, _) -> Ok (Authz_admission_event.Registration registration_id)
;;

let admission zone ~now_ms ~draw ~identity ~through_of =
  let rec go left =
    let snapshot = Authz_zone.snapshot zone in
    let state = snapshot.state in
    match Principals.find_identity state.principals identity with
    | Some user_id -> Error (Already_joined user_id)
    | None ->
      let* through = through_of state in
      (match Authz_mode_state.workspace state.mode with
       | None -> Error Not_bootstrapped
       | Some workspace_id ->
         let* result = try_admission zone ~snapshot ~now_ms ~draw ~identity ~through ~workspace_id in
         (match result with
          | `Done outcome -> Ok outcome
          | `Again last -> if left > 1 then go (left - 1) else Error last))
  in
  go attempts
;;

let sign_in zone ~now_ms ~draw ~identity ~invite =
  match Authz_zone.read zone with
  | Error (_ : Authz_zone.uncertain) -> Error Uncertain
  | Ok trusted ->
    let state = (trusted :> Authz_zone.snapshot).state in
    let principals = state.principals in
    (match Principals.find_identity principals identity, invite with
     | Some user_id, None ->
       if Principals.is_active principals user_id then signed_in state user_id else Error (Disabled user_id)
     | Some user_id, Some _ -> Error (Already_joined user_id)
     | None, None -> admission zone ~now_ms ~draw ~identity ~through_of:(through_registration identity)
     | None, Some invite -> admission zone ~now_ms ~draw ~identity ~through_of:(through_invitation invite))
;;
