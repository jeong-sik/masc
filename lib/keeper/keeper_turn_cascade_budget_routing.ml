(** Fail-open cascade routing helpers for keeper turn budgeting. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime
module EC = Keeper_error_classify

let next_fail_open_cascade_for_turn
      ~(base_cascade : string)
      ~(effective_cascade : string)
      ~(tool_requirement : Keeper_agent_tool_surface.tool_requirement)
      ~(attempted_cascades : string list)
      (err : Agent_sdk.Error.sdk_error)
  : EC.degraded_retry option
  =
  let fallback_hint =
    Keeper_cascade_profile.fallback_cascade_for effective_cascade
  in
  EC.degraded_rotation_after_recoverable_error
    ?fallback_hint
    ~base_cascade
    ~effective_cascade
    ~tool_requirement
    ~attempted_cascades
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
  | Agent_sdk.Error.A2a _ -> "a2a"
  | Agent_sdk.Error.Internal _ -> "internal"

let record_turn_failure_stress
      ~(meta : keeper_meta)
      ~(is_auto_recoverable : bool)
      ~(consecutive : int)
      ~(threshold : int)
      ~(err : Agent_sdk.Error.sdk_error)
  : unit
  =
  let room_id =
    match meta.joined_room_ids with
    | room_id :: _ -> room_id
    | [] -> ""
  in
  Agent_stress.record
    { agent_name = meta.name
    ; room_id
    ; kind =
        Turn_failure
          { consecutive
          ; threshold
          ; counted_toward_crash = not is_auto_recoverable
          ; recoverable = is_auto_recoverable
          ; error_kind = Some (Agent_stress.error_kind_of_string (sdk_error_kind err))
          }
    ; (* NDT-OK: stress telemetry records wall-clock observation time only;
         failure classification is derived above. *)
      timestamp = Unix.gettimeofday ()
    }
