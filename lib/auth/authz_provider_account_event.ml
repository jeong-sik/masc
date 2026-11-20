(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types

let ( let* ) = Result.bind

type t =
  | Linked of
      { provider_account_id : Provider_account_id.t
      ; user_id : User_id.t
      ; integration_id : Integration_id.t
      }
  | Key_linked of
      { provider_account_id : Provider_account_id.t
      ; user_id : User_id.t
      ; integration_id : Integration_id.t
      }
  | Key_replaced of
      { provider_account_id : Provider_account_id.t
      ; user_id : User_id.t
      ; generation : Key_generation.t
      }

let provider_account_id = function
  | Linked { provider_account_id; user_id = _; integration_id = _ }
  | Key_linked { provider_account_id; user_id = _; integration_id = _ }
  | Key_replaced { provider_account_id; user_id = _; generation = _ } -> provider_account_id
;;

let equal a b =
  match a, b with
  | Linked a, Linked b ->
    Provider_account_id.equal a.provider_account_id b.provider_account_id
    && User_id.equal a.user_id b.user_id
    && Integration_id.equal a.integration_id b.integration_id
  | Key_linked a, Key_linked b ->
    Provider_account_id.equal a.provider_account_id b.provider_account_id
    && User_id.equal a.user_id b.user_id
    && Integration_id.equal a.integration_id b.integration_id
  | Key_replaced a, Key_replaced b ->
    Provider_account_id.equal a.provider_account_id b.provider_account_id
    && User_id.equal a.user_id b.user_id
    && Key_generation.equal a.generation b.generation
  | Linked _, (Key_linked _ | Key_replaced _)
  | Key_linked _, (Linked _ | Key_replaced _)
  | Key_replaced _, (Linked _ | Key_linked _) -> false
;;

let linked_label = "linked"
let key_linked_label = "key_linked"
let key_replaced_label = "key_replaced"

let to_body event =
  match event with
  | Linked { provider_account_id; user_id; integration_id } ->
    let* event = Authz_body.string linked_label in
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
  | Key_replaced { provider_account_id; user_id; generation } ->
    let* event = Authz_body.string key_replaced_label in
    let* provider_account_id =
      Authz_body.string (Provider_account_id.to_string provider_account_id)
    in
    let* user_id = Authz_body.string (User_id.to_string user_id) in
    let* generation = Authz_body.int (Key_generation.to_int generation) in
    Authz_body.object_
      [ "event", event
      ; "provider_account_id", provider_account_id
      ; "user_id", user_id
      ; "generation", generation
      ]
;;

type error =
  | Not_an_object
  | Unknown_event of string
  | Wrong_members
  | Invalid_provider_account_id of Authz_id.error
  | Invalid_user_id of Authz_id.error
  | Invalid_integration_id of Authz_id.error
  | Invalid_generation of int

let error_to_string = function
  | Not_an_object -> "the body of a provider account record is an object"
  | Unknown_event label -> Printf.sprintf "%S is not an event of a provider account" label
  | Wrong_members ->
    "the body of a linked or key_linked provider account has the members event, \
     provider_account_id, user_id, and integration_id, each a string, and that of a \
     key_replaced one event, provider_account_id, and user_id, each a string, and \
     generation, an integer, in this order"
  | Invalid_provider_account_id error ->
    "the provider account id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_user_id error -> "the user id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_integration_id error ->
    "the integration id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_generation generation ->
    Printf.sprintf "%d is not a generation of a key" generation
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

let account_owner_integration ~provider_account_id ~user_id ~integration_id =
  let* provider_account_id, user_id = account_and_owner ~provider_account_id ~user_id in
  let* integration_id =
    Result.map_error
      (fun error -> Invalid_integration_id error)
      (Integration_id.of_string integration_id)
  in
  Ok (provider_account_id, user_id, integration_id)
;;

let linked_of ~provider_account_id ~user_id ~integration_id =
  let* provider_account_id, user_id, integration_id =
    account_owner_integration ~provider_account_id ~user_id ~integration_id
  in
  Ok (Linked { provider_account_id; user_id; integration_id })
;;

let key_linked_of ~provider_account_id ~user_id ~integration_id =
  let* provider_account_id, user_id, integration_id =
    account_owner_integration ~provider_account_id ~user_id ~integration_id
  in
  Ok (Key_linked { provider_account_id; user_id; integration_id })
;;

let key_replaced_of ~provider_account_id ~user_id ~generation =
  let* provider_account_id, user_id = account_and_owner ~provider_account_id ~user_id in
  match Key_generation.of_int generation with
  | Some generation -> Ok (Key_replaced { provider_account_id; user_id; generation })
  | None -> Error (Invalid_generation generation)
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object (("event", Authz_body.String event) :: members) ->
    if String.equal event linked_label || String.equal event key_linked_label
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
           if String.equal event linked_label
           then linked_of ~provider_account_id ~user_id ~integration_id
           else key_linked_of ~provider_account_id ~user_id ~integration_id
         | (None | Some _), (None | Some _), (None | Some _) -> Error Wrong_members)
      | _ -> Error Wrong_members)
    else if String.equal event key_replaced_label
    then (
      match members with
      | [ ("provider_account_id", provider_account_id)
        ; ("user_id", user_id)
        ; ("generation", generation)
        ] ->
        (match
           ( Authz_body.string_value provider_account_id
           , Authz_body.string_value user_id
           , Authz_body.int_value generation )
         with
         | Some provider_account_id, Some user_id, Some generation ->
           key_replaced_of ~provider_account_id ~user_id ~generation
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
