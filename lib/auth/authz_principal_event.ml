(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types

let ( let* ) = Result.bind

module Identity = Authz_external_identity

type t =
  | Disabled of { user_id : User_id.t }
  | Enabled of { user_id : User_id.t }
  | Deleted of
      { user_id : User_id.t
      ; identity : Identity.t
      }

let user_id = function
  | Disabled { user_id } | Enabled { user_id } | Deleted { user_id; identity = _ } -> user_id
;;

let equal a b =
  match a, b with
  | Disabled a, Disabled b -> User_id.equal a.user_id b.user_id
  | Enabled a, Enabled b -> User_id.equal a.user_id b.user_id
  | Deleted a, Deleted b -> User_id.equal a.user_id b.user_id && Identity.equal a.identity b.identity
  | (Disabled _ | Enabled _ | Deleted _), (Disabled _ | Enabled _ | Deleted _) -> false
;;

let disabled_label = "disabled"
let enabled_label = "enabled"
let deleted_label = "deleted"

let to_body t =
  let label =
    match t with
    | Disabled _ -> disabled_label
    | Enabled _ -> enabled_label
    | Deleted _ -> deleted_label
  in
  let* event = Authz_body.string label in
  let* user = Authz_body.string (User_id.to_string (user_id t)) in
  match t with
  | Disabled _ | Enabled _ -> Authz_body.object_ [ "event", event; "user_id", user ]
  | Deleted { identity; user_id = _ } ->
    let* identity = Identity.to_body identity in
    Authz_body.object_ [ "event", event; "user_id", user; "identity", identity ]
;;

type error =
  | Not_an_object
  | Unknown_event of string
  | Wrong_members
  | Invalid_user_id of Authz_id.error
  | Invalid_identity of Identity.body_error

let error_to_string = function
  | Not_an_object -> "the body of a principal record is an object"
  | Unknown_event label -> Printf.sprintf "%S is not an event of a principal" label
  | Wrong_members ->
    "a disabled or enabled principal has the members event and user_id, both strings, and a \
     deleted one also identity, an object, in this order"
  | Invalid_user_id error -> Printf.sprintf "the user id is not valid: %s" (Authz_id.error_to_string error)
  | Invalid_identity error -> "the identity is not valid: " ^ Identity.body_error_to_string error
;;

let user_id_of text =
  Result.map_error (fun error -> Invalid_user_id error) (User_id.of_string text)
;;

(* An identity that is not an object is a member of the wrong type, as in the
   other bodies of the log. *)
let identity_of body =
  match Identity.of_body body with
  | Ok identity -> Ok identity
  | Error Identity.Not_an_object -> Error Wrong_members
  | Error ((Identity.Unknown_provider _ | Identity.Wrong_members | Identity.Invalid _) as error) ->
    Error (Invalid_identity error)
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object (("event", Authz_body.String event) :: members) ->
    let one_user make =
      match members with
      | [ ("user_id", user) ] ->
        (match Authz_body.string_value user with
         | Some user ->
           let* user_id = user_id_of user in
           Ok (make user_id)
         | None -> Error Wrong_members)
      | _ -> Error Wrong_members
    in
    if String.equal event disabled_label
    then one_user (fun user_id -> Disabled { user_id })
    else if String.equal event enabled_label
    then one_user (fun user_id -> Enabled { user_id })
    else if String.equal event deleted_label
    then (
      match members with
      | [ ("user_id", user); ("identity", identity) ] ->
        (match Authz_body.string_value user with
         | Some user ->
           let* user_id = user_id_of user in
           let* identity = identity_of identity in
           Ok (Deleted { user_id; identity })
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
