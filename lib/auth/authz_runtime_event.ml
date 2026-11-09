(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types

let ( let* ) = Result.bind

type t =
  | Made of
      { runtime_id : Runtime_id.t
      ; provider_account_id : Provider_account_id.t
      ; user_id : User_id.t
      ; grant_id : Grant_id.t
      ; self_effects : Effect.Set.t
      }

let equal (Made a) (Made b) =
  Runtime_id.equal a.runtime_id b.runtime_id
  && Provider_account_id.equal a.provider_account_id b.provider_account_id
  && User_id.equal a.user_id b.user_id
  && Grant_id.equal a.grant_id b.grant_id
  && Effect.Set.equal a.self_effects b.self_effects
;;

let made_label = "made"

let to_body (Made { runtime_id; provider_account_id; user_id; grant_id; self_effects }) =
  let* event = Authz_body.string made_label in
  let* runtime_id = Authz_body.string (Runtime_id.to_string runtime_id) in
  let* provider_account_id =
    Authz_body.string (Provider_account_id.to_string provider_account_id)
  in
  let* user_id = Authz_body.string (User_id.to_string user_id) in
  let* grant_id = Authz_body.string (Grant_id.to_string grant_id) in
  let* self_effects = Authz_scope_body.effect_set_to_body self_effects in
  Authz_body.object_
    [ "event", event
    ; "runtime_id", runtime_id
    ; "provider_account_id", provider_account_id
    ; "user_id", user_id
    ; "grant_id", grant_id
    ; "self_effects", self_effects
    ]
;;

type error =
  | Not_an_object
  | Unknown_event of string
  | Wrong_members
  | Invalid_runtime_id of Authz_id.error
  | Invalid_provider_account_id of Authz_id.error
  | Invalid_user_id of Authz_id.error
  | Invalid_grant_id of Authz_id.error
  | Invalid_self_effects of Authz_scope_body.error

let error_to_string = function
  | Not_an_object -> "the body of a Runtime record is an object"
  | Unknown_event label -> Printf.sprintf "%S is not an event of a Runtime" label
  | Wrong_members ->
    "the body of a made Runtime has the members event, runtime_id, provider_account_id, \
     user_id, grant_id, and self_effects, in this order, the last a list of effects and \
     the others strings"
  | Invalid_runtime_id error -> "the Runtime id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_provider_account_id error ->
    "the provider account id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_user_id error -> "the user id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_grant_id error -> "the grant id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_self_effects error ->
    "the effects of the Self grant are not valid: " ^ Authz_scope_body.error_to_string error
;;

let made_of ~runtime_id ~provider_account_id ~user_id ~grant_id ~self_effects =
  let* runtime_id =
    Result.map_error (fun error -> Invalid_runtime_id error) (Runtime_id.of_string runtime_id)
  in
  let* provider_account_id =
    Result.map_error
      (fun error -> Invalid_provider_account_id error)
      (Provider_account_id.of_string provider_account_id)
  in
  let* user_id =
    Result.map_error (fun error -> Invalid_user_id error) (User_id.of_string user_id)
  in
  let* grant_id =
    Result.map_error (fun error -> Invalid_grant_id error) (Grant_id.of_string grant_id)
  in
  let* self_effects =
    Result.map_error
      (fun error -> Invalid_self_effects error)
      (Authz_scope_body.effect_set_of_body self_effects)
  in
  Ok (Made { runtime_id; provider_account_id; user_id; grant_id; self_effects })
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object (("event", Authz_body.String event) :: members) ->
    if String.equal event made_label
    then (
      match members with
      | [ ("runtime_id", runtime_id)
        ; ("provider_account_id", provider_account_id)
        ; ("user_id", user_id)
        ; ("grant_id", grant_id)
        ; ("self_effects", self_effects)
        ] ->
        (match
           ( Authz_body.string_value runtime_id
           , Authz_body.string_value provider_account_id
           , Authz_body.string_value user_id
           , Authz_body.string_value grant_id )
         with
         | Some runtime_id, Some provider_account_id, Some user_id, Some grant_id ->
           made_of ~runtime_id ~provider_account_id ~user_id ~grant_id ~self_effects
         | (None | Some _), (None | Some _), (None | Some _), (None | Some _) ->
           Error Wrong_members)
      | _ -> Error Wrong_members)
    else Error (Unknown_event event)
  | Authz_body.Object _ -> Error Wrong_members
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> Error Not_an_object
;;
