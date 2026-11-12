(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module Token = Authz_credential_token.Pat

let ( let* ) = Result.bind

type error =
  | Id_not_drawn of Authz_id.error
  | Body_not_built of Authz_body.error
  | Commit_failed of Authz_zone.error

let error_to_string = function
  | Id_not_drawn error -> "a drawn PAT id was refused: " ^ Authz_id.error_to_string error
  | Body_not_built error -> "the PAT body was not built: " ^ Authz_body.error_to_string error
  | Commit_failed error -> Authz_zone.error_to_string error
;;

let attempts = 3

let commit zone ~user_id event =
  let* body = Result.map_error (fun error -> Body_not_built error) (Authz_pat_event.to_body event) in
  let draft =
    { Authz_zone.author = Author.Authenticated (Principal.Human user_id)
    ; kind = Authz_record.Kind.Pat
    ; body
    }
  in
  Result.map_error (fun error -> Commit_failed error) (Authz_zone.commit zone draft)
;;

(* An id that the snapshot already names is drawn again. On the last attempt
   it goes to the zone all the same, which refuses it as issued before. *)
let issue zone ~user_id ~draw ~scope ~expires_at_ms =
  let rec go left =
    let* pat_id = Result.map_error (fun error -> Id_not_drawn error) (Pat_id.of_string (draw ())) in
    match Authz_pat_state.find (Authz_zone.snapshot zone).state.pats pat_id with
    | Some (_ : Authz_pat_state.pat) when left > 1 -> go (left - 1)
    | Some (_ : Authz_pat_state.pat) | None ->
      let token = Token.draw pat_id in
      let secret_digest = Token.secret_digest token in
      let* (_ : Authz_zone.committed) =
        commit
          zone
          ~user_id
          (Authz_pat_event.Issued { pat_id; user_id; secret_digest; scope; expires_at_ms })
      in
      Ok token
  in
  go attempts
;;

type signed_in =
  { user_id : User_id.t
  ; pat_id : Pat_id.t
  ; pat_scope : Pat_scope.t
  }

type refusal =
  | Unknown
  | Ended
  | Expired
  | Secret_differs
  | Revocation_pending
  | Principal_inactive of User_id.t
  | Principal_revocation_pending of User_id.t

let refusal_to_string = function
  | Unknown -> "no PAT has the id of the token"
  | Ended -> "the PAT of the token was revoked"
  | Expired -> "the PAT of the token has expired"
  | Secret_differs -> "the token does not carry the secret of its PAT"
  | Revocation_pending ->
    "a revocation of the PAT of the token was given up before it reached the log"
  | Principal_inactive user_id ->
    Printf.sprintf "the principal %s of the PAT is disabled or deleted" (User_id.to_string user_id)
  | Principal_revocation_pending user_id ->
    Printf.sprintf
      "a revocation of the principal %s of the PAT was given up before it reached the log"
      (User_id.to_string user_id)
;;

let ms_per_second = 1000.

let authenticate (trusted : Authz_zone.trusted) ~now_ms token =
  let state = (trusted :> Authz_zone.snapshot).state in
  let pat_id = Token.id token in
  match Authz_pat_state.find_active state.pats pat_id ~now_ms with
  | Error Authz_pat_state.Unknown -> Error Unknown
  | Error Authz_pat_state.Ended -> Error Ended
  | Error Authz_pat_state.Expired -> Error Expired
  | Ok { Authz_pat_state.user_id; secret_digest; scope; expires_at_ms; issued_at_ms = _; status = _ }
    ->
    if not (Token.Digest.equal secret_digest (Token.secret_digest token))
    then Error Secret_differs
    else (
      match Authz_state.revocation state (Subject.Pat pat_id) with
      | Revocation_state.Pending -> Error Revocation_pending
      | Revocation_state.Not_pending ->
        if not (Authz_principal_state.is_active state.principals user_id)
        then Error (Principal_inactive user_id)
        else (
          match Authz_state.revocation state (Subject.Principal (Principal.Human user_id)) with
          | Revocation_state.Pending -> Error (Principal_revocation_pending user_id)
          | Revocation_state.Not_pending ->
            let expires_at =
              Option.map (fun at_ms -> Float.of_int at_ms /. ms_per_second) expires_at_ms
            in
            Ok { user_id; pat_id; pat_scope = { Pat_scope.scope; expires_at } }))
;;

let revoke zone ~user_id pat_id =
  Result.map
    (fun (_ : Authz_zone.committed) -> ())
    (commit zone ~user_id (Authz_pat_event.Revoked { pat_id }))
;;
