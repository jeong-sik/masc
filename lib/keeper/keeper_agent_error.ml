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
      ; ( "missing_required_tools"
        , `List (List.map (fun value -> `String value) missing_required_tools) )
      ; "visible_tools", `List (List.map (fun value -> `String value) visible_tools)
      ]
;;

let sdk_error_of_keeper_internal_error err =
  Agent_sdk.Error.Internal
    (keeper_internal_error_prefix
     ^ Yojson.Safe.to_string (keeper_internal_error_to_json err))
;;

let sdk_error_kind = function
  | Agent_sdk.Error.Api _ -> "api"
  | Agent_sdk.Error.Agent _ -> "agent"
  | Agent_sdk.Error.Mcp _ -> "mcp"
  | Agent_sdk.Error.Config _ -> "config"
  | Agent_sdk.Error.Serialization _ -> "serialization"
  | Agent_sdk.Error.Io _ -> "io"
  | Agent_sdk.Error.Orchestration _ -> "orchestration"
  | Agent_sdk.Error.A2a _ -> "a2a"
  | Agent_sdk.Error.Internal _ -> "internal"
;;

(* Per-variant terminal_reason_code for Agent_sdk.Error.Api.
   Previously every API failure collapsed to "api_error", so 7 keepers
   stuck on different conditions (rate limit, overload, server fault,
   auth) all displayed the same dashboard chip and the broadcast
   payload could not differentiate them. Memory:
   no-collapse-richer-enum-at-sdk-boundary. *)
let api_error_terminal_reason_code (err : Agent_sdk.Error.api_error) : string =
  match err with
  | Agent_sdk.Retry.RateLimited _ -> "api_error_rate_limited"
  | Agent_sdk.Retry.Overloaded _ -> "api_error_overloaded"
  | Agent_sdk.Retry.ServerError { status; _ } ->
    Printf.sprintf "api_error_server:%d" status
  | Agent_sdk.Retry.AuthError _ -> "api_error_auth"
  | Agent_sdk.Retry.InvalidRequest _ -> "api_error_invalid_request"
  | Agent_sdk.Retry.NotFound _ -> "api_error_not_found"
  | Agent_sdk.Retry.ContextOverflow _ -> "api_error_context_overflow"
  | Agent_sdk.Retry.NetworkError _ -> "api_error_network"
  | Agent_sdk.Retry.Timeout _ -> "api_error_timeout"
;;

(* Per-variant terminal_reason_code for Agent_sdk.Error.Agent.
   Previously every Agent failure collapsed to "agent_error", mirroring
   the old Api behaviour. Memory: no-collapse-richer-enum-at-sdk-boundary. *)
let agent_error_terminal_reason_code = function
  | Agent_sdk.Error.CompletionContractViolation { contract; _ } ->
    Printf.sprintf
      "completion_contract_violation:%s"
      (Agent_sdk.Completion_contract_id.to_string contract)
  | Agent_sdk.Error.MaxTurnsExceeded { turns; limit } ->
    Printf.sprintf "agent_error_max_turns_exceeded:turns=%d,limit=%d" turns limit
  | Agent_sdk.Error.ExitConditionMet { turn } ->
    Printf.sprintf "agent_error_exit_condition_met:turn=%d" turn
  | Agent_sdk.Error.UnrecognizedStopReason { reason } ->
    Printf.sprintf "agent_error_unrecognized_stop_reason:%s" reason
  | Agent_sdk.Error.TokenBudgetExceeded { kind; used; limit } ->
    Printf.sprintf
      "agent_error_token_budget_exceeded:kind=%s,used=%d,limit=%d"
      kind
      used
      limit
  | Agent_sdk.Error.CostBudgetExceeded { spent_usd; limit_usd } ->
    Printf.sprintf
      "agent_error_cost_budget_exceeded:spent_usd=%.2f,limit_usd=%.2f"
      spent_usd
      limit_usd
  | Agent_sdk.Error.IdleDetected { consecutive_idle_turns } ->
    Printf.sprintf
      "agent_error_idle_detected:consecutive_idle_turns=%d"
      consecutive_idle_turns
  | Agent_sdk.Error.ToolRetryExhausted { attempts; limit; detail = _ } ->
    Printf.sprintf "agent_error_tool_retry_exhausted:attempts=%d,limit=%d" attempts limit
  | Agent_sdk.Error.GuardrailViolation { validator; reason = _ } ->
    Printf.sprintf "agent_error_guardrail_violation:validator=%s" validator
  | Agent_sdk.Error.TripwireViolation { tripwire; reason = _ } ->
    Printf.sprintf "agent_error_tripwire_violation:tripwire=%s" tripwire
