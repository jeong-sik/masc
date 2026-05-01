(** Error translation helpers for keeper Agent.run orchestration. *)

type keeper_internal_error =
  | Keeper_tool_surface_empty of
      { keeper_name : string
      ; turn_lane : string
      ; affordances : string list
      ; fallback_used : bool
      }
  | Keeper_tool_surface_mismatch of
      { keeper_name : string
      ; required_tools : string list
      ; missing_required_tools : string list
      ; visible_tools : string list
      }

let keeper_internal_error_prefix = "[keeper_internal_error] "

let keeper_internal_error_to_json = function
  | Keeper_tool_surface_empty { keeper_name; turn_lane; affordances; fallback_used } ->
    `Assoc
      [ "kind", `String "keeper_tool_surface_empty"
      ; "keeper_name", `String keeper_name
      ; "turn_lane", `String turn_lane
      ; "affordances", `List (List.map (fun value -> `String value) affordances)
      ; "fallback_used", `Bool fallback_used
      ]
  | Keeper_tool_surface_mismatch
      { keeper_name; required_tools; missing_required_tools; visible_tools } ->
    `Assoc
      [ "kind", `String "tool_surface_mismatch"
      ; "keeper_name", `String keeper_name
      ; "required_tools", `List (List.map (fun value -> `String value) required_tools)
      ; ( "missing_required_tools",
          `List (List.map (fun value -> `String value) missing_required_tools) )
      ; "visible_tools", `List (List.map (fun value -> `String value) visible_tools)
      ]

let sdk_error_of_keeper_internal_error err =
  Oas.Error.Internal
    (keeper_internal_error_prefix
     ^ Yojson.Safe.to_string (keeper_internal_error_to_json err))

let sdk_error_kind = function
  | Oas.Error.Api _ -> "api"
  | Oas.Error.Agent _ -> "agent"
  | Oas.Error.Mcp _ -> "mcp"
  | Oas.Error.Config _ -> "config"
  | Oas.Error.Serialization _ -> "serialization"
  | Oas.Error.Io _ -> "io"
  | Oas.Error.Orchestration _ -> "orchestration"
  | Oas.Error.Internal _ -> "internal"
  | Oas.Error.A2a _ -> "a2a"

(* Per-variant terminal_reason_code for Oas.Error.Api.
   Previously every API failure collapsed to "api_error", so 7 keepers
   stuck on different conditions (rate limit, overload, server fault,
   auth) all displayed the same dashboard chip and the broadcast
   payload could not differentiate them. Memory:
   no-collapse-richer-enum-at-sdk-boundary. *)
let api_error_terminal_reason_code (err : Oas.Error.api_error) : string =
  match err with
  | Oas.Retry.RateLimited _ -> "api_error_rate_limited"
  | Oas.Retry.Overloaded _ -> "api_error_overloaded"
  | Oas.Retry.ServerError { status; _ } ->
    Printf.sprintf "api_error_server:%d" status
  | Oas.Retry.AuthError _ -> "api_error_auth"
  | Oas.Retry.InvalidRequest _ -> "api_error_invalid_request"
  | Oas.Retry.NotFound _ -> "api_error_not_found"
  | Oas.Retry.ContextOverflow _ -> "api_error_context_overflow"
  | Oas.Retry.NetworkError _ -> "api_error_network"
  | Oas.Retry.Timeout _ -> "api_error_timeout"

(* Per-variant terminal_reason_code for Oas.Error.Agent.
   Previously every Agent failure collapsed to "agent_error", mirroring
   the old Api behaviour. Memory: no-collapse-richer-enum-at-sdk-boundary. *)
let agent_error_terminal_reason_code = function
  | Oas.Error.CompletionContractViolation { contract; _ } ->
    Printf.sprintf
      "completion_contract_violation:%s"
      (Oas.Completion_contract_id.to_string contract)
  | Oas.Error.MaxTurnsExceeded { turns; limit } ->
    Printf.sprintf
      "agent_error_max_turns_exceeded:turns=%d,limit=%d"
      turns limit
  | Oas.Error.ExitConditionMet { turn } ->
    Printf.sprintf
      "agent_error_exit_condition_met:turn=%d"
      turn
  | Oas.Error.UnrecognizedStopReason { reason } ->
    Printf.sprintf
      "agent_error_unrecognized_stop_reason:%s"
      reason
  | Oas.Error.TokenBudgetExceeded { kind; used; limit } ->
    Printf.sprintf
      "agent_error_token_budget_exceeded:kind=%s,used=%d,limit=%d"
      kind used limit
  | Oas.Error.CostBudgetExceeded { spent_usd; limit_usd } ->
    Printf.sprintf
      "agent_error_cost_budget_exceeded:spent_usd=%.2f,limit_usd=%.2f"
      spent_usd limit_usd
  | Oas.Error.IdleDetected { consecutive_idle_turns } ->
    Printf.sprintf
      "agent_error_idle_detected:consecutive_idle_turns=%d"
      consecutive_idle_turns
  | Oas.Error.ToolRetryExhausted { attempts; limit; detail = _ } ->
    Printf.sprintf
      "agent_error_tool_retry_exhausted:attempts=%d,limit=%d"
      attempts limit
  | Oas.Error.GuardrailViolation { validator; reason = _ } ->
    Printf.sprintf
      "agent_error_guardrail_violation:validator=%s"
      validator
  | Oas.Error.TripwireViolation { tripwire; reason = _ } ->
    Printf.sprintf
      "agent_error_tripwire_violation:tripwire=%s"
      tripwire

let terminal_reason_code_of_sdk_error = function
  | Oas.Error.Agent err -> agent_error_terminal_reason_code err
  | Oas.Error.Api err -> api_error_terminal_reason_code err
  | Oas.Error.Mcp _ -> "mcp_error"
  | Oas.Error.Config _ -> "config_error"
  | Oas.Error.Serialization _ -> "serialization_error"
  | Oas.Error.Io _ -> "io_error"
  | Oas.Error.Orchestration _ -> "orchestration_error"
  | Oas.Error.Internal _ -> "internal_error"
  | Oas.Error.A2a _ -> "a2a_error"

let receipt_outcome_kind_of_sdk_error = function
  | Oas.Error.Api (Oas.Retry.Timeout _) -> `Cancelled
  | Oas.Error.Agent (Oas.Error.MaxTurnsExceeded _) -> `Cancelled
  | Oas.Error.Agent (Oas.Error.IdleDetected _) -> `Cancelled
  | Oas.Error.Agent (Oas.Error.ExitConditionMet _) -> `Cancelled
  | _ -> `Error

let checkpoint_persistence_error ~keeper_name ~detail =
  Oas.Error.Internal
    (Printf.sprintf
       "keeper_checkpoint_persist_failed: keeper=%s detail=%s"
       keeper_name detail)

let cascade_outcome_of_observation = function
  | Some (obs : Oas_worker.cascade_observation) when obs.fallback_applied ->
    "passed_to_next_model"
  | Some _ -> "completed"
  | None -> "not_observed"
