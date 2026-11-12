(* HIGH-RISK-UNREVIEWED: see the interface. *)

module R = Login_routes
module S = Authz_state
module State = Authz_pat_state

let ( let* ) = Result.bind
let path = "/api/v1/auth/pats"
let refused status text = R.json status [ "error", `String text ]
let ms_of = R.ms_of

(* The scope and the expiry the person chose. Both members are required, so a
   PAT never gets a scope the person did not state (design 4.4). *)
let issue_request ~now_ms body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error (_ : string) -> Error "the body is not JSON"
  | json ->
    (match Authz_body.of_yojson json with
     | Error error -> Error (Authz_body.error_to_string error)
     | Ok (Authz_body.Object [ ("scope", scope); ("expires_at_ms", expiry) ]) ->
       let* scope =
         Result.map_error
           (fun error -> "the scope is refused: " ^ Authz_scope_body.error_to_string error)
           (Authz_scope_body.of_body scope)
       in
       let* expires_at_ms =
         match expiry with
         | Authz_body.Null -> Ok None
         | Authz_body.Int expires_at_ms ->
           if expires_at_ms > now_ms
           then Ok (Some expires_at_ms)
           else Error "the expiry is not after now"
         | Authz_body.Bool _ | Authz_body.String _ | Authz_body.List _ | Authz_body.Object _ ->
           Error "expires_at_ms is neither an integer nor null"
       in
       Ok (scope, expires_at_ms)
     | Ok
         ( Authz_body.Null
         | Authz_body.Bool _
         | Authz_body.Int _
         | Authz_body.String _
         | Authz_body.List _
         | Authz_body.Object _ ) ->
       Error
         {|the body is not {"scope": ..., "expires_at_ms": ...} with these two members in this order|})
;;

(* The person of the session writes a record about their own PAT, so the
   state refuses it for these reasons. A PAT that is not theirs gets the text
   of an id that names nothing, so the answer says nothing of another's PAT.
   The last four mean a bug: the route issues for the session's own human
   principal, with an id it drew. *)
let pat_answer ~text = function
  | State.Not_issued pat_id | State.Not_the_owner { pat_id; author = _ } ->
    R.Not_found_404, "this person has no PAT " ^ Authz_types.Pat_id.to_string pat_id
  | State.Already_revoked (_ : Authz_types.Pat_id.t) -> R.Conflict_409, text
  | State.User_not_active (_ : Authz_types.User_id.t) -> R.Forbidden_403, text
  | State.Already_issued (_ : Authz_types.Pat_id.t)
  | State.Issued_for_another _
  | State.Not_a_human (_ : Authz_types.Principal.t)
  | State.Not_a_pat_author (_ : Authz_records.Author.t) -> R.Internal_error_500, text
;;

(* What the state says of a PAT record that a session wrote. Only the PAT
   itself, the author, and the mode can refuse it; the other refusals are of
   other kinds of record, or of a record that closes a reduction, which this
   one does not. *)
let state_answer ~text = function
  | S.Pat refusal -> pat_answer ~text refusal
  | S.Author_inactive (_ : Authz_types.User_id.t) | S.Revocation_pending (_ : Authz_records.Subject.t) ->
    R.Forbidden_403, text
  | S.Before_bootstrap (_ : Authz_record.Kind.t) | S.Accounts_off (_ : Authz_record.Kind.t) ->
    R.Service_unavailable_503, text
  | S.Pat_unreadable _
  | S.Registration_unreadable _
  | S.Registration _
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
  | S.Service_credential_unreadable _
  | S.Service_credential _
  | S.Provider_account_unreadable _
  | S.Provider_account _
  | S.Runtime_unreadable _
  | S.Runtime _
  | S.Keeper_unreadable _
  | S.Keeper _ -> R.Internal_error_500, text
;;

let error_answer error =
  let text = Authz_pat.error_to_string error in
  match error with
  | Authz_pat.Commit_failed (Authz_zone.Refused refusal) -> state_answer ~text refusal
  | Authz_pat.Id_not_drawn (_ : Authz_id.error)
  | Authz_pat.Body_not_built (_ : Authz_body.error)
  | Authz_pat.Commit_failed (Authz_zone.Record_not_built _ | Authz_zone.Log_holds_records _) ->
    R.Internal_error_500, text
  | Authz_pat.Commit_failed
      ( Authz_zone.Store_stopped _
      | Authz_zone.Log_stopped _
      | Authz_zone.Uncertain _
      | Authz_zone.Store_holds_no_answer
      | Authz_zone.Store_entry_refused _
      | Authz_zone.Abort_not_confirmed _
      | Authz_zone.Settlement_not_written _
      | Authz_zone.Intent_not_written _
      | Authz_zone.Record_not_appended _
      | Authz_zone.Answer_not_written _ ) -> R.Service_unavailable_503, text
;;

let failed error =
  let status, text = error_answer error in
  refused status text
;;

let issue (t : R.t) request ~body =
  match R.acting t request with
  | Error answer -> answer
  | Ok ((_ : Authz_browser_session.Cookie.t), { Authz_browser_session.user_id; _ }) ->
    (match issue_request ~now_ms:(ms_of (t.R.now ())) body with
     | Error text -> refused R.Bad_request_400 text
     | Ok (scope, expires_at_ms) ->
       (match Authz_pat.issue t.R.zone ~user_id ~draw:t.R.draw ~scope ~expires_at_ms with
        | Error error -> failed error
        | Ok token ->
          R.json
            R.Ok_200
            [ ( "pat_id"
              , `String (Authz_types.Pat_id.to_string (Authz_credential_token.Pat.id token)) )
            ; "token", `String (Authz_credential_token.Pat.to_string token)
            ]))
;;

(* [find_active] decides, so the expiry rule stays in one place. A listed id
   comes from the same snapshot, so [Unknown] would mean the state lost it, and
   the label says that rather than guess. *)
let status_label = function
  | Ok (_ : State.pat) -> "open"
  | Error State.Expired -> "expired"
  | Error State.Ended -> "revoked"
  | Error State.Unknown -> "unknown"
;;

let listed ~now_ms pats (pat_id, { State.scope; expires_at_ms; issued_at_ms; _ }) =
  let* scope = Authz_scope_body.to_body scope in
  Ok
    (`Assoc
        [ "pat_id", `String (Authz_types.Pat_id.to_string pat_id)
        ; "scope", Authz_body.to_yojson scope
        ; ( "expires_at_ms"
          , match expires_at_ms with
            | None -> `Null
            | Some expires_at_ms -> `Int expires_at_ms )
        ; "issued_at_ms", `Int issued_at_ms
        ; "status", `String (status_label (State.find_active pats pat_id ~now_ms))
        ])
;;

let list (t : R.t) request =
  match R.acting t request with
  | Error answer -> answer
  | Ok ((_ : Authz_browser_session.Cookie.t), { Authz_browser_session.user_id; _ }) ->
    let pats = (Authz_zone.snapshot t.R.zone).Authz_zone.state.S.pats in
    let now_ms = ms_of (t.R.now ()) in
    let entries =
      List.fold_right
        (fun pat entries ->
          let* entry = listed ~now_ms pats pat in
          let* entries = entries in
          Ok (entry :: entries))
        (State.of_user pats user_id)
        (Ok [])
    in
    (match entries with
     | Error error ->
       refused R.Internal_error_500 ("a scope was not written: " ^ Authz_body.error_to_string error)
     | Ok entries -> R.json R.Ok_200 [ "pats", `List entries ])
;;

let revoke (t : R.t) request ~pat_id =
  match R.acting t request with
  | Error answer -> answer
  | Ok ((_ : Authz_browser_session.Cookie.t), { Authz_browser_session.user_id; _ }) ->
    (match Authz_types.Pat_id.of_string pat_id with
     | Error error -> refused R.Bad_request_400 ("the PAT id is refused: " ^ Authz_id.error_to_string error)
     | Ok pat_id ->
       (match Authz_pat.revoke t.R.zone ~user_id pat_id with
        | Ok () -> { R.status = R.No_content_204; headers = [ "cache-control", "no-store" ]; body = "" }
        | Error error -> failed error))
;;
