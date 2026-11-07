(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
module Digest = Authz_credential_token.Pat.Digest

let ( let* ) = Result.bind

type t =
  | Issued of
      { pat_id : Pat_id.t
      ; user_id : User_id.t
      ; secret_digest : Digest.t
      ; scope : Authorization_scope.t
      ; expires_at_ms : int option
      }
  | Revoked of { pat_id : Pat_id.t }

let pat_id = function
  | Issued { pat_id; _ } | Revoked { pat_id } -> pat_id
;;

let equal a b =
  match a, b with
  | Issued a, Issued b ->
    Pat_id.equal a.pat_id b.pat_id
    && User_id.equal a.user_id b.user_id
    && Digest.equal a.secret_digest b.secret_digest
    && Authorization_scope.equal a.scope b.scope
    && Option.equal Int.equal a.expires_at_ms b.expires_at_ms
  | Revoked a, Revoked b -> Pat_id.equal a.pat_id b.pat_id
  | Issued _, Revoked _ | Revoked _, Issued _ -> false
;;

let issued_label = "issued"
let revoked_label = "revoked"

let to_body = function
  | Issued { pat_id; user_id; secret_digest; scope; expires_at_ms } ->
    let* event = Authz_body.string issued_label in
    let* pat_id = Authz_body.string (Pat_id.to_string pat_id) in
    let* user_id = Authz_body.string (User_id.to_string user_id) in
    let* secret_digest = Authz_body.string (Digest.to_hex secret_digest) in
    let* scope = Authz_scope_body.to_body scope in
    let* expires_at_ms =
      match expires_at_ms with
      | Some at_ms -> Authz_body.int at_ms
      | None -> Ok Authz_body.null
    in
    Authz_body.object_
      [ "event", event
      ; "pat_id", pat_id
      ; "user_id", user_id
      ; "secret_digest", secret_digest
      ; "scope", scope
      ; "expires_at_ms", expires_at_ms
      ]
  | Revoked { pat_id } ->
    let* event = Authz_body.string revoked_label in
    let* pat_id = Authz_body.string (Pat_id.to_string pat_id) in
    Authz_body.object_ [ "event", event; "pat_id", pat_id ]
;;

type error =
  | Not_an_object
  | Unknown_event of string
  | Wrong_members
  | Invalid_pat_id of Authz_id.error
  | Invalid_user_id of Authz_id.error
  | Invalid_secret_digest
  | Invalid_scope of Authz_scope_body.error

let error_to_string = function
  | Not_an_object -> "the body of a PAT record is an object"
  | Unknown_event label -> Printf.sprintf "%S is not an event of a PAT" label
  | Wrong_members ->
    "the body of an issued PAT has the members event, pat_id, user_id, secret_digest, \
     scope, and expires_at_ms, and that of a revoked one event and pat_id, in this order, \
     scope an object, expires_at_ms an integer or null and the others strings"
  | Invalid_pat_id error -> "the PAT id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_user_id error -> "the user id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_secret_digest -> "the secret digest is not 64 lowercase hex characters"
  | Invalid_scope error -> "the scope is not valid: " ^ Authz_scope_body.error_to_string error
;;

let pat_id_of text =
  Result.map_error (fun error -> Invalid_pat_id error) (Pat_id.of_string text)
;;

(* [expires_at_ms] is read only when it is an integer or null, so a member of
   another type is [Wrong_members]. *)
type expiry_member =
  | Expires of int
  | Never
  | Not_an_expiry

let expiry_member = function
  | Authz_body.Int at_ms -> Expires at_ms
  | Authz_body.Null -> Never
  | Authz_body.Bool _ | Authz_body.String _ | Authz_body.List _ | Authz_body.Object _ ->
    Not_an_expiry
;;

let is_object = function
  | Authz_body.Object _ -> true
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> false
;;

let issued_of ~pat_id ~user_id ~secret_digest ~scope ~expires_at_ms =
  let* pat_id = pat_id_of pat_id in
  let* user_id =
    Result.map_error (fun error -> Invalid_user_id error) (User_id.of_string user_id)
  in
  let* secret_digest =
    Option.to_result ~none:Invalid_secret_digest (Digest.of_hex secret_digest)
  in
  let* scope =
    Result.map_error (fun error -> Invalid_scope error) (Authz_scope_body.of_body scope)
  in
  Ok (Issued { pat_id; user_id; secret_digest; scope; expires_at_ms })
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object (("event", Authz_body.String event) :: members) ->
    if String.equal event issued_label
    then (
      match members with
      | [ ("pat_id", pat_id)
        ; ("user_id", user_id)
        ; ("secret_digest", secret_digest)
        ; ("scope", scope)
        ; ("expires_at_ms", expires_at_ms)
        ] ->
        (match
           ( Authz_body.string_value pat_id
           , Authz_body.string_value user_id
           , Authz_body.string_value secret_digest
           , is_object scope
           , expiry_member expires_at_ms )
         with
         | Some pat_id, Some user_id, Some secret_digest, true, Expires at_ms ->
           issued_of ~pat_id ~user_id ~secret_digest ~scope ~expires_at_ms:(Some at_ms)
         | Some pat_id, Some user_id, Some secret_digest, true, Never ->
           issued_of ~pat_id ~user_id ~secret_digest ~scope ~expires_at_ms:None
         | ( (None | Some _)
           , (None | Some _)
           , (None | Some _)
           , (true | false)
           , (Expires _ | Never | Not_an_expiry) ) -> Error Wrong_members)
      | _ -> Error Wrong_members)
    else if String.equal event revoked_label
    then (
      match members with
      | [ ("pat_id", pat_id) ] ->
        (match Authz_body.string_value pat_id with
         | Some pat_id ->
           let* pat_id = pat_id_of pat_id in
           Ok (Revoked { pat_id })
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
