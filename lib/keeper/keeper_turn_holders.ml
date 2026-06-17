(* keeper_turn_holders — provider timeout strike budget.

   Keeper turn execution no longer enters a keeper-owned runtime gate. This
   module only tracks provider timeout strikes per keeper.

   State is stored as an immutable [StringMap] under an [Atomic.t] so
   concurrent updates are lock-free. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
module StringMap = Set_util.StringMap

(* Provider timeout strikes. *)
let provider_timeout_strike_limit = 3

type provider_timeout_strike_outcome =
  | Provider_timeout_warn
  | Provider_timeout_soft_backoff

let classify_provider_timeout_strike ~strikes =
  if strikes >= provider_timeout_strike_limit then Provider_timeout_soft_backoff
  else Provider_timeout_warn
;;

let state : int StringMap.t Atomic.t = Atomic.make StringMap.empty

let update_state f =
  let rec loop () =
    let cur = Atomic.get state in
    let result, next = f cur in
    if Atomic.compare_and_set state cur next then result else loop ()
  in
  loop ()
;;

let bump_budget_exhaustion_seeded ~keeper_name ~prior_strikes =
  update_state (fun cur ->
    (* DET-OK: budget_exhaustions is advisory; absence = 0 strikes (no exhaustion recorded) *)
    let current = Option.value ~default:0 (StringMap.find_opt keeper_name cur) in
    let next = max current prior_strikes + 1 in
    next, StringMap.add keeper_name next cur)
;;

let bump_budget_exhaustion ~keeper_name =
  bump_budget_exhaustion_seeded ~keeper_name ~prior_strikes:0
;;

let reset_budget_exhaustion ~keeper_name =
  update_state (fun cur -> (), StringMap.remove keeper_name cur)
;;

let peek_budget_exhaustion_for_test ~keeper_name =
  update_state (fun cur ->
    (* DET-OK: budget_exhaustions is advisory; absence = 0 strikes (no exhaustion recorded) *)
    Option.value ~default:0 (StringMap.find_opt keeper_name cur), cur)
;;

let set_budget_exhaustion_for_test ~keeper_name ~strikes =
  update_state (fun cur -> (), StringMap.add keeper_name strikes cur)
;;
