(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
module Digest = Authz_credential_token.Service_credential.Digest

let ( let* ) = Result.bind

type t =
  | Issued of
      { credential_id : Service_credential_id.t
      ; service_id : Service_id.t
      ; secret_digest : Digest.t
      }
  | Revoked of { credential_id : Service_credential_id.t }

let credential_id = function
  | Issued { credential_id; _ } | Revoked { credential_id } -> credential_id
;;

let equal a b =
  match a, b with
  | Issued a, Issued b ->
    Service_credential_id.equal a.credential_id b.credential_id
    && Service_id.equal a.service_id b.service_id
    && Digest.equal a.secret_digest b.secret_digest
  | Revoked a, Revoked b -> Service_credential_id.equal a.credential_id b.credential_id
  | Issued _, Revoked _ | Revoked _, Issued _ -> false
;;

let issued_label = "issued"
let revoked_label = "revoked"

let to_body = function
  | Issued { credential_id; service_id; secret_digest } ->
    let* event = Authz_body.string issued_label in
    let* credential_id = Authz_body.string (Service_credential_id.to_string credential_id) in
    let* service_id = Authz_body.string (Service_id.to_string service_id) in
    let* secret_digest = Authz_body.string (Digest.to_hex secret_digest) in
    Authz_body.object_
      [ "event", event
      ; "credential_id", credential_id
      ; "service_id", service_id
      ; "secret_digest", secret_digest
      ]
  | Revoked { credential_id } ->
    let* event = Authz_body.string revoked_label in
    let* credential_id = Authz_body.string (Service_credential_id.to_string credential_id) in
    Authz_body.object_ [ "event", event; "credential_id", credential_id ]
;;

type error =
  | Not_an_object
  | Unknown_event of string
  | Wrong_members
  | Invalid_credential_id of Authz_id.error
  | Invalid_service_id of Authz_id.error
  | Invalid_secret_digest

let error_to_string = function
  | Not_an_object -> "the body of a Service credential record is an object"
  | Unknown_event label -> Printf.sprintf "%S is not an event of a Service credential" label
  | Wrong_members ->
    "the body of an issued Service credential has the members event, credential_id, \
     service_id, and secret_digest, and that of a revoked one event and credential_id, in \
     this order, all strings"
  | Invalid_credential_id error ->
    "the credential id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_service_id error -> "the service id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_secret_digest -> "the secret digest is not 64 lowercase hex characters"
;;

let credential_id_of text =
  Result.map_error
    (fun error -> Invalid_credential_id error)
    (Service_credential_id.of_string text)
;;

let issued_of ~credential_id ~service_id ~secret_digest =
  let* credential_id = credential_id_of credential_id in
  let* service_id =
    Result.map_error (fun error -> Invalid_service_id error) (Service_id.of_string service_id)
  in
  let* secret_digest =
    Option.to_result ~none:Invalid_secret_digest (Digest.of_hex secret_digest)
  in
  Ok (Issued { credential_id; service_id; secret_digest })
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object (("event", Authz_body.String event) :: members) ->
    if String.equal event issued_label
    then (
      match members with
      | [ ("credential_id", credential_id)
        ; ("service_id", service_id)
        ; ("secret_digest", secret_digest)
        ] ->
        (match
           ( Authz_body.string_value credential_id
           , Authz_body.string_value service_id
           , Authz_body.string_value secret_digest )
         with
         | Some credential_id, Some service_id, Some secret_digest ->
           issued_of ~credential_id ~service_id ~secret_digest
         | (None | Some _), (None | Some _), (None | Some _) -> Error Wrong_members)
      | _ -> Error Wrong_members)
    else if String.equal event revoked_label
    then (
      match members with
      | [ ("credential_id", credential_id) ] ->
        (match Authz_body.string_value credential_id with
         | Some credential_id ->
           let* credential_id = credential_id_of credential_id in
           Ok (Revoked { credential_id })
         | None -> Error Wrong_members)
      | _ -> Error Wrong_members)
    else Error (Unknown_event event)
  | Authz_body.Object _ -> Error Wrong_members
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> Error Not_an_object
;;
