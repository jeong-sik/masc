(** Typed fail-open runtime rotation helpers. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime
module EC = Keeper_error_classify

let next_fail_open_runtime_for_turn
      ~(base_runtime : string)
      ~(effective_runtime : string)
      ~(attempted_runtimes : string list)
      (err : Agent_core.Error.t)
  : EC.degraded_retry option
  =
  EC.degraded_rotation_after_recoverable_error
    ~base_runtime
    ~effective_runtime
    ~attempted_runtimes
    err
