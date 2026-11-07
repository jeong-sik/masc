(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module Token = Authz_credential_token.Service_credential

let ( let* ) = Result.bind

type error =
  | Id_not_drawn of Authz_id.error
  | Body_not_built of Authz_body.error
  | Commit_failed of Authz_zone.error

let error_to_string = function
  | Id_not_drawn error -> "a drawn credential id was refused: " ^ Authz_id.error_to_string error
  | Body_not_built error ->
    "the Service credential body was not built: " ^ Authz_body.error_to_string error
  | Commit_failed error -> Authz_zone.error_to_string error
;;

let attempts = 3

let commit zone event =
  let* body =
    Result.map_error
      (fun error -> Body_not_built error)
      (Authz_service_credential_event.to_body event)
  in
  let draft =
    { Authz_zone.author = Author.Local_operator
    ; kind = Authz_record.Kind.Internal_service_credential
    ; body
    }
  in
  Result.map_error (fun error -> Commit_failed error) (Authz_zone.commit zone draft)
;;

(* An id that the snapshot already names is drawn again. On the last attempt
   it goes to the zone all the same, which refuses it as issued before. *)
let issue zone ~service_id ~draw =
  let rec go left =
    let* credential_id =
      Result.map_error (fun error -> Id_not_drawn error) (Service_credential_id.of_string (draw ()))
    in
    match
      Authz_service_credential_state.find
        (Authz_zone.snapshot zone).state.service_credentials
        credential_id
    with
    | Some (_ : Authz_service_credential_state.credential) when left > 1 -> go (left - 1)
    | Some (_ : Authz_service_credential_state.credential) | None ->
      let token = Token.draw credential_id in
      let secret_digest = Token.secret_digest token in
      let* (_ : Authz_zone.committed) =
        commit
          zone
          (Authz_service_credential_event.Issued { credential_id; service_id; secret_digest })
      in
      Ok token
  in
  go attempts
;;

type signed_in =
  { service_id : Service_id.t
  ; credential_id : Service_credential_id.t
  }

type refusal =
  | Unknown
  | Ended
  | Secret_differs
  | Revocation_pending

let refusal_to_string = function
  | Unknown -> "no Service credential has the id of the token"
  | Ended -> "the Service credential of the token was revoked"
  | Secret_differs -> "the token does not carry the secret of its Service credential"
  | Revocation_pending ->
    "a revocation of the Service credential of the token was given up before it reached the log"
;;

let authenticate (state : Authz_state.t) token =
  let credential_id = Token.id token in
  match Authz_service_credential_state.find_active state.service_credentials credential_id with
  | Error Authz_service_credential_state.Unknown -> Error Unknown
  | Error Authz_service_credential_state.Ended -> Error Ended
  | Ok { Authz_service_credential_state.service_id; secret_digest; issued_at_ms = _; status = _ } ->
    if not (Token.Digest.equal secret_digest (Token.secret_digest token))
    then Error Secret_differs
    else (
      match Authz_state.revocation state (Subject.Service_credential credential_id) with
      | Revocation_state.Pending -> Error Revocation_pending
      | Revocation_state.Not_pending -> Ok { service_id; credential_id })
;;

let revoke zone credential_id =
  Result.map
    (fun (_ : Authz_zone.committed) -> ())
    (commit zone (Authz_service_credential_event.Revoked { credential_id }))
;;
