(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types

let ( let* ) = Result.bind

type t =
  | Registered of
      { registration_id : Registration_id.t
      ; identity : Authz_external_identity.t
      }
  | Removed of { registration_id : Registration_id.t }

let registration_id = function
  | Registered { registration_id; _ } | Removed { registration_id } -> registration_id
;;

let equal a b =
  match a, b with
  | Registered a, Registered b ->
    Registration_id.equal a.registration_id b.registration_id
    && Authz_external_identity.equal a.identity b.identity
  | Removed a, Removed b -> Registration_id.equal a.registration_id b.registration_id
  | Registered _, Removed _ | Removed _, Registered _ -> false
;;

let registered_label = "registered"
let removed_label = "removed"

let to_body = function
  | Registered { registration_id; identity } ->
    let* event = Authz_body.string registered_label in
    let* registration_id = Authz_body.string (Registration_id.to_string registration_id) in
    let* identity = Authz_external_identity.to_body identity in
    Authz_body.object_
      [ "event", event; "registration_id", registration_id; "identity", identity ]
  | Removed { registration_id } ->
    let* event = Authz_body.string removed_label in
    let* registration_id = Authz_body.string (Registration_id.to_string registration_id) in
    Authz_body.object_ [ "event", event; "registration_id", registration_id ]
;;

type error =
  | Not_an_object
  | Unknown_event of string
  | Wrong_members
  | Invalid_registration_id of Authz_id.error
  | Invalid_identity of Authz_external_identity.body_error

let id_error_to_string : Authz_id.error -> string = function
  | Authz_id.Empty -> "empty"
  | Authz_id.Too_long -> "too long"
  | Authz_id.Invalid_byte { index } -> Printf.sprintf "invalid byte at %d" index
  | Authz_id.Path_segment -> "a path segment"
;;

let error_to_string = function
  | Not_an_object -> "the body of an allowlist record is an object"
  | Unknown_event label -> Printf.sprintf "%S is not an event of the allowlist" label
  | Wrong_members ->
    "the body of a registration has the members event, registration_id, and identity, and \
     that of a removal event and registration_id, in this order, identity an object and the \
     others strings"
  | Invalid_registration_id error ->
    Printf.sprintf "the registration id is not valid: %s" (id_error_to_string error)
  | Invalid_identity error ->
    "the identity is not valid: " ^ Authz_external_identity.body_error_to_string error
;;

let registration_id_of text =
  Result.map_error (fun error -> Invalid_registration_id error) (Registration_id.of_string text)
;;

(* The identity member is read only when it is an object, so a member of
   another type is [Wrong_members], as in the body of an admission. *)
let object_member = function
  | Authz_body.Object _ as member -> Some member
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> None
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object (("event", Authz_body.String event) :: members) ->
    if String.equal event registered_label
    then (
      match members with
      | [ ("registration_id", registration_id); ("identity", identity) ] ->
        (match Authz_body.string_value registration_id, object_member identity with
         | Some registration_id, Some identity ->
           let* registration_id = registration_id_of registration_id in
           let* identity =
             Result.map_error
               (fun error -> Invalid_identity error)
               (Authz_external_identity.of_body identity)
           in
           Ok (Registered { registration_id; identity })
         | (None | Some _), (None | Some _) -> Error Wrong_members)
      | _ -> Error Wrong_members)
    else if String.equal event removed_label
    then (
      match members with
      | [ ("registration_id", registration_id) ] ->
        (match Authz_body.string_value registration_id with
         | Some registration_id ->
           let* registration_id = registration_id_of registration_id in
           Ok (Removed { registration_id })
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
