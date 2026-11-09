(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types

let ( let* ) = Result.bind

type t =
  | Made of
      { keeper_id : Keeper_id.t
      ; user_id : User_id.t
      ; policy_id : Policy_id.t
      ; turn_scope : Authorization_scope.t
      }
  | Assigned of
      { keeper_id : Keeper_id.t
      ; runtime_id : Runtime_id.t
      }

let equal a b =
  match a, b with
  | Made a, Made b ->
    Keeper_id.equal a.keeper_id b.keeper_id
    && User_id.equal a.user_id b.user_id
    && Policy_id.equal a.policy_id b.policy_id
    && Authorization_scope.equal a.turn_scope b.turn_scope
  | Assigned a, Assigned b ->
    Keeper_id.equal a.keeper_id b.keeper_id && Runtime_id.equal a.runtime_id b.runtime_id
  | Made _, Assigned _ | Assigned _, Made _ -> false
;;

let made_label = "made"
let assigned_label = "assigned"

let to_body = function
  | Made { keeper_id; user_id; policy_id; turn_scope } ->
    let* event = Authz_body.string made_label in
    let* keeper_id = Authz_body.string (Keeper_id.to_string keeper_id) in
    let* user_id = Authz_body.string (User_id.to_string user_id) in
    let* policy_id = Authz_body.string (Policy_id.to_string policy_id) in
    let* turn_scope = Authz_scope_body.to_body turn_scope in
    Authz_body.object_
      [ "event", event
      ; "keeper_id", keeper_id
      ; "user_id", user_id
      ; "policy_id", policy_id
      ; "turn_scope", turn_scope
      ]
  | Assigned { keeper_id; runtime_id } ->
    let* event = Authz_body.string assigned_label in
    let* keeper_id = Authz_body.string (Keeper_id.to_string keeper_id) in
    let* runtime_id = Authz_body.string (Runtime_id.to_string runtime_id) in
    Authz_body.object_ [ "event", event; "keeper_id", keeper_id; "runtime_id", runtime_id ]
;;

type error =
  | Not_an_object
  | Unknown_event of string
  | Wrong_members
  | Invalid_keeper_id of Authz_id.error
  | Invalid_user_id of Authz_id.error
  | Invalid_runtime_id of Authz_id.error
  | Invalid_policy_id of Authz_id.error
  | Invalid_turn_scope of Authz_scope_body.error

let error_to_string = function
  | Not_an_object -> "the body of a Keeper record is an object"
  | Unknown_event label -> Printf.sprintf "%S is not an event of a Keeper" label
  | Wrong_members ->
    "the body of a Keeper record has the members event, keeper_id, user_id, policy_id and \
     turn_scope (made) or event, keeper_id and runtime_id (assigned), in this order, \
     turn_scope a scope and the others strings"
  | Invalid_keeper_id error -> "the Keeper id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_user_id error -> "the user id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_runtime_id error -> "the Runtime id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_policy_id error -> "the policy id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_turn_scope error ->
    "the scope of the Keeper's turns is not valid: " ^ Authz_scope_body.error_to_string error
;;

let keeper_id_of value =
  Result.map_error (fun error -> Invalid_keeper_id error) (Keeper_id.of_string value)
;;

let made_of ~keeper_id ~user_id ~policy_id ~turn_scope =
  let* keeper_id = keeper_id_of keeper_id in
  let* user_id =
    Result.map_error (fun error -> Invalid_user_id error) (User_id.of_string user_id)
  in
  let* policy_id =
    Result.map_error (fun error -> Invalid_policy_id error) (Policy_id.of_string policy_id)
  in
  let* turn_scope =
    Result.map_error (fun error -> Invalid_turn_scope error) (Authz_scope_body.of_body turn_scope)
  in
  Ok (Made { keeper_id; user_id; policy_id; turn_scope })
;;

let assigned_of ~keeper_id ~runtime_id =
  let* keeper_id = keeper_id_of keeper_id in
  let* runtime_id =
    Result.map_error (fun error -> Invalid_runtime_id error) (Runtime_id.of_string runtime_id)
  in
  Ok (Assigned { keeper_id; runtime_id })
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object (("event", Authz_body.String event) :: members) ->
    if String.equal event made_label
    then (
      match members with
      | [ ("keeper_id", keeper_id)
        ; ("user_id", user_id)
        ; ("policy_id", policy_id)
        ; ("turn_scope", turn_scope)
        ] ->
        (match
           ( Authz_body.string_value keeper_id
           , Authz_body.string_value user_id
           , Authz_body.string_value policy_id )
         with
         | Some keeper_id, Some user_id, Some policy_id ->
           made_of ~keeper_id ~user_id ~policy_id ~turn_scope
         | (None | Some _), (None | Some _), (None | Some _) -> Error Wrong_members)
      | _ -> Error Wrong_members)
    else if String.equal event assigned_label
    then (
      match members with
      | [ ("keeper_id", keeper_id); ("runtime_id", runtime_id) ] ->
        (match Authz_body.string_value keeper_id, Authz_body.string_value runtime_id with
         | Some keeper_id, Some runtime_id -> assigned_of ~keeper_id ~runtime_id
         | (None | Some _), (None | Some _) -> Error Wrong_members)
      | _ -> Error Wrong_members)
    else Error (Unknown_event event)
  | Authz_body.Object _ -> Error Wrong_members
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> Error Not_an_object
;;
