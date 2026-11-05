(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module E = Authz_invite_event
module Invite_map = Map.Make (Invite_id)
module Digest_map = Map.Make (String)

type status =
  | Open
  | Revoked

type invitation =
  { token_digest : E.Token_digest.t
  ; expires_at_ms : int
  ; role : E.role
  ; status : status
  }

(* [by_digest] names, for each token digest, the invitation that has it. The two
   maps change together in [apply] and nowhere else. *)
type t =
  { by_id : invitation Invite_map.t
  ; by_digest : Invite_id.t Digest_map.t
  }

let empty = { by_id = Invite_map.empty; by_digest = Digest_map.empty }
let find t invite_id = Invite_map.find_opt invite_id t.by_id

let find_by_token_digest t digest =
  match Digest_map.find_opt (E.Token_digest.to_hex digest) t.by_digest with
  | None -> None
  | Some invite_id ->
    (match find t invite_id with
     | Some invitation -> Some (invite_id, invitation)
     | None -> None)
;;

type refusal =
  | Already_issued of Invite_id.t
  | Token_digest_taken of Invite_id.t
  | Not_issued of Invite_id.t
  | Already_revoked of Invite_id.t
  | Local_operator_invites_only_admins
  | Authenticated_author_not_read of Principal.t
  | Not_an_invite_author of Author.t

let author_label : Author.t -> string = function
  | Author.Authenticated principal -> "the principal " ^ Principal.to_string principal
  | Author.Local_operator -> "the local operator"
  | Author.System_cron -> "the system cron"
  | Author.System_maintenance -> "the system maintenance"
  | Author.System_migration -> "the system migration"
;;

let refusal_to_string = function
  | Already_issued id -> Printf.sprintf "the invitation %s was issued before" (Invite_id.to_string id)
  | Token_digest_taken id ->
    Printf.sprintf
      "the invitation %s already has the same token digest"
      (Invite_id.to_string id)
  | Not_issued id -> Printf.sprintf "no invitation %s was issued" (Invite_id.to_string id)
  | Already_revoked id ->
    Printf.sprintf "the invitation %s was revoked before" (Invite_id.to_string id)
  | Local_operator_invites_only_admins -> "the local operator invites only Admins"
  | Authenticated_author_not_read principal ->
    Printf.sprintf
      "no layer of this server reads whether the principal %s may write invitations"
      (Principal.to_string principal)
  | Not_an_invite_author author -> author_label author ^ " does not write invitations"
;;

let issue t ~invite_id ~token_digest ~expires_at_ms ~role =
  let digest_key = E.Token_digest.to_hex token_digest in
  match Invite_map.mem invite_id t.by_id, Digest_map.find_opt digest_key t.by_digest with
  | true, (None | Some _) -> Error (Already_issued invite_id)
  | false, Some holder -> Error (Token_digest_taken holder)
  | false, None ->
    Ok
      { by_id = Invite_map.add invite_id { token_digest; expires_at_ms; role; status = Open } t.by_id
      ; by_digest = Digest_map.add digest_key invite_id t.by_digest
      }
;;

let revoke t ~invite_id =
  match find t invite_id with
  | None -> Error (Not_issued invite_id)
  | Some { status = Revoked; _ } -> Error (Already_revoked invite_id)
  | Some ({ status = Open; _ } as invitation) ->
    Ok { t with by_id = Invite_map.add invite_id { invitation with status = Revoked } t.by_id }
;;

(* The author is matched before the event, so a branch says what each author
   may write, and the layer that reads the Admins changes only the branch of an
   authenticated principal. *)
let apply t ~(author : Author.t) (event : E.t) =
  match author, event with
  | Author.Local_operator, E.Issued { invite_id; token_digest; expires_at_ms; role = E.Admin } ->
    issue t ~invite_id ~token_digest ~expires_at_ms ~role:E.Admin
  | Author.Local_operator, E.Issued { role = E.Member; _ } ->
    Error Local_operator_invites_only_admins
  | Author.Local_operator, E.Revoked { invite_id } -> revoke t ~invite_id
  | Author.Authenticated principal, (E.Issued _ | E.Revoked _) ->
    Error (Authenticated_author_not_read principal)
  | ( (Author.System_cron | Author.System_maintenance | Author.System_migration)
    , (E.Issued _ | E.Revoked _) ) -> Error (Not_an_invite_author author)
;;
