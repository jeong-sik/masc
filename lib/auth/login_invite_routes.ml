(* HIGH-RISK-UNREVIEWED: see the interface. *)

module E = Authz_invite_event
module R = Login_routes
module S = Authz_state

let path = "/api/v1/auth/invites"
let shape = {|The body is {"role": "member"} or {"role": "admin"}.|}
let refused status text = R.json status [ "error", `String text ]

let role_of_body body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error (_ : string) -> Error shape
  | `Assoc [ ("role", `String label) ] -> Option.to_result ~none:shape (E.role_of_label label)
  | _ -> Error shape
;;

let invite_status = function
  | Authz_invite_state.Author_is_not_an_admin (_ : Authz_types.Principal.t) -> R.Forbidden_403
  | Authz_invite_state.Not_issued (_ : Authz_types.Invite_id.t) -> R.Not_found_404
  | Authz_invite_state.Already_revoked (_ : Authz_types.Invite_id.t)
  | Authz_invite_state.Already_consumed (_ : Authz_types.Invite_id.t) -> R.Conflict_409
  (* The id and the token are drawn fresh, and the author is the human
     principal of the session: no local operator, and one that may write an
     invite record. *)
  | Authz_invite_state.Already_issued (_ : Authz_types.Invite_id.t)
  | Authz_invite_state.Token_digest_taken (_ : Authz_types.Invite_id.t)
  | Authz_invite_state.Local_operator_invites_only_admins
  | Authz_invite_state.Not_an_invite_author (_ : Authz_records.Author.t) -> R.Internal_error_500
;;

(* What the state says of an invite record that an Admin's session wrote.
   Only the invitation itself, the author, and the mode can refuse it; the
   other refusals are of other kinds of record, or of a record that closes a
   reduction, which this one does not. *)
let state_status = function
  | S.Invite refusal -> invite_status refusal
  | S.Author_inactive (_ : Authz_types.User_id.t) | S.Revocation_pending (_ : Authz_records.Subject.t) ->
    R.Forbidden_403
  | S.Before_bootstrap (_ : Authz_record.Kind.t) | S.Accounts_off (_ : Authz_record.Kind.t) ->
    R.Service_unavailable_503
  | S.Invite_unreadable (_ : E.error)
  | S.Mode_event_unreadable _
  | S.Mode _
  | S.Admission_unreadable _
  | S.Admission _
  | S.Admin_assignment_unreadable _
  | S.Admin_assignment _
  | S.Principal_unreadable _
  | S.Principal_event _
  | S.Registration_unreadable _
  | S.Registration _
  | S.Kind_not_read _
  | S.Admission_behind_log _
  | S.Closes_without_reduction
  | S.Closes_not_held _
  | S.Cancel_unreadable _
  | S.Canceller_is_not_an_admin _
  | S.Cancel_not_held _
  | S.Cancel_subject_differs _
  | S.Canceller_owns_the_subject _
  | S.Cancel_owner_unknown _
  | S.Session_unreadable _
  | S.Session _
  | S.Pat_unreadable _
  | S.Pat _
  | S.Service_credential_unreadable _
  | S.Service_credential _
  | S.Provider_account_unreadable _
  | S.Provider_account _
  | S.Runtime_unreadable _
  | S.Runtime _
  | S.Keeper_unreadable _
  | S.Keeper _ -> R.Internal_error_500
;;

let error_status = function
  | Authz_invite.Commit_failed (Authz_zone.Refused refusal) -> state_status refusal
  | Authz_invite.Id_not_drawn (_ : Authz_id.error)
  | Authz_invite.Body_not_built (_ : Authz_body.error)
  | Authz_invite.Commit_failed (Authz_zone.Record_not_built _ | Authz_zone.Log_holds_records _) ->
    R.Internal_error_500
  | Authz_invite.Commit_failed
      ( Authz_zone.Store_stopped _
      | Authz_zone.Log_stopped _
      | Authz_zone.Uncertain _
      | Authz_zone.Store_holds_no_answer
      | Authz_zone.Store_entry_refused _
      | Authz_zone.Abort_not_confirmed _
      | Authz_zone.Settlement_not_written _
      | Authz_zone.Intent_not_written _
      | Authz_zone.Record_not_appended _
      | Authz_zone.Answer_not_written _ ) -> R.Service_unavailable_503
;;

let failed error = refused (error_status error) (Authz_invite.error_to_string error)

let issue (t : R.t) request ~body =
  match R.acting t request with
  | Error answer -> answer
  | Ok ((_ : Authz_browser_session.Cookie.t), { Authz_browser_session.user_id = admin; _ }) ->
    (match role_of_body body with
     | Error text -> refused R.Bad_request_400 text
     | Ok role ->
       (match
          Authz_invite.issue
            t.R.zone
            ~admin
            ~draw:t.R.draw
            ~now_ms:(fun () -> R.ms_of (t.R.now ()))
            role
        with
        | Error error -> failed error
        | Ok { Authz_invite.invite_id; token; expires_at_ms; role } ->
          R.json
            R.Ok_200
            [ "invite_id", `String (Authz_types.Invite_id.to_string invite_id)
            ; "role", `String (E.role_label role)
            ; "expires_at_ms", `Int expires_at_ms
            ; "link", `String (Authz_activation.invitation_path ^ "#" ^ token)
            ]))
;;

let revoke (t : R.t) request ~invite_id =
  match R.acting t request with
  | Error answer -> answer
  | Ok ((_ : Authz_browser_session.Cookie.t), { Authz_browser_session.user_id = admin; _ }) ->
    (match Authz_types.Invite_id.of_string invite_id with
     | Error error -> refused R.Bad_request_400 ("the invite id is refused: " ^ Authz_id.error_to_string error)
     | Ok invite_id ->
       (match Authz_invite.revoke t.R.zone ~admin invite_id with
        | Error error -> failed error
        | Ok () -> { R.status = R.No_content_204; headers = [ "cache-control", "no-store" ]; body = "" }))
;;
