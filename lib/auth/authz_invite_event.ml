(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types

let ( let* ) = Result.bind

type role =
  | Member
  | Admin

(* [role_label] names every constructor, so the compiler stops at a new one.
   [roles] is what a label is read back through: a constructor that is missing
   from it is written and then read as [Unknown_role]. *)
let roles = [ Member; Admin ]

let role_label = function
  | Member -> "member"
  | Admin -> "admin"
;;

let role_of_label label = List.find_opt (fun role -> String.equal (role_label role) label) roles

module Token_digest = struct
  type t = string

  let hex_length = Agent_core_sha256.digest_size * 2

  (* Keeps the digest of a token from being valid as a digest in any other
     protocol, the record hash of the log included. *)
  let domain = "masc-authz-invite-token-v1\n"

  let of_token token =
    Agent_core_sha256.to_hex (Agent_core_sha256.digest_string (domain ^ token))
  ;;

  let is_lower_hex = function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false
  ;;

  let of_hex s =
    if String.length s = hex_length && String.for_all is_lower_hex s then Some s else None
  ;;

  let to_hex t = t
  let equal = String.equal
end

type t =
  | Issued of
      { invite_id : Invite_id.t
      ; token_digest : Token_digest.t
      ; expires_at_ms : int
      ; role : role
      }
  | Revoked of { invite_id : Invite_id.t }

let invite_id = function
  | Issued { invite_id; _ } | Revoked { invite_id } -> invite_id
;;

let equal a b =
  match a, b with
  | Issued a, Issued b ->
    Invite_id.equal a.invite_id b.invite_id
    && Token_digest.equal a.token_digest b.token_digest
    && Int.equal a.expires_at_ms b.expires_at_ms
    && a.role = b.role
  | Revoked a, Revoked b -> Invite_id.equal a.invite_id b.invite_id
  | Issued _, Revoked _ | Revoked _, Issued _ -> false
;;

let issued_label = "issued"
let revoked_label = "revoked"

let to_body = function
  | Issued { invite_id; token_digest; expires_at_ms; role } ->
    let* event = Authz_body.string issued_label in
    let* invite_id = Authz_body.string (Invite_id.to_string invite_id) in
    let* token_digest = Authz_body.string (Token_digest.to_hex token_digest) in
    let* expires_at_ms = Authz_body.int expires_at_ms in
    let* role = Authz_body.string (role_label role) in
    Authz_body.object_
      [ "event", event
      ; "invite_id", invite_id
      ; "token_digest", token_digest
      ; "expires_at_ms", expires_at_ms
      ; "role", role
      ]
  | Revoked { invite_id } ->
    let* event = Authz_body.string revoked_label in
    let* invite_id = Authz_body.string (Invite_id.to_string invite_id) in
    Authz_body.object_ [ "event", event; "invite_id", invite_id ]
;;

type error =
  | Not_an_object
  | Unknown_event of string
  | Wrong_members
  | Invalid_invite_id of Authz_id.error
  | Invalid_token_digest
  | Unknown_role of string

let id_error_to_string : Authz_id.error -> string = function
  | Authz_id.Empty -> "empty"
  | Authz_id.Too_long -> "too long"
  | Authz_id.Invalid_byte { index } -> Printf.sprintf "invalid byte at %d" index
  | Authz_id.Path_segment -> "a path segment"
;;

let error_to_string = function
  | Not_an_object -> "the body of an invite record is an object"
  | Unknown_event label -> Printf.sprintf "%S is not an event of an invitation" label
  | Wrong_members ->
    "the body of an issued invitation has the members event, invite_id, token_digest, \
     expires_at_ms, and role, and that of a revoked one event and invite_id, in this order, \
     expires_at_ms a number and the others strings"
  | Invalid_invite_id error ->
    Printf.sprintf "the invite id is not valid: %s" (id_error_to_string error)
  | Invalid_token_digest -> "the token digest is not 64 lowercase hex characters"
  | Unknown_role label -> Printf.sprintf "%S is not a role of an invitation" label
;;

let invite_id_of text =
  Result.map_error (fun error -> Invalid_invite_id error) (Invite_id.of_string text)
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object (("event", Authz_body.String event) :: members) ->
    if String.equal event issued_label
    then (
      match members with
      | [ ("invite_id", Authz_body.String invite_id)
        ; ("token_digest", Authz_body.String token_digest)
        ; ("expires_at_ms", Authz_body.Int expires_at_ms)
        ; ("role", Authz_body.String role)
        ] ->
        let* invite_id = invite_id_of invite_id in
        let* token_digest =
          match Token_digest.of_hex token_digest with
          | Some digest -> Ok digest
          | None -> Error Invalid_token_digest
        in
        let* role =
          match role_of_label role with
          | Some role -> Ok role
          | None -> Error (Unknown_role role)
        in
        Ok (Issued { invite_id; token_digest; expires_at_ms; role })
      | _ -> Error Wrong_members)
    else if String.equal event revoked_label
    then (
      match members with
      | [ ("invite_id", Authz_body.String invite_id) ] ->
        let* invite_id = invite_id_of invite_id in
        Ok (Revoked { invite_id })
      | _ -> Error Wrong_members)
    else Error (Unknown_event event)
  | Authz_body.Object _ -> Error Wrong_members
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> Error Not_an_object
;;
