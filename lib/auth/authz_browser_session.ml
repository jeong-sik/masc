(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records

let ( let* ) = Result.bind
let secret_bytes = 32
let secret_length = 2 * secret_bytes

let is_lower_hex = function
  | '0' .. '9' | 'a' .. 'f' -> true
  | _ -> false
;;

module Cookie = struct
  type t =
    { session_id : Session_id.t
    ; secret : string
    }

  let session_id t = t.session_id
  let to_value t = Session_id.to_string t.session_id ^ "." ^ t.secret

  let of_value value =
    let length = String.length value in
    (* At least one byte of id, the dot, and the secret. *)
    if length < secret_length + 2 || not (Char.equal value.[length - secret_length - 1] '.')
    then None
    else (
      let secret = String.sub value (length - secret_length) secret_length in
      if not (String.for_all is_lower_hex secret)
      then None
      else (
        match Session_id.of_string (String.sub value 0 (length - secret_length - 1)) with
        | Ok session_id -> Some { session_id; secret }
        | Error (_ : Authz_id.error) -> None))
  ;;
end

(* Keeps the token from being the digest of the secret in the log, or of any
   other protocol's text. *)
let csrf_domain = "masc-authz-browser-session-csrf-v1\n"

let csrf_token (cookie : Cookie.t) =
  Agent_core_sha256.to_hex (Agent_core_sha256.digest_string (csrf_domain ^ cookie.Cookie.secret))
;;

let csrf_matches cookie token = Eqaf.equal (csrf_token cookie) token

type error =
  | Id_not_drawn of Authz_id.error
  | Body_not_built of Authz_body.error
  | Commit_failed of Authz_zone.error

let error_to_string = function
  | Id_not_drawn error -> "a drawn session id was refused: " ^ Authz_id.error_to_string error
  | Body_not_built error -> "the session body was not built: " ^ Authz_body.error_to_string error
  | Commit_failed error -> Authz_zone.error_to_string error
;;

let attempts = 3

let commit zone ~user_id event =
  let* body = Result.map_error (fun error -> Body_not_built error) (Authz_session_event.to_body event) in
  let draft =
    { Authz_zone.author = Author.Authenticated (Principal.Human user_id)
    ; kind = Authz_record.Kind.Session
    ; body
    }
  in
  Result.map_error (fun error -> Commit_failed error) (Authz_zone.commit zone draft)
;;

(* An id that the snapshot already names is drawn again. On the last attempt
   it goes to the zone all the same, which refuses it as issued before. *)
let issue zone ~user_id ~draw ~replaces =
  let rec go left =
    let* session_id = Result.map_error (fun error -> Id_not_drawn error) (Session_id.of_string (draw ())) in
    let sessions = (Authz_zone.snapshot zone).state.sessions in
    match Authz_session_state.find sessions session_id with
    | Some (_ : Authz_session_state.session) when left > 1 -> go (left - 1)
    | Some (_ : Authz_session_state.session) | None ->
      let secret = Random_id.hex ~bytes:secret_bytes in
      let secret_digest = Authz_session_event.Secret_digest.of_secret secret in
      let* (_ : Authz_zone.committed) =
        commit zone ~user_id (Authz_session_event.Issued { session_id; user_id; secret_digest; replaces })
      in
      Ok { Cookie.session_id; secret }
  in
  go attempts
;;

type signed_in =
  { user_id : User_id.t
  ; session_id : Session_id.t
  ; expires_at_ms : int
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
  | Unknown -> "no session has the id of the cookie"
  | Ended -> "the session of the cookie was signed out or replaced"
  | Expired -> "the session of the cookie has expired"
  | Secret_differs -> "the cookie does not carry the secret of its session"
  | Revocation_pending ->
    "a revocation of the session of the cookie was given up before it reached the log"
  | Principal_inactive user_id ->
    Printf.sprintf "the principal %s of the session is disabled or deleted" (User_id.to_string user_id)
  | Principal_revocation_pending user_id ->
    Printf.sprintf
      "a revocation of the principal %s of the session was given up before it reached the log"
      (User_id.to_string user_id)
;;

let authenticate (trusted : Authz_zone.trusted) ~now_ms (cookie : Cookie.t) =
  let state = (trusted :> Authz_zone.snapshot).state in
  match Authz_session_state.find_active state.sessions cookie.Cookie.session_id ~now_ms with
  | Error Authz_session_state.Unknown -> Error Unknown
  | Error Authz_session_state.Ended -> Error Ended
  | Error Authz_session_state.Expired -> Error Expired
  | Ok { Authz_session_state.user_id; secret_digest; issued_at_ms; status = _ } ->
    if
      not
        (Authz_session_event.Secret_digest.equal
           secret_digest
           (Authz_session_event.Secret_digest.of_secret cookie.Cookie.secret))
    then Error Secret_differs
    else (
      match Authz_state.revocation state (Subject.Session cookie.Cookie.session_id) with
      | Revocation_state.Pending -> Error Revocation_pending
      | Revocation_state.Not_pending ->
        if not (Authz_principal_state.is_active state.principals user_id)
        then Error (Principal_inactive user_id)
        else (
          match Authz_state.revocation state (Subject.Principal (Principal.Human user_id)) with
          | Revocation_state.Pending -> Error (Principal_revocation_pending user_id)
          | Revocation_state.Not_pending ->
            Ok
              { user_id
              ; session_id = cookie.Cookie.session_id
              ; expires_at_ms = issued_at_ms + Authz_session_state.lifetime_ms
              }))
;;

let sign_out zone ~user_id session_id =
  Result.map
    (fun (_ : Authz_zone.committed) -> ())
    (commit zone ~user_id (Authz_session_event.Revoked { session_id }))
;;
