(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module E = Authz_invite_event

let ( let* ) = Result.bind

type issued =
  { invite_id : Invite_id.t
  ; token : string
  ; expires_at_ms : int
  ; role : E.role
  }

type error =
  | Id_not_drawn of Authz_id.error
  | Body_not_built of Authz_body.error
  | Commit_failed of Authz_zone.error

let error_to_string = function
  | Id_not_drawn error -> "a drawn id was refused: " ^ Authz_id.error_to_string error
  | Body_not_built error -> "the invitation body was not built: " ^ Authz_body.error_to_string error
  | Commit_failed error -> Authz_zone.error_to_string error
;;

let lifetime_ms = Authz_activation.admin_invitation_lifetime_ms
let attempts = 3

let commit zone ~admin event =
  let* body = Result.map_error (fun error -> Body_not_built error) (E.to_body event) in
  let draft =
    { Authz_zone.author = Author.Authenticated (Principal.Human admin)
    ; kind = Authz_record.Kind.Invite
    ; body
    }
  in
  Result.map_error (fun error -> Commit_failed error) (Authz_zone.commit zone draft)
;;

(* An id that the snapshot already names is drawn again. On the last attempt
   it goes to the zone all the same, which refuses it as issued. *)
let issue zone ~admin ~draw ~now_ms role =
  let rec go left =
    let* invite_id =
      Result.map_error (fun error -> Id_not_drawn error) (Invite_id.of_string (draw ()))
    in
    let invites = (Authz_zone.snapshot zone).state.invites in
    match Authz_invite_state.find invites invite_id with
    | Some (_ : Authz_invite_state.invitation) when left > 1 -> go (left - 1)
    | Some (_ : Authz_invite_state.invitation) | None ->
      let token = draw () in
      let expires_at_ms = now_ms () + lifetime_ms in
      let* (_ : Authz_zone.committed) =
        commit
          zone
          ~admin
          (E.Issued { invite_id; token_digest = E.Token_digest.of_token token; expires_at_ms; role })
      in
      Ok { invite_id; token; expires_at_ms; role }
  in
  go attempts
;;

let revoke zone ~admin invite_id =
  Result.map (fun (_ : Authz_zone.committed) -> ()) (commit zone ~admin (E.Revoked { invite_id }))
;;
