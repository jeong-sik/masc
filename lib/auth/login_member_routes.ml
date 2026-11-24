(* HIGH-RISK-UNREVIEWED: see the interface. *)

module P = Authz_principal_state
module R = Login_routes
module S = Authz_state

let path = "/api/v1/auth/members"
let refused status text = R.json status [ "error", `String text ]

let status_name = function
  | P.Active -> "active"
  | P.Disabled -> "disabled"
;;

(* Each kind of reduction of a principal is its own change in the store
   (Revoke for the end of an Admin assignment, Disable, Delete), and a change
   made again closes the holds of that change only, so the list names them. *)
let held state user_id =
  let subject = Authz_records.Subject.Principal (Authz_types.Principal.Human user_id) in
  List.sort_uniq
    String.compare
    (List.filter_map
       (fun (held : S.held) ->
         if Authz_records.Subject.equal held.subject subject
         then Some (Authz_external_store.Change.authz_event_label held.event)
         else None)
       state.S.revocation_pending)
;;

let member state (user_id, (principal : P.principal)) =
  match Authz_external_identity.to_body principal.identity with
  | Error error -> Error error
  | Ok identity ->
    let role =
      if P.has_admin_assignment state.S.principals user_id
      then Authz_invite_event.Admin
      else Authz_invite_event.Member
    in
    Ok
      (`Assoc
          [ "user_id", `String (Authz_types.User_id.to_string user_id)
          ; "identity", Authz_body.to_yojson identity
          ; "role", `String (Authz_invite_event.role_label role)
          ; "status", `String (status_name principal.status)
          ; "held", `List (List.map (fun label -> `String label) (held state user_id))
          ])
;;

let list (t : R.t) request =
  match R.admin_reading t request with
  | Error answer -> answer
  | Ok state ->
    let rec members acc = function
      | [] -> Ok (List.rev acc)
      | one :: rest ->
        (match member state one with
         | Error error -> Error error
         | Ok json -> members (json :: acc) rest)
    in
    (match members [] (P.bindings state.S.principals) with
     | Error error -> refused R.Internal_error_500 ("an identity is not shown: " ^ Authz_body.error_to_string error)
     | Ok members -> R.json R.Ok_200 [ "members", `List members ])
;;

let revoke_admin_shape =
  {|The body is {"cause": "security_incident"} or {"cause": "operational"}.|}
;;

let cause_of_body body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error (_ : string) -> Error revoke_admin_shape
  | `Assoc [ ("cause", `String label) ] ->
    Option.to_result ~none:revoke_admin_shape (Authz_admin_event.cause_of_label label)
  | _ -> Error revoke_admin_shape
;;

let principal_status = function
  | P.Writer_is_not_an_admin (_ : Authz_records.Author.t) -> R.Forbidden_403
  | P.No_principal (_ : Authz_types.User_id.t) -> R.Not_found_404
  | P.Already_disabled (_ : Authz_types.User_id.t)
  | P.Not_disabled (_ : Authz_types.User_id.t)
  | P.Identity_differs { user_id = _; identity = _ }
  | P.Would_leave_no_admin (_ : Authz_types.User_id.t) -> R.Conflict_409
;;

let revocation_status = function
  | P.Revoker_is_not_an_admin (_ : Authz_records.Author.t) -> R.Forbidden_403
  | P.Not_an_admin (_ : Authz_types.User_id.t) | P.Last_admin (_ : Authz_types.User_id.t) ->
    R.Conflict_409
;;

let state_status = function
  | S.Principal_event refusal -> principal_status refusal
  | S.Admin_assignment refusal -> revocation_status refusal
  | S.Author_inactive (_ : Authz_types.User_id.t)
  | S.Revocation_pending (_ : Authz_records.Subject.t) -> R.Forbidden_403
  | S.Before_bootstrap (_ : Authz_record.Kind.t)
  | S.Accounts_off (_ : Authz_record.Kind.t) -> R.Service_unavailable_503
  | S.Mode_event_unreadable _
  | S.Mode _
  | S.Invite_unreadable _
  | S.Invite _
  | S.Admission_unreadable _
  | S.Admission _
  | S.Admin_assignment_unreadable _
  | S.Principal_unreadable _
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
  | S.Registration_unreadable _
  | S.Registration _
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

let commit_error_status = function
  | Authz_zone.Refused refusal -> state_status refusal
  | Authz_zone.Record_not_built _ | Authz_zone.Log_holds_records _ -> R.Internal_error_500
  | Authz_zone.Store_stopped _
  | Authz_zone.Log_stopped _
  | Authz_zone.Uncertain _
  | Authz_zone.Store_holds_no_answer
  | Authz_zone.Store_entry_refused _
  | Authz_zone.Abort_not_confirmed _
  | Authz_zone.Settlement_not_written _
  | Authz_zone.Intent_not_written _
  | Authz_zone.Record_not_appended _
  | Authz_zone.Answer_not_written _ -> R.Service_unavailable_503
