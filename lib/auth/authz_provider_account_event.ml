(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types

let ( let* ) = Result.bind

type t =
  | Linked of
      { provider_account_id : Provider_account_id.t
      ; user_id : User_id.t
      }
  | Key_linked of
      { provider_account_id : Provider_account_id.t
      ; user_id : User_id.t
      ; integration_id : Integration_id.t
      }

let provider_account_id = function
  | Linked { provider_account_id; user_id = _ }
  | Key_linked { provider_account_id; user_id = _; integration_id = _ } -> provider_account_id
;;

let equal a b =
  match a, b with
  | Linked a, Linked b ->
    Provider_account_id.equal a.provider_account_id b.provider_account_id
    && User_id.equal a.user_id b.user_id
  | Key_linked a, Key_linked b ->
    Provider_account_id.equal a.provider_account_id b.provider_account_id
    && User_id.equal a.user_id b.user_id
    && Integration_id.equal a.integration_id b.integration_id
  | Linked _, Key_linked _ | Key_linked _, Linked _ -> false
;;

let linked_label = "linked"
let key_linked_label = "key_linked"

let to_body event =
  match event with
  | Linked { provider_account_id; user_id } ->
    let* event = Authz_body.string linked_label in
    let* provider_account_id =
      Authz_body.string (Provider_account_id.to_string provider_account_id)
    in
    let* user_id = Authz_body.string (User_id.to_string user_id) in
    Authz_body.object_
      [ "event", event; "provider_account_id", provider_account_id; "user_id", user_id ]
  | Key_linked { provider_account_id; user_id; integration_id } ->
    let* event = Authz_body.string key_linked_label in
    let* provider_account_id =
      Authz_body.string (Provider_account_id.to_string provider_account_id)
    in
    let* user_id = Authz_body.string (User_id.to_string user_id) in
    let* integration_id = Authz_body.string (Integration_id.to_string integration_id) in
    Authz_body.object_
      [ "event", event
      ; "provider_account_id", provider_account_id
      ; "user_id", user_id
      ; "integration_id", integration_id
      ]
;;

type error =
  | Not_an_object
  | Unknown_event of string
  | Wrong_members
  | Invalid_provider_account_id of Authz_id.error
  | Invalid_user_id of Authz_id.error
  | Invalid_integration_id of Authz_id.error

let error_to_string = function
  | Not_an_object -> "the body of a provider account record is an object"
  | Unknown_event label -> Printf.sprintf "%S is not an event of a provider account" label
  | Wrong_members ->
    "the body of a linked provider account has the members event, provider_account_id, \
     and user_id, and that of a key_linked one event, provider_account_id, user_id, and \
     integration_id, in this order, each a string"
  | Invalid_provider_account_id error ->
    "the provider account id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_user_id error -> "the user id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_integration_id error ->
    "the integration id is not valid: " ^ Authz_id.error_to_string error
;;

let account_and_owner ~provider_account_id ~user_id =
  let* provider_account_id =
    Result.map_error
      (fun error -> Invalid_provider_account_id error)
      (Provider_account_id.of_string provider_account_id)
  in
  let* user_id =
    Result.map_error (fun error -> Invalid_user_id error) (User_id.of_string user_id)
  in
  Ok (provider_account_id, user_id)
;;

let linked_of ~provider_account_id ~user_id =
  let* provider_account_id, user_id = account_and_owner ~provider_account_id ~user_id in
  Ok (Linked { provider_account_id; user_id })
;;

let key_linked_of ~provider_account_id ~user_id ~integration_id =
  let* provider_account_id, user_id = account_and_owner ~provider_account_id ~user_id in
  let* integration_id =
    Result.map_error
      (fun error -> Invalid_integration_id error)
      (Integration_id.of_string integration_id)
  in
  Ok (Key_linked { provider_account_id; user_id; integration_id })
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object (("event", Authz_body.String event) :: members) ->
    if String.equal event linked_label
    then (
      match members with
      | [ ("provider_account_id", provider_account_id); ("user_id", user_id) ] ->
        (match Authz_body.string_value provider_account_id, Authz_body.string_value user_id with
         | Some provider_account_id, Some user_id -> linked_of ~provider_account_id ~user_id
         | (None | Some _), (None | Some _) -> Error Wrong_members)
      | _ -> Error Wrong_members)
    else if String.equal event key_linked_label
    then (
      match members with
      | [ ("provider_account_id", provider_account_id)
        ; ("user_id", user_id)
        ; ("integration_id", integration_id)
        ] ->
        (match
           ( Authz_body.string_value provider_account_id
           , Authz_body.string_value user_id
           , Authz_body.string_value integration_id )
         with
         | Some provider_account_id, Some user_id, Some integration_id ->
           key_linked_of ~provider_account_id ~user_id ~integration_id
         | (None | Some _), (None | Some _), (None | Some _) -> Error Wrong_members)
      | _ -> Error Wrong_members)
    else Error (Unknown_event event)
  | Authz_body.Object _ -> Error Wrong_members
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> Error Not_an_object
;;
