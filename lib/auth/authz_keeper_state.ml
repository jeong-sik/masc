(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module E = Authz_keeper_event
module Keeper_map = Map.Make (Keeper_id)

type keeper =
  { owner : User_id.t
  ; policy_id : Policy_id.t
  ; turn_scope : Authorization_scope.t
  ; runtime : Runtime_id.t option
  }

type t = keeper Keeper_map.t

let empty = Keeper_map.empty
let find t keeper_id = Keeper_map.find_opt keeper_id t

let owned_by t user_id =
  Keeper_map.bindings t |> List.filter (fun (_, keeper) -> User_id.equal keeper.owner user_id)
;;

type refusal =
  | Already_made of Keeper_id.t
  | Policy_named_before of Policy_id.t
  | Not_made of Keeper_id.t
  | Made_for_another of
      { author : User_id.t
      ; user_id : User_id.t
      }
  | Assigned_by_another of
      { author : User_id.t
      ; keeper_id : Keeper_id.t
      ; owner : User_id.t
      }
  | Runtime_not_made of Runtime_id.t
  | Not_the_owners_runtime of
      { keeper_id : Keeper_id.t
      ; runtime_id : Runtime_id.t
      ; runtime_owner : User_id.t
      }
  | User_not_active of User_id.t
  | Not_a_human of Principal.t
  | Not_a_keeper_author of Author.t

let refusal_to_string = function
  | Already_made id -> Printf.sprintf "the Keeper %s was made before" (Keeper_id.to_string id)
  | Policy_named_before id ->
    Printf.sprintf "the policy %s was named by another Keeper before" (Policy_id.to_string id)
  | Not_made id ->
    Printf.sprintf "the Keeper %s was never made and is given no Runtime" (Keeper_id.to_string id)
  | Made_for_another { author; user_id } ->
    Printf.sprintf
      "%s makes a Keeper for %s, and a principal makes a Keeper only for themselves"
      (User_id.to_string author)
      (User_id.to_string user_id)
  | Assigned_by_another { author; keeper_id; owner } ->
    Printf.sprintf
      "%s gives a Runtime to the Keeper %s of %s, and only its owner does"
      (User_id.to_string author)
      (Keeper_id.to_string keeper_id)
      (User_id.to_string owner)
  | Runtime_not_made id ->
    Printf.sprintf "the Runtime %s was never made and has no owner" (Runtime_id.to_string id)
  | Not_the_owners_runtime { keeper_id; runtime_id; runtime_owner } ->
    Printf.sprintf
      "the Runtime %s is of %s, and the Keeper %s is given only a Runtime of its owner"
      (Runtime_id.to_string runtime_id)
      (User_id.to_string runtime_owner)
      (Keeper_id.to_string keeper_id)
  | User_not_active id ->
    Printf.sprintf "the principal %s is not active and writes no Keeper record" (User_id.to_string id)
  | Not_a_human principal ->
    Printf.sprintf
      "the principal %s is a service and writes no Keeper record"
      (Principal.to_string principal)
  | Not_a_keeper_author author -> Author.label author ^ " writes no Keeper record"
;;

let names_policy t policy_id =
  Keeper_map.exists (fun _ keeper -> Policy_id.equal keeper.policy_id policy_id) t
;;

let make t ~author ~is_active ~keeper_id ~user_id ~policy_id ~turn_scope =
  if Keeper_map.mem keeper_id t
  then Error (Already_made keeper_id)
  else if names_policy t policy_id
  then Error (Policy_named_before policy_id)
  else if not (User_id.equal author user_id)
  then Error (Made_for_another { author; user_id })
  else if not (is_active user_id)
  then Error (User_not_active user_id)
  else Ok (Keeper_map.add keeper_id { owner = user_id; policy_id; turn_scope; runtime = None } t)
;;

let assign t ~author ~is_active ~runtime_owner ~keeper_id ~runtime_id =
  match Keeper_map.find_opt keeper_id t with
  | None -> Error (Not_made keeper_id)
  | Some keeper ->
    if not (User_id.equal author keeper.owner)
    then Error (Assigned_by_another { author; keeper_id; owner = keeper.owner })
    else if not (is_active author)
    then Error (User_not_active author)
    else (
      match runtime_owner runtime_id with
      | None -> Error (Runtime_not_made runtime_id)
      | Some runtime_owner ->
        if User_id.equal runtime_owner keeper.owner
        then Ok (Keeper_map.add keeper_id { keeper with runtime = Some runtime_id } t)
        else Error (Not_the_owners_runtime { keeper_id; runtime_id; runtime_owner }))
;;

(* The author is matched before the event, so a branch says what each author
   may write. *)
let apply t ~(author : Author.t) ~is_active ~runtime_owner (event : E.t) =
  match author, event with
  | Author.Authenticated (Principal.Human id), E.Made { keeper_id; user_id; policy_id; turn_scope } ->
    make t ~author:id ~is_active ~keeper_id ~user_id ~policy_id ~turn_scope
  | Author.Authenticated (Principal.Human id), E.Assigned { keeper_id; runtime_id } ->
    assign t ~author:id ~is_active ~runtime_owner ~keeper_id ~runtime_id
  | Author.Authenticated (Principal.Service _ as principal), (E.Made _ | E.Assigned _) ->
    Error (Not_a_human principal)
  | ( ( Author.Local_operator
      | Author.System_cron
      | Author.System_maintenance
      | Author.System_migration )
    , (E.Made _ | E.Assigned _) ) -> Error (Not_a_keeper_author author)
;;