;;

let commit_failed error = refused (commit_error_status error) (Authz_zone.error_to_string error)

let is_acting_admin state user_id =
  let subject = Authz_records.Subject.Principal (Authz_types.Principal.Human user_id) in
  match P.is_admin state.S.principals user_id, S.revocation state subject with
  | true, Authz_records.Revocation_state.Not_pending -> true
  | false, (Authz_records.Revocation_state.Not_pending | Authz_records.Revocation_state.Pending)
  | true, Authz_records.Revocation_state.Pending -> false
;;

let with_admin_mutation (t : R.t) request f =
  match R.acting_reading t request with
  | Error answer -> answer
  | Ok ({ Authz_browser_session.user_id = admin; _ }, state) ->
    if is_acting_admin state admin
    then f ~admin ~state
    else refused R.Forbidden_403 "only an active Admin may manage members"
;;

let with_target_user_id user_id f =
  match Authz_types.User_id.of_string user_id with
  | Error error ->
    refused R.Bad_request_400 ("the user id is refused: " ^ Authz_id.error_to_string error)
  | Ok target_id -> f target_id
;;

let commit_record (t : R.t) ~admin ~kind ~body_result ~on_ok =
  match body_result with
  | Error error ->
    refused
      R.Internal_error_500
      ("the member lifecycle body was not built: " ^ Authz_body.error_to_string error)
  | Ok body ->
    let draft =
      { Authz_zone.author = Authz_records.Author.Authenticated (Authz_types.Principal.Human admin)
      ; kind
      ; body
      }
    in
    (match Authz_zone.commit t.R.zone draft with
     | Error error -> commit_failed error
     | Ok (_ : Authz_zone.committed) -> on_ok ())
;;

let disable (t : R.t) request ~user_id =
  with_admin_mutation t request (fun ~admin ~state:(_ : S.t) ->
    with_target_user_id user_id (fun target_id ->
      commit_record
        t
        ~admin
        ~kind:Authz_record.Kind.Principal
        ~body_result:(Authz_principal_event.to_body (Authz_principal_event.Disabled { user_id = target_id }))
        ~on_ok:(fun () ->
          R.json
            R.Ok_200
            [ "user_id", `String (Authz_types.User_id.to_string target_id)
            ; "status", `String (status_name P.Disabled)
            ])))
;;

let enable (t : R.t) request ~user_id =
  with_admin_mutation t request (fun ~admin ~state:(_ : S.t) ->
    with_target_user_id user_id (fun target_id ->
      commit_record
        t
        ~admin
        ~kind:Authz_record.Kind.Principal
        ~body_result:(Authz_principal_event.to_body (Authz_principal_event.Enabled { user_id = target_id }))
        ~on_ok:(fun () ->
          R.json
            R.Ok_200
            [ "user_id", `String (Authz_types.User_id.to_string target_id)
            ; "status", `String (status_name P.Active)
            ])))
;;

let revoke_admin (t : R.t) request ~user_id ~body =
  with_admin_mutation t request (fun ~admin ~state:(_ : S.t) ->
    with_target_user_id user_id (fun target_id ->
      match cause_of_body body with
      | Error text -> refused R.Bad_request_400 text
      | Ok cause ->
        commit_record
          t
          ~admin
          ~kind:Authz_record.Kind.Admin_assignment
          ~body_result:
            (Authz_admin_event.to_body (Authz_admin_event.Revoked { user_id = target_id; cause }))
          ~on_ok:(fun () ->
            R.json
              R.Ok_200
              [ "user_id", `String (Authz_types.User_id.to_string target_id)
              ; "role", `String (Authz_invite_event.role_label Authz_invite_event.Member)
              ; "cause", `String (Authz_admin_event.cause_label cause)
              ])))
;;

let delete (t : R.t) request ~user_id =
  with_admin_mutation t request (fun ~admin ~state ->
    with_target_user_id user_id (fun target_id ->
      match P.find state.S.principals target_id with
      | None ->
        refused
          R.Not_found_404
          (Printf.sprintf "principal %s is not found" (Authz_types.User_id.to_string target_id))
      | Some (principal : P.principal) ->
        commit_record
          t
          ~admin
          ~kind:Authz_record.Kind.Principal
          ~body_result:
            (Authz_principal_event.to_body
               (Authz_principal_event.Deleted
                  { user_id = target_id; identity = principal.identity }))
          ~on_ok:(fun () ->
            { R.status = R.No_content_204; headers = [ "cache-control", "no-store" ]; body = "" })))
;;
