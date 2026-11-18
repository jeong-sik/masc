(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types

let ( let* ) = Result.bind

type conversation =
  { owner : User_id.t
  ; conversation_id : Conversation_id.t
  }

type account =
  { owner : User_id.t
  ; provider_account_id : Provider_account_id.t
  }

type target =
  | Keeper_conversation of conversation
  | Provider_account of account

let conversation_compare (a : conversation) (b : conversation) =
  match User_id.compare a.owner b.owner with
  | 0 -> Conversation_id.compare a.conversation_id b.conversation_id
  | order -> order
;;

let account_compare (a : account) (b : account) =
  match User_id.compare a.owner b.owner with
  | 0 -> Provider_account_id.compare a.provider_account_id b.provider_account_id
  | order -> order
;;

let conversation_equal a b = Int.equal (conversation_compare a b) 0
let account_equal a b = Int.equal (account_compare a b) 0

let target_equal a b =
  match a, b with
  | Keeper_conversation a, Keeper_conversation b -> conversation_equal a b
  | Provider_account a, Provider_account b -> account_equal a b
  | Keeper_conversation _, Provider_account _ | Provider_account _, Keeper_conversation _ -> false
;;

let subject = function
  | Keeper_conversation { owner; conversation_id } ->
    Authz_records.Subject.Keeper_conversation { owner; conversation_id }
  | Provider_account { owner = _; provider_account_id } ->
    Authz_records.Subject.Credential provider_account_id
;;

type vendor_copy =
  | Removed
  | No_copy
  | May_remain

type conversation_failed_stage = Folder_not_removed

type account_failed_stage =
  | Key_not_removed
  | Home_not_removed

type purged =
  | Conversation_purged of
      { conversation : conversation
      ; vendor_copy : vendor_copy
      }
  | Account_purged of { account : account }

type failed =
  | Conversation_not_purged of
      { conversation : conversation
      ; failed_stage : conversation_failed_stage
      ; vendor_copy : vendor_copy
      }
  | Account_not_purged of
      { account : account
      ; failed_stage : account_failed_stage
      }

type t =
  | Purge_pending of { target : target }
  | Purged of purged
  | Purge_failed of failed

let target = function
  | Purge_pending { target } -> target
  | Purged (Conversation_purged { conversation; vendor_copy = _ })
  | Purge_failed (Conversation_not_purged { conversation; failed_stage = _; vendor_copy = _ }) ->
    Keeper_conversation conversation
  | Purged (Account_purged { account })
  | Purge_failed (Account_not_purged { account; failed_stage = _ }) -> Provider_account account
;;

let vendor_copy_equal a b =
  match a, b with
  | Removed, Removed | No_copy, No_copy | May_remain, May_remain -> true
  | Removed, (No_copy | May_remain)
  | No_copy, (Removed | May_remain)
  | May_remain, (Removed | No_copy) -> false
;;

let conversation_failed_stage_equal a b =
  match a, b with
  | Folder_not_removed, Folder_not_removed -> true
;;

let account_failed_stage_equal a b =
  match a, b with
  | Key_not_removed, Key_not_removed | Home_not_removed, Home_not_removed -> true
  | Key_not_removed, Home_not_removed | Home_not_removed, Key_not_removed -> false
;;

let purged_equal a b =
  match a, b with
  | Conversation_purged a, Conversation_purged b ->
    conversation_equal a.conversation b.conversation && vendor_copy_equal a.vendor_copy b.vendor_copy
  | Account_purged a, Account_purged b -> account_equal a.account b.account
  | Conversation_purged _, Account_purged _ | Account_purged _, Conversation_purged _ -> false
;;

let failed_equal a b =
  match a, b with
  | Conversation_not_purged a, Conversation_not_purged b ->
    conversation_equal a.conversation b.conversation
    && conversation_failed_stage_equal a.failed_stage b.failed_stage
    && vendor_copy_equal a.vendor_copy b.vendor_copy
  | Account_not_purged a, Account_not_purged b ->
    account_equal a.account b.account && account_failed_stage_equal a.failed_stage b.failed_stage
  | Conversation_not_purged _, Account_not_purged _ | Account_not_purged _, Conversation_not_purged _
    -> false
;;

let equal a b =
  match a, b with
  | Purge_pending a, Purge_pending b -> target_equal a.target b.target
  | Purged a, Purged b -> purged_equal a b
  | Purge_failed a, Purge_failed b -> failed_equal a b
  | Purge_pending _, (Purged _ | Purge_failed _)
  | Purged _, (Purge_pending _ | Purge_failed _)
  | Purge_failed _, (Purge_pending _ | Purged _) -> false
;;

let pending_label = "pending"
let purged_label = "purged"
let failed_label = "failed"
let keeper_conversation_label = "keeper_conversation"
let provider_account_label = "provider_account"

(* The label functions name every constructor, so the compiler stops at a new
   one. These lists are what a label is read back through. *)
let vendor_copies = [ Removed; No_copy; May_remain ]

let vendor_copy_label = function
  | Removed -> "removed"
  | No_copy -> "none"
  | May_remain -> "may_remain"
;;

let conversation_failed_stages = [ Folder_not_removed ]

let conversation_failed_stage_label = function
  | Folder_not_removed -> "folder_not_removed"
;;

let account_failed_stages = [ Key_not_removed; Home_not_removed ]

let account_failed_stage_label = function
  | Key_not_removed -> "key_not_removed"
  | Home_not_removed -> "home_not_removed"
;;

let body_of_conversation ({ owner; conversation_id } : conversation) =
  let* kind = Authz_body.string keeper_conversation_label in
  let* owner = Authz_body.string (User_id.to_string owner) in
  let* conversation_id = Authz_body.string (Conversation_id.to_string conversation_id) in
  Authz_body.object_ [ "type", kind; "owner", owner; "conversation_id", conversation_id ]
;;

let body_of_account ({ owner; provider_account_id } : account) =
  let* kind = Authz_body.string provider_account_label in
  let* owner = Authz_body.string (User_id.to_string owner) in
  let* provider_account_id =
    Authz_body.string (Provider_account_id.to_string provider_account_id)
  in
  Authz_body.object_ [ "type", kind; "owner", owner; "provider_account_id", provider_account_id ]
;;

let body_of_target = function
  | Keeper_conversation conversation -> body_of_conversation conversation
  | Provider_account account -> body_of_account account
;;

let to_body event =
  match event with
  | Purge_pending { target } ->
    let* event = Authz_body.string pending_label in
    let* target = body_of_target target in
    Authz_body.object_ [ "event", event; "target", target ]
  | Purged (Conversation_purged { conversation; vendor_copy }) ->
    let* event = Authz_body.string purged_label in
    let* target = body_of_conversation conversation in
    let* vendor_copy = Authz_body.string (vendor_copy_label vendor_copy) in
    Authz_body.object_ [ "event", event; "target", target; "vendor_copy", vendor_copy ]
  | Purged (Account_purged { account }) ->
    let* event = Authz_body.string purged_label in
    let* target = body_of_account account in
    Authz_body.object_ [ "event", event; "target", target ]
  | Purge_failed (Conversation_not_purged { conversation; failed_stage; vendor_copy }) ->
    let* event = Authz_body.string failed_label in
    let* target = body_of_conversation conversation in
    let* failed_stage = Authz_body.string (conversation_failed_stage_label failed_stage) in
    let* vendor_copy = Authz_body.string (vendor_copy_label vendor_copy) in
    Authz_body.object_
      [ "event", event; "target", target; "failed_stage", failed_stage; "vendor_copy", vendor_copy ]
  | Purge_failed (Account_not_purged { account; failed_stage }) ->
    let* event = Authz_body.string failed_label in
    let* target = body_of_account account in
    let* failed_stage = Authz_body.string (account_failed_stage_label failed_stage) in
    Authz_body.object_ [ "event", event; "target", target; "failed_stage", failed_stage ]
;;

type error =
  | Not_an_object
  | Unknown_event of string
  | Wrong_members
  | Unknown_target of string
  | Invalid_owner of Authz_id.error
  | Invalid_conversation_id of Authz_id.error
  | Invalid_provider_account_id of Authz_id.error
  | Unknown_failed_stage of string
  | Unknown_vendor_copy of string

let error_to_string = function
  | Not_an_object -> "the body of a purge record is an object"
  | Unknown_event label -> Printf.sprintf "%S is not an event of a purge" label
  | Wrong_members ->
    "the body of a pending purge has the members event and target; that of a purged \
     conversation event, target, and vendor_copy, and that of a failed one event, target, \
     failed_stage, and vendor_copy; that of a purged account event and target, and that of a \
     failed one event, target, and failed_stage; in this order, with target an object of \
     type, owner, and conversation_id or provider_account_id, and every other member a string"
  | Unknown_target label -> Printf.sprintf "%S is not a target of a purge" label
  | Invalid_owner error -> "the owner is not a valid user id: " ^ Authz_id.error_to_string error
  | Invalid_conversation_id error ->
    "the conversation id is not valid: " ^ Authz_id.error_to_string error
  | Invalid_provider_account_id error ->
    "the provider account id is not valid: " ^ Authz_id.error_to_string error
  | Unknown_failed_stage label ->
    Printf.sprintf "%S is not a stage that the purge of this target fails at" label
  | Unknown_vendor_copy label -> Printf.sprintf "%S is not a state of the vendor copy" label
;;

let of_label values label_of label =
  List.find_opt (fun value -> String.equal (label_of value) label) values
;;

let conversation_failed_stage_of label =
  Option.to_result
    ~none:(Unknown_failed_stage label)
    (of_label conversation_failed_stages conversation_failed_stage_label label)
;;

let account_failed_stage_of label =
  Option.to_result
    ~none:(Unknown_failed_stage label)
    (of_label account_failed_stages account_failed_stage_label label)
;;

let vendor_copy_of label =
  Option.to_result ~none:(Unknown_vendor_copy label) (of_label vendor_copies vendor_copy_label label)
;;

let owner_of owner = Result.map_error (fun error -> Invalid_owner error) (User_id.of_string owner)

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
           let* owner = owner_of owner in
           let* conversation_id =
             Result.map_error
               (fun error -> Invalid_conversation_id error)
               (Conversation_id.of_string conversation_id)
           in
           Ok (Keeper_conversation { owner; conversation_id })
         | None, (None | Some _) | Some _, None -> Error Wrong_members)
      | _ -> Error Wrong_members)
    else if String.equal kind provider_account_label
    then (
      match members with
      | [ ("owner", owner); ("provider_account_id", provider_account_id) ] ->
        (match Authz_body.string_value owner, Authz_body.string_value provider_account_id with
         | Some owner, Some provider_account_id ->
           let* owner = owner_of owner in
           let* provider_account_id =
             Result.map_error
               (fun error -> Invalid_provider_account_id error)
               (Provider_account_id.of_string provider_account_id)
           in
           Ok (Provider_account { owner; provider_account_id })
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

(* The target is read before the members that follow it, because its kind
   says which members those are. *)
let purged_of ~target members =
  let* target = target_of_body target in
  match target, members with
  | Keeper_conversation conversation, [ ("vendor_copy", vendor_copy) ] ->
    (match Authz_body.string_value vendor_copy with
     | Some vendor_copy ->
       let* vendor_copy = vendor_copy_of vendor_copy in
       Ok (Purged (Conversation_purged { conversation; vendor_copy }))
     | None -> Error Wrong_members)
  | Provider_account account, [] -> Ok (Purged (Account_purged { account }))
  | (Keeper_conversation _ | Provider_account _), _ -> Error Wrong_members
;;

let failed_of ~target members =
  let* target = target_of_body target in
  match target, members with
  | Keeper_conversation conversation, [ ("failed_stage", failed_stage); ("vendor_copy", vendor_copy) ]
    ->
    (match Authz_body.string_value failed_stage, Authz_body.string_value vendor_copy with
     | Some failed_stage, Some vendor_copy ->
       let* failed_stage = conversation_failed_stage_of failed_stage in
       let* vendor_copy = vendor_copy_of vendor_copy in
       Ok (Purge_failed (Conversation_not_purged { conversation; failed_stage; vendor_copy }))
     | None, (None | Some _) | Some _, None -> Error Wrong_members)
  | Provider_account account, [ ("failed_stage", failed_stage) ] ->
    (match Authz_body.string_value failed_stage with
     | Some failed_stage ->
       let* failed_stage = account_failed_stage_of failed_stage in
       Ok (Purge_failed (Account_not_purged { account; failed_stage }))
     | None -> Error Wrong_members)
  | (Keeper_conversation _ | Provider_account _), _ -> Error Wrong_members
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
      | ("target", target) :: members -> purged_of ~target members
      | _ -> Error Wrong_members)
    else if String.equal event failed_label
    then (
      match members with
      | ("target", target) :: members -> failed_of ~target members
      | _ -> Error Wrong_members)
    else Error (Unknown_event event)
  | Authz_body.Object _ -> Error Wrong_members
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> Error Not_an_object
;;
