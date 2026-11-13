(* HIGH-RISK-UNREVIEWED: see the interface. *)

module R = Login_routes
module S = Authz_state

let path = "/api/v1/auth/allowlist"

let refused status text = R.json status [ "error", `String text ]

let identity_of_body body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error (_ : string) -> Error "the body is not JSON"
  | json ->
    (match Authz_body.of_yojson json with
     | Error error -> Error (Authz_body.error_to_string error)
     | Ok body ->
       Result.map_error Authz_external_identity.body_error_to_string (Authz_external_identity.of_body body))
;;

let registration_status = function
  | Authz_registration_state.Author_is_not_an_admin (_ : Authz_types.Principal.t) -> R.Forbidden_403
  | Authz_registration_state.Not_registered (_ : Authz_types.Registration_id.t) -> R.Not_found_404
  | Authz_registration_state.Already_registered (_ : Authz_types.Registration_id.t)
  | Authz_registration_state.Identity_registered (_ : Authz_types.Registration_id.t)
  | Authz_registration_state.Identity_bound
  | Authz_registration_state.Already_removed (_ : Authz_types.Registration_id.t)
  | Authz_registration_state.Already_consumed (_ : Authz_types.Registration_id.t) -> R.Conflict_409
  (* The author is the human principal of the session, which may write a
     registration record. *)
  | Authz_registration_state.Not_a_registration_author (_ : Authz_records.Author.t) -> R.Internal_error_500
;;

(* What the state says of a registration record that an Admin's session wrote.
   Only the registration itself, the author, and the mode can refuse it; the
   other refusals are of other kinds of record, or of a record that closes a
   reduction, which this one does not. *)
let state_status = function
  | S.Registration refusal -> registration_status refusal
  | S.Author_inactive (_ : Authz_types.User_id.t) | S.Revocation_pending (_ : Authz_records.Subject.t) ->
    R.Forbidden_403
  | S.Before_bootstrap (_ : Authz_record.Kind.t) | S.Accounts_off (_ : Authz_record.Kind.t) ->
    R.Service_unavailable_503
  | S.Registration_unreadable (_ : Authz_registration_event.error)
  | S.Mode_event_unreadable _
  | S.Mode _
  | S.Invite_unreadable _
  | S.Invite _
  | S.Admission_unreadable _
  | S.Admission _
  | S.Admin_assignment_unreadable _
  | S.Admin_assignment _
  | S.Principal_unreadable _
  | S.Principal_event _
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
  | S.Keeper _
  | S.Purge_unreadable _
  | S.Purge _ -> R.Internal_error_500
;;

let error_status = function
  | Authz_allowlist.Commit_failed (Authz_zone.Refused refusal) -> state_status refusal
  | Authz_allowlist.Id_not_drawn (_ : Authz_id.error)
  | Authz_allowlist.Body_not_built (_ : Authz_body.error)
  | Authz_allowlist.Commit_failed (Authz_zone.Record_not_built _ | Authz_zone.Log_holds_records _) ->
    R.Internal_error_500
  | Authz_allowlist.Commit_failed
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

let failed error = refused (error_status error) (Authz_allowlist.error_to_string error)

let register (t : R.t) request ~body =
  match R.acting t request with
  | Error answer -> answer
  | Ok ((_ : Authz_browser_session.Cookie.t), { Authz_browser_session.user_id = admin; _ }) ->
    (match identity_of_body body with
     | Error text -> refused R.Bad_request_400 text
     | Ok identity ->
       (match Authz_allowlist.register t.R.zone ~admin ~draw:t.R.draw identity with
        | Error error -> failed error
        | Ok { Authz_allowlist.registration_id; previously_deleted } ->
          R.json
            R.Ok_200
            [ "registration_id", `String (Authz_types.Registration_id.to_string registration_id)
            ; "previously_deleted", `Bool previously_deleted
            ]))
;;

let remove (t : R.t) request ~registration_id =
  match R.acting t request with
  | Error answer -> answer
  | Ok ((_ : Authz_browser_session.Cookie.t), { Authz_browser_session.user_id = admin; _ }) ->
    (match Authz_types.Registration_id.of_string registration_id with
     | Error error -> refused R.Bad_request_400 ("the registration id is refused: " ^ Authz_id.error_to_string error)
     | Ok registration_id ->
       (match Authz_allowlist.remove t.R.zone ~admin registration_id with
        | Error error -> failed error
        | Ok () -> { R.status = R.No_content_204; headers = [ "cache-control", "no-store" ]; body = "" }))
;;
