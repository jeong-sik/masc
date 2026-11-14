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

let held state user_id =
  match S.revocation state (Authz_records.Subject.Principal (Authz_types.Principal.Human user_id)) with
  | Authz_records.Revocation_state.Pending -> true
  | Authz_records.Revocation_state.Not_pending -> false
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
          ; "revocation_pending", `Bool (held state user_id)
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
