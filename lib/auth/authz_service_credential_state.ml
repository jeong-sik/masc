(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module E = Authz_service_credential_event
module Credential_map = Map.Make (Service_credential_id)

type status =
  | Open
  | Revoked

type credential =
  { service_id : Service_id.t
  ; secret_digest : Authz_credential_token.Service_credential.Digest.t
  ; issued_at_ms : int
  ; status : status
  }

type t = credential Credential_map.t

let empty = Credential_map.empty
let find t credential_id = Credential_map.find_opt credential_id t

type inactive =
  | Unknown
  | Ended

let find_active t credential_id =
  match find t credential_id with
  | None -> Error Unknown
  | Some { status = Revoked; _ } -> Error Ended
  | Some ({ status = Open; _ } as credential) -> Ok credential
;;

type refusal =
  | Already_issued of Service_credential_id.t
  | Not_issued of Service_credential_id.t
  | Already_revoked of Service_credential_id.t
  | Not_a_credential_author of Author.t

let author_label : Author.t -> string = function
  | Author.Authenticated principal -> "the principal " ^ Principal.to_string principal
  | Author.Local_operator -> "the local operator"
  | Author.System_cron -> "the system cron"
  | Author.System_maintenance -> "the system maintenance"
  | Author.System_migration -> "the system migration"
;;

let refusal_to_string = function
  | Already_issued id ->
    Printf.sprintf "the Service credential %s was issued before" (Service_credential_id.to_string id)
  | Not_issued id ->
    Printf.sprintf "no Service credential %s was issued" (Service_credential_id.to_string id)
  | Already_revoked id ->
    Printf.sprintf "the Service credential %s was revoked before" (Service_credential_id.to_string id)
  | Not_a_credential_author author ->
    author_label author ^ " writes no Service credential; the local operator does"
;;

let issue t ~at_ms ~credential_id ~service_id ~secret_digest =
  if Credential_map.mem credential_id t
  then Error (Already_issued credential_id)
  else
    Ok
      (Credential_map.add
         credential_id
         { service_id; secret_digest; issued_at_ms = at_ms; status = Open }
         t)
;;

let revoke t ~credential_id =
  match find t credential_id with
  | None -> Error (Not_issued credential_id)
  | Some { status = Revoked; _ } -> Error (Already_revoked credential_id)
  | Some ({ status = Open; _ } as credential) ->
    Ok (Credential_map.add credential_id { credential with status = Revoked } t)
;;

let apply t ~(author : Author.t) ~at_ms (event : E.t) =
  match author, event with
  | Author.Local_operator, E.Issued { credential_id; service_id; secret_digest } ->
    issue t ~at_ms ~credential_id ~service_id ~secret_digest
  | Author.Local_operator, E.Revoked { credential_id } -> revoke t ~credential_id
  | ( ( Author.Authenticated _
      | Author.System_cron
      | Author.System_maintenance
      | Author.System_migration )
    , (E.Issued _ | E.Revoked _) ) -> Error (Not_a_credential_author author)
;;
