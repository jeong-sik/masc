(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types

let ( let* ) = Result.bind

module Secret_digest = struct
  type t = string

  let hex_length = Agent_core_sha256.digest_size * 2

  (* Keeps the digest of a secret from being valid as a digest in any other
     protocol, the invitation token and the record hash of the log included. *)
  let domain = "masc-authz-browser-session-secret-v1\n"

  let of_secret secret =
    Agent_core_sha256.to_hex (Agent_core_sha256.digest_string (domain ^ secret))
  ;;

  let is_lower_hex = function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false
  ;;

  let of_hex s =
    if String.length s = hex_length && String.for_all is_lower_hex s then Some s else None
  ;;

  let to_hex t = t
  let equal = Eqaf.equal
end

type t =
  | Issued of
      { session_id : Session_id.t
      ; user_id : User_id.t
      ; secret_digest : Secret_digest.t
      ; replaces : Session_id.t option
      }
  | Revoked of { session_id : Session_id.t }

let session_id = function
  | Issued { session_id; _ } | Revoked { session_id } -> session_id
;;

let equal a b =
  match a, b with
  | Issued a, Issued b ->
    Session_id.equal a.session_id b.session_id
    && User_id.equal a.user_id b.user_id
    && Secret_digest.equal a.secret_digest b.secret_digest
    && Option.equal Session_id.equal a.replaces b.replaces
  | Revoked a, Revoked b -> Session_id.equal a.session_id b.session_id
  | Issued _, Revoked _ | Revoked _, Issued _ -> false
;;

let issued_label = "issued"
let revoked_label = "revoked"

let to_body = function
  | Issued { session_id; user_id; secret_digest; replaces } ->
    let* event = Authz_body.string issued_label in
    let* session_id = Authz_body.string (Session_id.to_string session_id) in
    let* user_id = Authz_body.string (User_id.to_string user_id) in
    let* secret_digest = Authz_body.string (Secret_digest.to_hex secret_digest) in
    let* replaces =
      match replaces with
      | Some replaced -> Authz_body.string (Session_id.to_string replaced)
      | None -> Ok Authz_body.null
    in
    Authz_body.object_
      [ "event", event
      ; "session_id", session_id
      ; "user_id", user_id
      ; "secret_digest", secret_digest
      ; "replaces", replaces
      ]
  | Revoked { session_id } ->
    let* event = Authz_body.string revoked_label in
    let* session_id = Authz_body.string (Session_id.to_string session_id) in
    Authz_body.object_ [ "event", event; "session_id", session_id ]
;;

type error =
  | Not_an_object
  | Unknown_event of string
  | Wrong_members
  | Invalid_session_id of Authz_id.error
  | Invalid_user_id of Authz_id.error
  | Invalid_secret_digest
  | Invalid_replaces of Authz_id.error

let error_to_string = function
  | Not_an_object -> "the body of a session record is an object"
  | Unknown_event label -> Printf.sprintf "%S is not an event of a browser session" label
  | Wrong_members ->
    "the body of an issued session has the members event, session_id, user_id, \
     secret_digest, and replaces, and that of a revoked one event and session_id, in this \
     order, replaces a string or null and the others strings"
  | Invalid_session_id error ->
    "the session id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_user_id error -> "the user id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_secret_digest -> "the secret digest is not 64 lowercase hex characters"
  | Invalid_replaces error ->
    "the id of the replaced session is not valid: " ^ Authz_id.error_to_string error
;;

let session_id_of text =
  Result.map_error (fun error -> Invalid_session_id error) (Session_id.of_string text)
;;

(* [replaces] is read only when it is a string or null, so a member of another
   type is [Wrong_members]. *)
type replaces_member =
  | Replaced of string
  | Nothing_replaced
  | Not_a_replaces

let replaces_member = function
  | Authz_body.String text -> Replaced text
  | Authz_body.Null -> Nothing_replaced
  | Authz_body.Bool _ | Authz_body.Int _ | Authz_body.List _ | Authz_body.Object _ ->
    Not_a_replaces
;;

let issued_of ~session_id ~user_id ~secret_digest ~replaces =
  let* session_id = session_id_of session_id in
  let* user_id =
    Result.map_error (fun error -> Invalid_user_id error) (User_id.of_string user_id)
  in
  let* secret_digest =
    Option.to_result ~none:Invalid_secret_digest (Secret_digest.of_hex secret_digest)
  in
  let* replaces =
    match replaces with
    | Some replaced ->
      Result.map
        Option.some
        (Result.map_error (fun error -> Invalid_replaces error) (Session_id.of_string replaced))
    | None -> Ok None
  in
  Ok (Issued { session_id; user_id; secret_digest; replaces })
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object (("event", Authz_body.String event) :: members) ->
    if String.equal event issued_label
    then (
      match members with
      | [ ("session_id", session_id)
        ; ("user_id", user_id)
        ; ("secret_digest", secret_digest)
        ; ("replaces", replaces)
        ] ->
        (match
           ( Authz_body.string_value session_id
           , Authz_body.string_value user_id
           , Authz_body.string_value secret_digest
           , replaces_member replaces )
         with
         | Some session_id, Some user_id, Some secret_digest, Replaced replaced ->
           issued_of ~session_id ~user_id ~secret_digest ~replaces:(Some replaced)
         | Some session_id, Some user_id, Some secret_digest, Nothing_replaced ->
           issued_of ~session_id ~user_id ~secret_digest ~replaces:None
         | ( (None | Some _)
           , (None | Some _)
           , (None | Some _)
           , (Replaced _ | Nothing_replaced | Not_a_replaces) ) ->
           Error Wrong_members)
      | _ -> Error Wrong_members)
    else if String.equal event revoked_label
    then (
      match members with
      | [ ("session_id", session_id) ] ->
        (match Authz_body.string_value session_id with
         | Some session_id ->
           let* session_id = session_id_of session_id in
           Ok (Revoked { session_id })
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
