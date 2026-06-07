(* keeper_turn_holders — provider timeout strike budget.

   Keeper turn execution no longer enters a keeper-owned runtime gate. This
   module only tracks provider timeout strikes per keeper. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(* Provider timeout strikes. *)
let provider_timeout_strike_limit = 3

type provider_timeout_strike_outcome =
  | Provider_timeout_warn
  | Provider_timeout_soft_backoff

let classify_provider_timeout_strike ~strikes =
  if strikes >= provider_timeout_strike_limit then Provider_timeout_soft_backoff
  else Provider_timeout_warn
;;

let budget_exhaustions_mutex = Stdlib.Mutex.create ()
let budget_exhaustions : (string, int) Hashtbl.t = Hashtbl.create 16

let update_budget_exhaustions f =
  Stdlib.Mutex.lock budget_exhaustions_mutex;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock budget_exhaustions_mutex)
    f
;;

let bump_budget_exhaustion_seeded ~keeper_name ~prior_strikes =
  update_budget_exhaustions (fun () ->
    (* DET-OK: budget_exhaustions is advisory; absence = 0 strikes (no exhaustion recorded) *)
    let current = Option.value ~default:0 (Hashtbl.find_opt budget_exhaustions keeper_name) in
    let next = max current prior_strikes + 1 in
    Hashtbl.replace budget_exhaustions keeper_name next;
    next)
;;

let bump_budget_exhaustion ~keeper_name =
  bump_budget_exhaustion_seeded ~keeper_name ~prior_strikes:0
;;

let reset_budget_exhaustion ~keeper_name =
  update_budget_exhaustions (fun () ->
    Hashtbl.remove budget_exhaustions keeper_name)
;;

let peek_budget_exhaustion_for_test ~keeper_name =
  update_budget_exhaustions (fun () ->
    (* DET-OK: budget_exhaustions is advisory; absence = 0 strikes (no exhaustion recorded) *)
    Option.value ~default:0 (Hashtbl.find_opt budget_exhaustions keeper_name))
;;

let set_budget_exhaustion_for_test ~keeper_name ~strikes =
  update_budget_exhaustions (fun () ->
    Hashtbl.replace budget_exhaustions keeper_name strikes)
;;
