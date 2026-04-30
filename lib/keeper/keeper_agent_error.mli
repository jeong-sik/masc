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

(** Prefix prepended to the JSON-encoded internal-error message. *)
val keeper_internal_error_prefix : string

(** Encode a [keeper_internal_error] as a JSON object suitable for log
    payloads and dashboard surfaces. *)
val keeper_internal_error_to_json : keeper_internal_error -> Yojson.Safe.t

(** Wrap a [keeper_internal_error] inside [Oas.Error.Internal] so it
    flows through the standard SDK error channel with a recognizable
    prefix. *)
val sdk_error_of_keeper_internal_error : keeper_internal_error -> Oas.Error.sdk_error

(** Coarse categorisation of [Oas.Error.sdk_error] (for dashboards). *)
val sdk_error_kind : Oas.Error.sdk_error -> string

(** Per-variant terminal reason code for [Oas.Error.api_error] —
    differentiates rate_limited / overloaded / server / auth / etc. so
    that dashboard chips and broadcast payloads stay distinguishable.
    Memory: no-collapse-richer-enum-at-sdk-boundary. *)
val api_error_terminal_reason_code : Oas.Error.api_error -> string

(** Combined terminal-reason-code mapping for any [Oas.Error.sdk_error],
    delegating to [api_error_terminal_reason_code] for [Api] cases and
    embedding the contract id for completion-contract violations. *)
val terminal_reason_code_of_sdk_error : Oas.Error.sdk_error -> string

(** Receipt outcome for terminal SDK errors.  Provider timeouts map to
    [`Cancelled] to match [KeeperTurnFSM.tla] [ProviderTimeout], while
    all other SDK errors remain ordinary failed receipts. *)
val receipt_outcome_kind_of_sdk_error :
  Oas.Error.sdk_error -> Keeper_execution_receipt.outcome_kind

(** Structured internal error for post-turn checkpoint persistence
    failures.  Used to prevent an otherwise successful keeper turn from
    returning [Ok] when the replay checkpoint is not durable. *)
val checkpoint_persistence_error :
  keeper_name:string -> detail:string -> Oas.Error.sdk_error

(** Map an optional cascade observation to a textual outcome label
    ("passed_to_next_model" / "completed" / "not_observed"). *)
val cascade_outcome_of_observation :
  Oas_worker.cascade_observation option -> string
