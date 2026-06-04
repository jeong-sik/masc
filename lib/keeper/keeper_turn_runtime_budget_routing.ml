(** Fail-open runtime routing helpers for keeper turn budgeting. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime
module EC = Keeper_error_classify

let next_fail_open_runtime_for_turn
      ~(base_runtime : string)
      ~(effective_runtime : string)
      ~(attempted_runtimes : string list)
      (err : Agent_sdk.Error.sdk_error)
  : EC.degraded_retry option
  =
  EC.degraded_rotation_after_recoverable_error
    ~base_runtime
    ~effective_runtime
    ~attempted_runtimes
    err

let sdk_error_kind = function
  | Agent_sdk.Error.Api _ -> "api"
  | Agent_sdk.Error.Provider _ -> "provider"
  | Agent_sdk.Error.Agent _ -> "agent"
  | Agent_sdk.Error.Mcp _ -> "mcp"
  | Agent_sdk.Error.Config _ -> "config"
  | Agent_sdk.Error.Serialization _ -> "serialization"
  | Agent_sdk.Error.Io _ -> "io"
  | Agent_sdk.Error.Orchestration _ -> "orchestration"
  | Agent_sdk.Error.Internal _ -> "internal"
