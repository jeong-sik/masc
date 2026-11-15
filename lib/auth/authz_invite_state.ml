(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module E = Authz_invite_event
module Invite_map = Map.Make (Invite_id)
module Digest_map = Map.Make (String)

type status =
  | Open
  | Revoked
  | Consumed of User_id.t

type issuer =
  | Local_operator_issued
  | Admin_issued of User_id.t

type invitation =
  { token_digest : E.Token_digest.t
  ; expires_at_ms : int
  ; role : E.role
  ; issuer : issuer
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
let bindings t = Invite_map.bindings t.by_id

let find_by_token_digest t digest =
  match Digest_map.find_opt (E.Token_digest.to_hex digest) t.by_digest with
  | None -> None
  | Some invite_id ->
    (match find t invite_id with
     | Some invitation -> Some (invite_id, invitation)
     | None -> None)
;;

let find_consumed_by t user_id =
  Seq.find
    (fun ((_ : Invite_id.t), invitation) ->
      match invitation.status with
      | Consumed spender -> User_id.equal spender user_id
      | Open | Revoked -> false)
    (Invite_map.to_seq t.by_id)
;;

type refusal =
  | Already_issued of Invite_id.t
  | Token_digest_taken of Invite_id.t
  | Not_issued of Invite_id.t
  | Already_revoked of Invite_id.t
  | Already_consumed of Invite_id.t
  | Local_operator_invites_only_admins
  | Author_is_not_an_admin of Principal.t
  | Not_an_invite_author of Author.t

let refusal_to_string = function
  | Already_issued id -> Printf.sprintf "the invitation %s was issued before" (Invite_id.to_string id)
  | Token_digest_taken id ->
    Printf.sprintf
      "the invitation %s already has the same token digest"
      (Invite_id.to_string id)
  | Not_issued id -> Printf.sprintf "no invitation %s was issued" (Invite_id.to_string id)
  | Already_revoked id ->
    Printf.sprintf "the invitation %s was revoked before" (Invite_id.to_string id)
  | Already_consumed id ->
    Printf.sprintf "the invitation %s was spent by an admission" (Invite_id.to_string id)
  | Local_operator_invites_only_admins -> "the local operator invites only Admins"
  | Author_is_not_an_admin principal ->
    Printf.sprintf
      "the principal %s is not an Admin, and only an Admin writes invitations"
      (Principal.to_string principal)
  | Not_an_invite_author author -> Author.label author ^ " does not write invitations"
;;

let issue t ~issuer ~invite_id ~token_digest ~expires_at_ms ~role =
  let digest_key = E.Token_digest.to_hex token_digest in
  match Invite_map.mem invite_id t.by_id, Digest_map.find_opt digest_key t.by_digest with
  | true, (None | Some _) -> Error (Already_issued invite_id)
  | false, Some holder -> Error (Token_digest_taken holder)
  | false, None ->
    Ok
      { by_id = Invite_map.add invite_id { token_digest; expires_at_ms; role; issuer; status = Open } t.by_id
      ; by_digest = Digest_map.add digest_key invite_id t.by_digest
      }
;;

let revoke t ~invite_id =
  match find t invite_id with
  | None -> Error (Not_issued invite_id)
  | Some { status = Revoked; _ } -> Error (Already_revoked invite_id)
  | Some { status = Consumed _; _ } -> Error (Already_consumed invite_id)
  | Some ({ status = Open; _ } as invitation) ->
    Ok { t with by_id = Invite_map.add invite_id { invitation with status = Revoked } t.by_id }
;;

type consume_refusal =
  | Invitation_not_issued of Invite_id.t
  | Invitation_revoked of Invite_id.t
  | Invitation_consumed of Invite_id.t
  | Invitation_expired of
      { invite_id : Invite_id.t
      ; expires_at_ms : int
      ; at_ms : int
      }

let consume_refusal_to_string = function
  | Invitation_not_issued id -> Printf.sprintf "no invitation %s was issued" (Invite_id.to_string id)
  | Invitation_revoked id -> Printf.sprintf "the invitation %s was revoked" (Invite_id.to_string id)
  | Invitation_consumed id ->
    Printf.sprintf "the invitation %s was spent by an admission before" (Invite_id.to_string id)
  | Invitation_expired { invite_id; expires_at_ms; at_ms } ->
    Printf.sprintf
      "the invitation %s expired at %d, and the admission is at %d"
      (Invite_id.to_string invite_id)
      expires_at_ms
      at_ms
;;

let consume t invite_id ~user_id ~at_ms =
  match find t invite_id with
  | None -> Error (Invitation_not_issued invite_id)
  | Some { status = Revoked; _ } -> Error (Invitation_revoked invite_id)
  | Some { status = Consumed _; _ } -> Error (Invitation_consumed invite_id)
  | Some { status = Open; expires_at_ms; _ } when at_ms >= expires_at_ms ->
    Error (Invitation_expired { invite_id; expires_at_ms; at_ms })
  | Some ({ status = Open; role; _ } as invitation) ->
    Ok
      ( { t with
          by_id = Invite_map.add invite_id { invitation with status = Consumed user_id } t.by_id
        }
      , role )
;;

(* The author is matched before the event, so a branch says what each author
   may write. *)
let apply t ~(author : Author.t) ~is_admin (event : E.t) =
  match author, event with
  | Author.Local_operator, E.Issued { invite_id; token_digest; expires_at_ms; role = E.Admin } ->
    issue t ~issuer:Local_operator_issued ~invite_id ~token_digest ~expires_at_ms ~role:E.Admin
  | Author.Local_operator, E.Issued { role = E.Member; _ } ->
    Error Local_operator_invites_only_admins
  | Author.Local_operator, E.Revoked { invite_id } -> revoke t ~invite_id
  | Author.Authenticated (Principal.Human id), E.Issued { invite_id; token_digest; expires_at_ms; role }
    when is_admin id -> issue t ~issuer:(Admin_issued id) ~invite_id ~token_digest ~expires_at_ms ~role
  | Author.Authenticated (Principal.Human id), E.Revoked { invite_id } when is_admin id ->
    revoke t ~invite_id
  | Author.Authenticated ((Principal.Human _ | Principal.Service _) as principal), (E.Issued _ | E.Revoked _)
    -> Error (Author_is_not_an_admin principal)
  | ( (Author.System_cron | Author.System_maintenance | Author.System_migration)
    , (E.Issued _ | E.Revoked _) ) -> Error (Not_an_invite_author author)
;;
