(** Typed terminal causes produced by the current Keeper runtime.

    Adding a constructor is a compile obligation for every match site.
    Wire decoding is deliberately narrower than wire encoding: a wire value
    that discarded typed evidence cannot reconstruct a cause. *)

(** Typed observation derived where the original agent-core error is still
    in hand, carried alongside the verbatim wire (RFC-0371 §6.1(3)).
    [None] on values rehydrated from persisted wire strings. *)
type agent_core_timeout =
  { phase : Llm_provider.Http_client.timeout_phase option }

type t =
  | Healthy
  (** Turn ended without error and reached the configured terminal
          runtime. *)
  | Stale_termination_storm
  (** [Keeper_registry.Stale_termination_storm]: cohort window
          escalation threshold reached. *)
  | Provider_runtime_error of string
  (** [Keeper_registry.Provider_runtime_error]: payload is the
          original [code] field. *)
  | Fiber_unresolved (** [Keeper_registry.Fiber_unresolved]. *)
  | Turn_overflow_failure
  (** [Keeper_registry.Turn_overflow_failure]: the turn's request
          exceeded the context window; the failure is recorded without
          changing Keeper pause state. *)
  | Operator_interrupt
  (** [Keeper_registry.Operator_interrupt]: the current turn was cancelled
          by an explicit operator request, typically from the dashboard
          "stop current turn" action. *)
  | Exception_unhandled of string
  (** [Keeper_registry.Exception]: payload is the exception
          message. *)
  | Agent_core_error of
      { wire : string
      ; timeout : agent_core_timeout option
      }
  (** Catch-all for [Agent_core.Error.t] wire strings (agent / api /
          mcp / config / serialization / io / orchestration / a2a /
          internal). The payload is the existing parametrised wire
          format produced by [Keeper_agent_error.terminal_reason_code_of_core_error]
          (e.g. ["api_error_server:502"]). PR-2.5 wraps the existing typed
          accessors in this variant so the typed bridge becomes a
          single source of truth for [Keeper_turn_terminal.t.code]
          field swap (PR-3). RFC-0042 §5.2 explicitly defers refining
          this into per-variant constructors (~25-variant explosion);
          a follow-up RFC will split it once production traces narrow
          the actual sub-kind set. *)

(** Stable wire format consumed by receipt JSON, dashboards,
    [bin/masc-trace], and external consumers. *)
val to_wire : t -> string

(** Decode only current wire values with a one-to-one typed meaning.

    Lossy values such as [exception], payload-bearing codes, and unknown strings
    return [None]. They must remain display-only or produce a typed decode
    failure; this function never invents missing evidence. *)
val of_wire_exact : string -> t option

(** Wrap an [Agent_core.Error.t] wire string produced by
    [Keeper_agent_error.terminal_reason_code_of_core_error] /
    [agent_error_terminal_reason_code] /
    [api_error_terminal_reason_code]. Returns [Agent_core_error s] verbatim;
    [to_wire] reproduces [s] byte-for-byte. *)
val of_core_error_wire : string -> t

(** Like {!of_core_error_wire} but with the typed timeout observation the
    producer derived from the original error. The wire stays verbatim. *)
val of_core_error : wire:string -> timeout:agent_core_timeout option -> t
