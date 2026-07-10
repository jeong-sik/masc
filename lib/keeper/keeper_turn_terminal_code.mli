(** Closed sum type for the terminal code carried by a keeper turn's
    receipt. See RFC-0042 (`docs/rfc/RFC-0042-keeper-terminal-code-closed-sum.md`)
    for the full motivation.

    This module is introduced in PR-1 of the RFC migration and is
    intentionally inert: no caller in the tree references it yet.
    PR-2 swaps the existing typed bridges to return values of type [t];
    PR-3 swaps [Keeper_turn_terminal.t.code] from
    [string] to [t]; PR-4 converts the
    [Keeper_execution_receipt] disposition mapping from
    [String.starts_with ~prefix] to exhaustive [match].

    Adding a new variant here is, by construction, a compile
    obligation for every match site after PR-4 lands. *)

type t =
  | Healthy
  (** Turn ended without error and reached the configured terminal
          runtime. *)
  | Stale_turn_timeout_idle
  (** [Keeper_registry.Stale_turn_timeout (Idle_turn _)]: the keeper
          was [Running] but never observed a turn-start. *)
  | Stale_turn_timeout_in_turn
  (** Terminal code for a stale turn whose kill-class sub-class was not
          preserved on the wire (formerly the retired [In_turn_hung]); produced
          by the lossy [of_wire] / [of_failure_reason_option] canonicalisation. *)
  | Stale_turn_timeout_no_progress
  (** [Keeper_registry.Stale_turn_timeout (Mid_turn_no_progress _)]: a live
          turn stayed inside its outer timeout but stopped producing
          streaming/tool progress. *)
  | Stale_turn_timeout_noop
  (** [Keeper_registry.Stale_turn_timeout (Noop_failure_loop _)]:
          turns kept firing but produced no tool calls. *)
  | Stale_termination_storm
  (** [Keeper_registry.Stale_termination_storm]: cohort window
          escalation threshold reached. *)
  | Stale_fleet_batch
  (** [Keeper_registry.Stale_fleet_batch]: legacy fleet-batch wire value.
      Current fleet-batch detection is observation-only; fresh watchdog kills
      retain their per-keeper terminal code. *)
  | Heartbeat_failures (** [Keeper_registry.Heartbeat_consecutive_failures]. *)
  | Turn_failures (** [Keeper_registry.Turn_consecutive_failures]. *)
  | Provider_runtime_error of string
  (** [Keeper_registry.Provider_runtime_error]: payload is the
          original [code] field. *)
  | Ambiguous_partial_commit_post_commit_timeout
  (** [Keeper_registry.Ambiguous_partial_commit] with
          [kind = Post_commit_timeout]. *)
  | Ambiguous_partial_commit_post_commit_failure
  (** [Keeper_registry.Ambiguous_partial_commit] with
          [kind = Post_commit_failure]. *)
  | Fiber_unresolved (** [Keeper_registry.Fiber_unresolved]. *)
  | Turn_overflow_pause
  (** [Keeper_registry.Turn_overflow_pause]: context overflow with
          compact retry exhausted; keeper auto-paused. *)
  | Turn_livelock_pause
  (** [Keeper_registry.Turn_livelock_pause]: turn livelock guard
          blocked dispatch; keeper auto-paused. *)
  | Operator_interrupt
  (** [Keeper_registry.Operator_interrupt]: the current turn was cancelled
          by an explicit operator request, typically from the dashboard
          "stop current turn" action. *)
  | Exception_unhandled of string
  (** [Keeper_registry.Exception]: payload is the exception
          message. *)
  | Sdk_error of string
  (** Catch-all for [Agent_sdk.Error.t] wire strings (agent / api /
          mcp / config / serialization / io / orchestration / a2a /
          internal). The payload is the existing parametrised wire
          format produced by [Keeper_agent_error.terminal_reason_code_of_sdk_error]
          (e.g. ["agent_error_max_turns_exceeded:turns=10,limit=10"],
          ["completion_contract_violation:completion_contract"],
          ["api_error_server:502"]). PR-2.5 wraps the existing typed
          accessors in this variant so the typed bridge becomes a
          single source of truth for [Keeper_turn_terminal.t.code]
          field swap (PR-3). RFC-0042 §5.2 explicitly defers refining
          this into per-variant constructors (~25-variant explosion);
          a follow-up RFC will split it once production traces narrow
          the actual sub-kind set. *)

(** Stable wire format. The strings produced here are byte-for-byte
    compatible with the receipt JSON consumed by dashboards,
    [bin/masc-trace], and external consumers.

    The [Stale_turn_timeout_*] variants and the two
    [Ambiguous_partial_commit_*] variants intentionally collapse to a
    single wire string each ([stale_turn_timeout],
    [ambiguous_partial_commit]) to preserve the existing cohort keys;
    the typed sub-class is still available to OCaml callers. *)
val to_wire : t -> string

(** Best-effort reverse of [to_wire]. Returned [None] for unknown wire
    codes; callers that previously consumed unknown codes via
    [String.starts_with ~prefix] should instead handle [None] (or wait
    for PR-4, which removes the consumer side of [of_wire] entirely).

    Some wire strings are lossy ([stale_turn_timeout] cannot distinguish
    [Idle_turn] / [Mid_turn_no_progress] / [Noop_failure_loop]).
    Such wire strings deserialise to a single canonical sub-class —
    documented in the [.ml] — to avoid silent fallthrough. *)
val of_wire : string -> t option

(** Canonical bridge from the existing typed source.

    Exhaustive over [Keeper_registry.failure_reason]: adding a new
    constructor there is a compile error here, which is the property
    this RFC is meant to provide. *)
val of_failure_reason : Keeper_registry.failure_reason -> t

(** Option-wrapped bridge. [None] is the legacy convention for a
    keeper that became stale without a recorded [failure_reason]; the
    pre-RFC string emitter mapped this to ["stale_turn_timeout"]. We
    canonicalise to [Stale_turn_timeout_in_turn] so [to_wire] reproduces
    the same bytes. PR-3 narrows callers to a non-option representation
    where applicable.

    @since 0.193.0 *)
val of_failure_reason_option : Keeper_registry.failure_reason option -> t

(** Wrap an [Agent_sdk.Error.t] wire string into the typed bridge.
    The argument is the legacy parametrised wire string produced by
    [Keeper_agent_error.terminal_reason_code_of_sdk_error] /
    [agent_error_terminal_reason_code] /
    [api_error_terminal_reason_code]. Returns [Sdk_error s] verbatim;
    [to_wire] reproduces [s] byte-for-byte.

    PR-2.5 introduces this as a thin typed bridge; a follow-up RFC
    will replace [s] with a closed sub-sum once the parametrised
    sub-kinds (`turns=N,limit=M`, `kind=token,used=K,limit=L`, …) are
    inventoried from production traces.

    @since 0.193.1 *)
val of_sdk_error_wire : string -> t
