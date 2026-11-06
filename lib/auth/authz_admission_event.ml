(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types

let ( let* ) = Result.bind

type t =
  { user_id : User_id.t
  ; identity : Authz_external_identity.t
  ; invite_id : Invite_id.t
  }

let equal a b =
  User_id.equal a.user_id b.user_id
  && Authz_external_identity.equal a.identity b.identity
  && Invite_id.equal a.invite_id b.invite_id
;;

let to_body { user_id; identity; invite_id } =
  let* user_id = Authz_body.string (User_id.to_string user_id) in
  let* identity = Authz_external_identity.to_body identity in
  let* invite_id = Authz_body.string (Invite_id.to_string invite_id) in
  Authz_body.object_ [ "user_id", user_id; "identity", identity; "invite_id", invite_id ]
;;

type error =
  | Not_an_object
  | Wrong_members
  | Invalid_user_id of Authz_id.error
  | Invalid_identity of Authz_external_identity.body_error
  | Invalid_invite_id of Authz_id.error

let id_error_to_string : Authz_id.error -> string = function
  | Authz_id.Empty -> "empty"
  | Authz_id.Too_long -> "too long"
  | Authz_id.Invalid_byte { index } -> Printf.sprintf "invalid byte at %d" index
  | Authz_id.Path_segment -> "a path segment"
;;

let error_to_string = function
  | Not_an_object -> "the body of an admission is an object"
  | Wrong_members ->
    "the body of an admission has the members user_id, a string, identity, an object, and \
     invite_id, a string, in this order"
  | Invalid_user_id error -> Printf.sprintf "the user id is not valid: %s" (id_error_to_string error)
  | Invalid_identity error ->
    "the identity is not valid: " ^ Authz_external_identity.body_error_to_string error
  | Invalid_invite_id error ->
    Printf.sprintf "the invite id is not valid: %s" (id_error_to_string error)
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object
      [ ("user_id", Authz_body.String user_id)
      ; ("identity", (Authz_body.Object _ as identity))
      ; ("invite_id", Authz_body.String invite_id)
      ] ->
    let* user_id =
      Result.map_error (fun error -> Invalid_user_id error) (User_id.of_string user_id)
    in
    let* identity =
      Result.map_error (fun error -> Invalid_identity error) (Authz_external_identity.of_body identity)
    in
    let* invite_id =
      Result.map_error (fun error -> Invalid_invite_id error) (Invite_id.of_string invite_id)
    in
    Ok { user_id; identity; invite_id }
  | Authz_body.Object _ -> Error Wrong_members
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> Error Not_an_object
;;
