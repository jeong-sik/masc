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
      (err : Masc_agent_core.Error.sdk_error)
  : EC.degraded_retry option
  =
  EC.degraded_rotation_after_recoverable_error
    ~base_runtime
    ~effective_runtime
    ~attempted_runtimes
    err

let sdk_error_kind = function
  | Masc_agent_core.Error.Api _ -> "api"
  | Masc_agent_core.Error.Provider _ -> "provider"
  | Masc_agent_core.Error.Agent _ -> "agent"
  | Masc_agent_core.Error.Mcp _ -> "mcp"
  | Masc_agent_core.Error.Config _ -> "config"
  | Masc_agent_core.Error.Serialization _ -> "serialization"
  | Masc_agent_core.Error.Io _ -> "io"
  | Masc_agent_core.Error.Orchestration _ -> "orchestration"
  | Masc_agent_core.Error.Internal _ -> "internal"
