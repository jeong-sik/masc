(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module E = Authz_purge_event

module Target_map = Map.Make (struct
    type t = E.target

    let compare = E.target_compare
  end)

type status =
  | Pending of { earlier_vendor_copy : E.vendor_copy option }
  | Purged of { vendor_copy : E.vendor_copy }
  | Failed of
      { failed_stage : E.failed_stage
      ; vendor_copy : E.vendor_copy
      }

type t = status Target_map.t

let empty = Target_map.empty
let find t target = Target_map.find_opt target t

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

let owner = function
  | E.Keeper_conversation { owner; conversation_id = _ } -> owner
;;

(* The owner is checked before the status, so a principal learns nothing of
   the purge of another's target. Either order refuses the same records. *)
let start t ~author ~is_active target =
  if not (User_id.equal (owner target) author)
  then Error (Not_the_owner { target; author })
  else if not (is_active author)
  then Error (User_not_active author)
  else (
    match find t target with
    | None -> Ok (Target_map.add target (Pending { earlier_vendor_copy = None }) t)
    | Some (Failed { failed_stage = _; vendor_copy }) ->
      Ok (Target_map.add target (Pending { earlier_vendor_copy = Some vendor_copy }) t)
    | Some (Pending _) -> Error (Already_pending target)
    | Some (Purged _) -> Error (Already_purged target))
;;

(* A purge that went through ends once more when a restore brought back what
   it deleted (design 8.5-6). *)
let finish t target status =
  match find t target with
  | Some (Pending _ | Purged _) -> Ok (Target_map.add target status t)
  | Some (Failed _) | None -> Error (Not_started target)
;;

(* The author is matched before the event, so a branch says what each author
   may write. *)
let apply t ~(author : Author.t) ~is_active (event : E.t) =
  match author, event with
  | Author.Authenticated (Principal.Human id), E.Purge_pending { target } ->
    start t ~author:id ~is_active target
  | Author.Authenticated (Principal.Human id), (E.Purged _ | E.Purge_failed _) ->
    Error (Ended_by_a_principal id)
  | ( Author.Authenticated (Principal.Service _ as principal)
    , (E.Purge_pending _ | E.Purged _ | E.Purge_failed _) ) -> Error (Not_a_human principal)
  | Author.System_maintenance, E.Purged { target; vendor_copy } ->
    finish t target (Purged { vendor_copy })
  | Author.System_maintenance, E.Purge_failed { target; failed_stage; vendor_copy } ->
    finish t target (Failed { failed_stage; vendor_copy })
  | Author.System_maintenance, E.Purge_pending { target } ->
    Error (Started_by_the_maintenance target)
  | ( (Author.Local_operator | Author.System_cron | Author.System_migration)
    , (E.Purge_pending _ | E.Purged _ | E.Purge_failed _) ) -> Error (Not_a_purge_author author)
;;