;;

let terminal_reason_code_of_sdk_error = function
  | Agent_sdk.Error.Agent err -> agent_error_terminal_reason_code err
  | Agent_sdk.Error.Api err -> api_error_terminal_reason_code err
  | Agent_sdk.Error.Mcp _ -> "mcp_error"
  | Agent_sdk.Error.Config _ -> "config_error"
  | Agent_sdk.Error.Serialization _ -> "serialization_error"
  | Agent_sdk.Error.Io _ -> "io_error"
  | Agent_sdk.Error.Orchestration _ -> "orchestration_error"
  | Agent_sdk.Error.A2a _ -> "a2a_error"
  | Agent_sdk.Error.Internal _ -> "internal_error"
;;

(* RFC-0042 PR-2.5: typed bridge for SDK errors. The wire format is the
   existing parametrised string (kept by [terminal_reason_code_of_sdk_error]
   above) wrapped in [Keeper_turn_terminal_code.Sdk_error]. PR-3 swaps
   [Keeper_turn_terminal.t.code] from [string] to [Keeper_turn_terminal_code.t]
   and uses these typed accessors at every emit site. RFC §5.2 defers the
   sub-sum split (per-variant constructors for [MaxTurnsExceeded] etc.) to
   a follow-up RFC. *)
let terminal_reason_code_of_sdk_error_typed err =
  Keeper_turn_terminal_code.of_sdk_error_wire (terminal_reason_code_of_sdk_error err)
;;

let api_error_terminal_reason_code_typed err =
  Keeper_turn_terminal_code.of_sdk_error_wire (api_error_terminal_reason_code err)
;;

let receipt_outcome_kind_of_sdk_error = function
  | Agent_sdk.Error.Api (Agent_sdk.Retry.Timeout _) -> `Cancelled
  | Agent_sdk.Error.Agent (Agent_sdk.Error.MaxTurnsExceeded _) -> `Cancelled
  | Agent_sdk.Error.Agent (Agent_sdk.Error.IdleDetected _) -> `Cancelled
  | Agent_sdk.Error.Agent (Agent_sdk.Error.ExitConditionMet _) -> `Cancelled
  | Agent_sdk.Error.Agent (Agent_sdk.Error.TokenBudgetExceeded _) -> `Error
  | Agent_sdk.Error.Agent (Agent_sdk.Error.CostBudgetExceeded _) -> `Error
  | Agent_sdk.Error.Agent (Agent_sdk.Error.UnrecognizedStopReason _) -> `Error
  | Agent_sdk.Error.Agent (Agent_sdk.Error.ToolRetryExhausted _) -> `Error
  | Agent_sdk.Error.Agent (Agent_sdk.Error.CompletionContractViolation _) -> `Error
  | Agent_sdk.Error.Agent (Agent_sdk.Error.GuardrailViolation _) -> `Error
  | Agent_sdk.Error.Agent (Agent_sdk.Error.TripwireViolation _) -> `Error
  | Agent_sdk.Error.Api _ -> `Error
  | Agent_sdk.Error.Mcp _ -> `Error
  | Agent_sdk.Error.Config _ -> `Error
  | Agent_sdk.Error.Serialization _ -> `Error
  | Agent_sdk.Error.Io _ -> `Error
  | Agent_sdk.Error.Orchestration _ -> `Error
  | Agent_sdk.Error.A2a _ -> `Error
  | Agent_sdk.Error.Internal _ -> `Error
;;

let checkpoint_persistence_error ~keeper_name ~detail =
  Agent_sdk.Error.Internal
    (Printf.sprintf
       "keeper_checkpoint_persist_failed: keeper=%s detail=%s"
       keeper_name
       detail)
;;

let cascade_outcome_of_observation = function
  | Some (obs : Cascade_legacy_runner.cascade_observation) when obs.fallback_applied ->
    "passed_to_next_model"
  | Some _ -> "completed"
  | None -> "not_observed"
;;
