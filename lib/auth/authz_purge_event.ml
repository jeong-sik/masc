(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types

let ( let* ) = Result.bind

type target =
  | Keeper_conversation of
      { owner : User_id.t
      ; conversation_id : Conversation_id.t
      }

let target_equal a b =
  match a, b with
  | Keeper_conversation a, Keeper_conversation b ->
    User_id.equal a.owner b.owner && Conversation_id.equal a.conversation_id b.conversation_id
;;

let target_compare a b =
  match a, b with
  | Keeper_conversation a, Keeper_conversation b ->
    (match User_id.compare a.owner b.owner with
     | 0 -> Conversation_id.compare a.conversation_id b.conversation_id
     | order -> order)
;;

let subject = function
  | Keeper_conversation { owner; conversation_id } ->
    Authz_records.Subject.Keeper_conversation { owner; conversation_id }
;;

type vendor_copy =
  | Removed
  | No_copy
  | May_remain

type failed_stage = Folder_not_removed

type t =
  | Purge_pending of { target : target }
  | Purged of
      { target : target
      ; vendor_copy : vendor_copy
      }
  | Purge_failed of
      { target : target
      ; failed_stage : failed_stage
      ; vendor_copy : vendor_copy
      }

let target = function
  | Purge_pending { target } | Purged { target; _ } | Purge_failed { target; _ } -> target
;;

let vendor_copy_equal a b =
  match a, b with
  | Removed, Removed | No_copy, No_copy | May_remain, May_remain -> true
  | Removed, (No_copy | May_remain)
  | No_copy, (Removed | May_remain)
  | May_remain, (Removed | No_copy) -> false
;;

let failed_stage_equal a b =
  match a, b with
  | Folder_not_removed, Folder_not_removed -> true
;;

let equal a b =
  match a, b with
  | Purge_pending a, Purge_pending b -> target_equal a.target b.target
  | Purged a, Purged b -> target_equal a.target b.target && vendor_copy_equal a.vendor_copy b.vendor_copy
  | Purge_failed a, Purge_failed b ->
    target_equal a.target b.target
    && failed_stage_equal a.failed_stage b.failed_stage
    && vendor_copy_equal a.vendor_copy b.vendor_copy
  | Purge_pending _, (Purged _ | Purge_failed _)
  | Purged _, (Purge_pending _ | Purge_failed _)
  | Purge_failed _, (Purge_pending _ | Purged _) -> false
;;

let pending_label = "pending"
let purged_label = "purged"
let failed_label = "failed"
let keeper_conversation_label = "keeper_conversation"

(* The label functions name every constructor, so the compiler stops at a new
   one. These lists are what a label is read back through. *)
let vendor_copies = [ Removed; No_copy; May_remain ]

let vendor_copy_label = function
  | Removed -> "removed"
  | No_copy -> "none"
  | May_remain -> "may_remain"
;;

let failed_stages = [ Folder_not_removed ]

let failed_stage_label = function
  | Folder_not_removed -> "folder_not_removed"
;;

let body_of_target = function
  | Keeper_conversation { owner; conversation_id } ->
    let* kind = Authz_body.string keeper_conversation_label in
    let* owner = Authz_body.string (User_id.to_string owner) in
    let* conversation_id = Authz_body.string (Conversation_id.to_string conversation_id) in
    Authz_body.object_ [ "type", kind; "owner", owner; "conversation_id", conversation_id ]
;;

let to_body event =
  let* target = body_of_target (target event) in
  match event with
  | Purge_pending { target = _ } ->
    let* event = Authz_body.string pending_label in
    Authz_body.object_ [ "event", event; "target", target ]
  | Purged { target = _; vendor_copy } ->
    let* event = Authz_body.string purged_label in
    let* vendor_copy = Authz_body.string (vendor_copy_label vendor_copy) in
    Authz_body.object_ [ "event", event; "target", target; "vendor_copy", vendor_copy ]
  | Purge_failed { target = _; failed_stage; vendor_copy } ->
    let* event = Authz_body.string failed_label in
    let* failed_stage = Authz_body.string (failed_stage_label failed_stage) in
    let* vendor_copy = Authz_body.string (vendor_copy_label vendor_copy) in
    Authz_body.object_
      [ "event", event; "target", target; "failed_stage", failed_stage; "vendor_copy", vendor_copy ]
;;

type error =
  | Not_an_object
  | Unknown_event of string
  | Wrong_members
  | Unknown_target of string
  | Invalid_owner of Authz_id.error
  | Invalid_conversation_id of Authz_id.error
  | Unknown_failed_stage of string
  | Unknown_vendor_copy of string

let error_to_string = function
  | Not_an_object -> "the body of a purge record is an object"
  | Unknown_event label -> Printf.sprintf "%S is not an event of a purge" label
  | Wrong_members ->
    "the body of a pending purge has the members event and target, that of a purged one \
     event, target, and vendor_copy, and that of a failed one event, target, failed_stage, \
     and vendor_copy, in this order, with target an object of type, owner, and \
     conversation_id, and every other member a string"
  | Unknown_target label -> Printf.sprintf "%S is not a target of a purge" label
  | Invalid_owner error -> "the owner is not a valid user id: " ^ Authz_id.error_to_string error
  | Invalid_conversation_id error ->
    "the conversation id is not valid: " ^ Authz_id.error_to_string error
  | Unknown_failed_stage label -> Printf.sprintf "%S is not a stage that a purge fails at" label
  | Unknown_vendor_copy label -> Printf.sprintf "%S is not a state of the vendor copy" label
;;

let of_label values label_of label =
  List.find_opt (fun value -> String.equal (label_of value) label) values
;;

let failed_stage_of label =
  Option.to_result ~none:(Unknown_failed_stage label) (of_label failed_stages failed_stage_label label)
;;

let vendor_copy_of label =
  Option.to_result ~none:(Unknown_vendor_copy label) (of_label vendor_copies vendor_copy_label label)
;;

(* The [type] of a target is read first, so a target of another type is
   [Unknown_target] whatever its other members are. *)
let target_of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object (("type", Authz_body.String kind) :: members) ->
    if String.equal kind keeper_conversation_label
    then (
      match members with
      | [ ("owner", owner); ("conversation_id", conversation_id) ] ->
        (match Authz_body.string_value owner, Authz_body.string_value conversation_id with
         | Some owner, Some conversation_id ->
           let* owner = Result.map_error (fun error -> Invalid_owner error) (User_id.of_string owner) in
           let* conversation_id =
             Result.map_error
               (fun error -> Invalid_conversation_id error)
               (Conversation_id.of_string conversation_id)
           in
           Ok (Keeper_conversation { owner; conversation_id })
         | None, (None | Some _) | Some _, None -> Error Wrong_members)
      | _ -> Error Wrong_members)
    else Error (Unknown_target kind)
  | Authz_body.Object _
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> Error Wrong_members
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object (("event", Authz_body.String event) :: members) ->
    if String.equal event pending_label
    then (
      match members with
      | [ ("target", target) ] ->
        let* target = target_of_body target in
        Ok (Purge_pending { target })
      | _ -> Error Wrong_members)
    else if String.equal event purged_label
    then (
      match members with
      | [ ("target", target); ("vendor_copy", vendor_copy) ] ->
        (match Authz_body.string_value vendor_copy with
         | Some vendor_copy ->
           let* target = target_of_body target in
           let* vendor_copy = vendor_copy_of vendor_copy in
           Ok (Purged { target; vendor_copy })
         | None -> Error Wrong_members)
      | _ -> Error Wrong_members)
    else if String.equal event failed_label
    then (
      match members with
      | [ ("target", target); ("failed_stage", failed_stage); ("vendor_copy", vendor_copy) ] ->
        (match Authz_body.string_value failed_stage, Authz_body.string_value vendor_copy with
         | Some failed_stage, Some vendor_copy ->
           let* target = target_of_body target in
           let* failed_stage = failed_stage_of failed_stage in
           let* vendor_copy = vendor_copy_of vendor_copy in
           Ok (Purge_failed { target; failed_stage; vendor_copy })
         | None, (None | Some _) | Some _, None -> Error Wrong_members)
      | _ -> Error Wrong_members)
    else Error (Unknown_event event)
  | Authz_body.Object _ -> Error Wrong_members
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> Error Not_an_object
;;
