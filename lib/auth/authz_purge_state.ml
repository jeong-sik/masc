(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module E = Authz_purge_event

module Conversation_map = Map.Make (struct
    type t = E.conversation

    let compare = E.conversation_compare
  end)

module Account_map = Map.Make (struct
    type t = E.account

    let compare = E.account_compare
  end)

type conversation_status =
  | Pending of { earlier_vendor_copy : E.vendor_copy option }
  | Purged of { vendor_copy : E.vendor_copy }
  | Failed of
      { failed_stage : E.conversation_failed_stage
      ; vendor_copy : E.vendor_copy
      }

type account_status =
  | Account_pending
  | Account_purged
  | Account_failed of { failed_stage : E.account_failed_stage }

(* One map for each kind of target, so the status of a target is of its
   kind. *)
type t =
  { conversations : conversation_status Conversation_map.t
  ; accounts : account_status Account_map.t
  }

let empty = { conversations = Conversation_map.empty; accounts = Account_map.empty }
let find_conversation t conversation = Conversation_map.find_opt conversation t.conversations
let conversations t = Conversation_map.bindings t.conversations
let find_account t account = Account_map.find_opt account t.accounts
let accounts t = Account_map.bindings t.accounts

type refusal =
  | Not_the_owner of
      { target : E.target
      ; author : User_id.t
      }
  | User_not_active of User_id.t
  | Already_pending of E.target
  | Already_purged of E.target
  | Not_started of E.target
  | Not_a_human of Principal.t
  | Ended_by_a_principal of User_id.t
  | Started_by_the_maintenance of E.target
  | Not_a_purge_author of Author.t

let target_label target = Subject.to_string (E.subject target)

let refusal_to_string = function
  | Not_the_owner { target; author } ->
    Printf.sprintf
      "%s starts the purge of %s, which they do not own"
      (User_id.to_string author)
      (target_label target)
  | User_not_active id ->
    Printf.sprintf "the principal %s is not active and starts no purge" (User_id.to_string id)
  | Already_pending target -> Printf.sprintf "a purge of %s is pending" (target_label target)
  | Already_purged target -> Printf.sprintf "%s was purged before" (target_label target)
  | Not_started target ->
    Printf.sprintf "no purge of %s is pending or went through, so none ends" (target_label target)
  | Not_a_human principal ->
    Printf.sprintf
      "the principal %s is a service and owns nothing to purge"
      (Principal.to_string principal)
  | Ended_by_a_principal id ->
    Printf.sprintf
      "the principal %s ends a purge, and only the system maintenance does"
      (User_id.to_string id)
  | Started_by_the_maintenance target ->
    Printf.sprintf
      "the system maintenance starts the purge of %s, and only its owner does"
      (target_label target)
  | Not_a_purge_author author -> Author.label author ^ " writes no purge record"
;;

let with_conversation t conversation status =
  { t with conversations = Conversation_map.add conversation status t.conversations }
;;

let with_account t account status = { t with accounts = Account_map.add account status t.accounts }

(* The log has the record that linked an account, so the owner the target
   names is the one of that record, or the target is no one's. *)
let owns ~account_owner ~author = function
  | E.Keeper_conversation { owner; conversation_id = _ } -> User_id.equal owner author
  | E.Provider_account { owner; provider_account_id } ->
    User_id.equal owner author
    &&
      (match account_owner provider_account_id with
      | Some linked_to -> User_id.equal linked_to owner
      | None -> false)
;;

let start_conversation t target conversation =
  match find_conversation t conversation with
  | None -> Ok (with_conversation t conversation (Pending { earlier_vendor_copy = None }))
  | Some (Failed { failed_stage = _; vendor_copy }) ->
    Ok (with_conversation t conversation (Pending { earlier_vendor_copy = Some vendor_copy }))
  | Some (Pending _) -> Error (Already_pending target)
  | Some (Purged _) -> Error (Already_purged target)
;;

let start_account t target account =
  match find_account t account with
  | None | Some (Account_failed _) -> Ok (with_account t account Account_pending)
  | Some Account_pending -> Error (Already_pending target)
  | Some Account_purged -> Error (Already_purged target)
;;

(* The owner is checked before the status, so a principal learns nothing of
   the purge of another's target. Either order refuses the same records. *)
let start t ~author ~is_active ~account_owner target =
  if not (owns ~account_owner ~author target)
  then Error (Not_the_owner { target; author })
  else if not (is_active author)
  then Error (User_not_active author)
  else (
    match target with
    | E.Keeper_conversation conversation -> start_conversation t target conversation
    | E.Provider_account account -> start_account t target account)
;;

(* A purge that went through ends once more when a restore brought back what
   it deleted (design 8.5-6). *)
let end_conversation t conversation status =
  match find_conversation t conversation with
  | Some (Pending _ | Purged _) -> Ok (with_conversation t conversation status)
  | Some (Failed _) | None -> Error (Not_started (E.Keeper_conversation conversation))
;;

let end_account t account status =
  match find_account t account with
  | Some (Account_pending | Account_purged) -> Ok (with_account t account status)
  | Some (Account_failed _) | None -> Error (Not_started (E.Provider_account account))
;;

(* The author is matched before the event, so a branch says what each author
   may write. *)
let apply t ~(author : Author.t) ~is_active ~account_owner (event : E.t) =
  match author, event with
  | Author.Authenticated (Principal.Human id), E.Purge_pending { target } ->
    start t ~author:id ~is_active ~account_owner target
  | Author.Authenticated (Principal.Human id), (E.Purged _ | E.Purge_failed _) ->
    Error (Ended_by_a_principal id)
  | ( Author.Authenticated (Principal.Service _ as principal)
    , (E.Purge_pending _ | E.Purged _ | E.Purge_failed _) ) -> Error (Not_a_human principal)
  | Author.System_maintenance, E.Purged (E.Conversation_purged { conversation; vendor_copy }) ->
    end_conversation t conversation (Purged { vendor_copy })
  | ( Author.System_maintenance
    , E.Purge_failed (E.Conversation_not_purged { conversation; failed_stage; vendor_copy }) ) ->
    end_conversation t conversation (Failed { failed_stage; vendor_copy })
  | Author.System_maintenance, E.Purged (E.Account_purged { account }) ->
    end_account t account Account_purged
  | Author.System_maintenance, E.Purge_failed (E.Account_not_purged { account; failed_stage }) ->
    end_account t account (Account_failed { failed_stage })
  | Author.System_maintenance, E.Purge_pending { target } ->
    Error (Started_by_the_maintenance target)
  | ( (Author.Local_operator | Author.System_cron)
    , (E.Purge_pending _ | E.Purged _ | E.Purge_failed _) ) -> Error (Not_a_purge_author author)
;;
