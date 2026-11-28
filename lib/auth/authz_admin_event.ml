(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types

let ( let* ) = Result.bind

type cause =
  | Security_incident
  | Operational

let causes = [ Security_incident; Operational ]

let cause_label = function
  | Security_incident -> "security_incident"
  | Operational -> "operational"
;;

let cause_of_label label = List.find_opt (fun cause -> String.equal (cause_label cause) label) causes

type t =
  | Granted of { user_id : User_id.t }
  | Revoked of
      { user_id : User_id.t
      ; cause : cause
      }

let equal a b =
  match a, b with
  | Granted a, Granted b -> User_id.equal a.user_id b.user_id
  | Revoked a, Revoked b ->
    User_id.equal a.user_id b.user_id
    &&
    (match a.cause, b.cause with
     | Security_incident, Security_incident | Operational, Operational -> true
     | Security_incident, Operational | Operational, Security_incident -> false)
  | Granted _, Revoked _ | Revoked _, Granted _ -> false
;;

let granted_label = "granted"
let revoked_label = "revoked"

let to_body = function
  | Granted { user_id } ->
    let* event = Authz_body.string granted_label in
    let* user_id = Authz_body.string (User_id.to_string user_id) in
    Authz_body.object_ [ "event", event; "user_id", user_id ]
  | Revoked { user_id; cause } ->
    let* event = Authz_body.string revoked_label in
    let* user_id = Authz_body.string (User_id.to_string user_id) in
    let* cause = Authz_body.string (cause_label cause) in
    Authz_body.object_ [ "event", event; "user_id", user_id; "cause", cause ]
;;

type error =
  | Not_an_object
  | Unknown_event of string
  | Wrong_members
  | Invalid_user_id of Authz_id.error
  | Unknown_cause of string

let error_to_string = function
  | Not_an_object -> "the body of an Admin assignment record is an object"
  | Unknown_event label -> Printf.sprintf "%S is not an event of an Admin assignment" label
  | Wrong_members ->
    "a grant of an Admin assignment has the members event and user_id, and a revocation \
     the members event, user_id, and cause, all strings, in this order"
  | Invalid_user_id error -> Printf.sprintf "the user id is not valid: %s" (Authz_id.error_to_string error)
  | Unknown_cause label -> Printf.sprintf "%S is not a cause of a revocation" label
;;

(* The user id is read before the cause, so a body with both wrong names the
   user id. *)
let revoked_of ~user_id ~cause =
  let* user_id = Result.map_error (fun error -> Invalid_user_id error) (User_id.of_string user_id) in
  let* cause =
    match cause_of_label cause with
    | Some cause -> Ok cause
    | None -> Error (Unknown_cause cause)
  in
  Ok (Revoked { user_id; cause })
;;

let granted_of ~user_id =
  Result.map
    (fun user_id -> Granted { user_id })
    (Result.map_error (fun error -> Invalid_user_id error) (User_id.of_string user_id))
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object (("event", Authz_body.String event) :: members) ->
    if String.equal event granted_label
    then (
      match members with
      | [ ("user_id", user_id) ] ->
        (match Authz_body.string_value user_id with
         | Some user_id -> granted_of ~user_id
         | None -> Error Wrong_members)
      | _ -> Error Wrong_members)
    else if String.equal event revoked_label
    then (
      match members with
      | [ ("user_id", user_id); ("cause", cause) ] ->
        (match Authz_body.string_value user_id, Authz_body.string_value cause with
         | Some user_id, Some cause -> revoked_of ~user_id ~cause
         | (None | Some _), (None | Some _) -> Error Wrong_members)
      | _ -> Error Wrong_members)
    else Error (Unknown_event event)
  | Authz_body.Object _ -> Error Wrong_members
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> Error Not_an_object
;;
