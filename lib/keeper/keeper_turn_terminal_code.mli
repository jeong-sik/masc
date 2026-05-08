(** Closed sum type for the terminal code carried by a keeper turn's
    receipt. See RFC-0042 (`docs/rfc/RFC-0042-keeper-terminal-code-closed-sum.md`)
    for the full motivation.

    This module is introduced in PR-1 of the RFC migration and is
    intentionally inert: no caller in the tree references it yet.
    PR-2 swaps the existing typed bridges
    ([Keeper_execution_receipt.stale_terminal_reason_code],
    [keeper_agent_error.agent_error_terminal_reason_code]) to return
    values of type [t]; PR-3 swaps [Keeper_turn_terminal.t.code] from
    [string] to [t]; PR-4 converts the readers
    ([Keeper_execution_receipt] disposition mapping,
    [Keeper_passive_loop_detector.progress_class_of_terminal_reason_code])
    from [String.starts_with ~prefix] to exhaustive [match].

    Adding a new variant here is, by construction, a compile
    obligation for every match site after PR-4 lands. *)

type t =
  | Healthy
  (** Turn ended without error and reached the configured terminal
          cascade. *)
  | Stale_turn_timeout_idle
  (** [Keeper_registry.Stale_turn_timeout (Idle_turn _)]: the keeper
          was [Running] but never observed a turn-start. *)
  | Stale_turn_timeout_in_turn
  (** [Keeper_registry.Stale_turn_timeout (In_turn_hung _)]: a turn
          began and ran past its timeout threshold. *)
  | Stale_turn_timeout_noop
  (** [Keeper_registry.Stale_turn_timeout (Noop_failure_loop _)]:
          turns kept firing but produced no tool calls. *)
  | Stale_termination_storm
  (** [Keeper_registry.Stale_termination_storm]: cohort window
          escalation threshold reached. *)
  | Stale_fleet_batch
  (** [Keeper_registry.Stale_fleet_batch]: distinct keepers
          terminated inside the fleet batch window. *)
  | Oas_timeout_budget
  (** [Keeper_registry.Oas_timeout_budget_loop]: same keeper
          exhausted the OAS turn budget on consecutive cycles. *)
  | Heartbeat_failures (** [Keeper_registry.Heartbeat_consecutive_failures]. *)
  | Turn_failures (** [Keeper_registry.Turn_consecutive_failures]. *)
  | Provider_runtime_error of string
  (** [Keeper_registry.Provider_runtime_error]: payload is the
          original [code] field. *)
  | Tool_required_unsatisfied of string
  (** [Keeper_registry.Tool_required_unsatisfied]: payload is the
          original [code] field. *)
  | Ambiguous_partial_commit_post_commit_timeout
  (** [Keeper_registry.Ambiguous_partial_commit] with
          [kind = Post_commit_timeout]. *)
  | Ambiguous_partial_commit_post_commit_failure
  (** [Keeper_registry.Ambiguous_partial_commit] with
          [kind = Post_commit_failure]. *)
  | Fiber_unresolved (** [Keeper_registry.Fiber_unresolved]. *)
  | Exception_unhandled of string
  (** [Keeper_registry.Exception]: payload is the exception
          message. *)

(** Stable wire format. The strings produced here are byte-for-byte
    compatible with the strings emitted today by
    [Keeper_execution_receipt.stale_terminal_reason_code], so swapping
    callers in PR-2 / PR-3 does not change the JSON received by
    dashboards, [bin/masc-trace], or external consumers.

    The two [Stale_turn_timeout_*] variants and the two
    [Ambiguous_partial_commit_*] variants intentionally collapse to a
    single wire string each ([stale_turn_timeout],
    [ambiguous_partial_commit]) to preserve the existing cohort keys;
    the typed sub-class is still available to OCaml callers. *)
val to_wire : t -> string

(** Best-effort reverse of [to_wire]. Returned [None] for unknown wire
    codes; callers that previously consumed unknown codes via
    [String.starts_with ~prefix] should instead handle [None] (or wait
    for PR-4, which removes the consumer side of [of_wire] entirely).

    Some wire strings are lossy ([stale_turn_timeout] cannot
    distinguish [Idle_turn] / [In_turn_hung] / [Noop_failure_loop]).
    Such wire strings deserialise to a single canonical sub-class —
    documented in the [.ml] — to avoid silent fallthrough. *)
val of_wire : string -> t option

(** Canonical bridge from the existing typed source. Replaces
    [Keeper_execution_receipt.stale_terminal_reason_code] in PR-2.

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
