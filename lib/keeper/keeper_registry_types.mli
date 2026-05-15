(** Keeper_registry_types — pure type definitions extracted from
    Keeper_registry (3041 LoC godfile).

    Holds the [failure_reason] cluster + pure converters. State-mutating
    operations remain in Keeper_registry. Re-included by Keeper_registry
    so existing 126 callers continue to use [Keeper_registry.failure_reason]
    unchanged. *)

open Keeper_types

(** Structured failure reason for crash cohort detection. *)
type ambiguous_partial_commit_kind =
  | Post_commit_timeout
  | Post_commit_failure

type ambiguous_partial_commit = {
  kind : ambiguous_partial_commit_kind;
  detail : string;
}

(** Phase B PR-6 (2026-04-28): the stale watchdog's three distinct kill
    causes used to collapse into a single [Stale_turn_timeout of float]
    variant.  Operators / dashboards could not tell whether a kill was an
    idle stall (turn never started), an active turn hang (turn running
    too long), or a no-op failure loop (turn fired but produced no tool
    calls) — three different root causes that need different operator
    actions.  Splitting the payload preserves the [Stale_turn_timeout]
    cohort key so existing dashboards keep working, while exposing the
    typed sub-class to anything that wants to discriminate. *)
type stale_kill_class =
  | Idle_turn of { stall_seconds : float }
      (** [last_turn_ts] older than the idle threshold while the keeper
          phase is [Running] but no [current_turn_observation] is
          recorded. *)
  | In_turn_hung of {
      active_seconds : float;
      timeout_threshold : float;
    }
      (** A turn started ([current_turn_observation = Some]) and ran past
          [timeout_threshold] seconds. *)
  | Noop_failure_loop of { noop_count : int }
      (** Turns kept firing but produced no tool calls; the keepalive's
          [consecutive_noop_count] reached the watchdog threshold. *)

val stale_kill_class_to_string : stale_kill_class -> string
(** Operator-facing label.  Used in [failure_reason_to_string] for the
    [Stale_turn_timeout] arm and exposed for dashboards / metrics that
    want to attribute kills by class. *)

type failure_reason =
  | Heartbeat_consecutive_failures of int
  | Turn_consecutive_failures of int
  | Stale_turn_timeout of stale_kill_class
  | Stale_termination_storm of { count : int }
      (** #10765 Phase 2: latched when [record_stale_termination] returns a
          window count >= [escalation_threshold]. The supervisor's
          [`Crashed] branch checks this variant and skips [to_restart],
          persisting [meta.paused = true] instead so an operator must
          investigate the underlying cascade/provider/fd issue before
          resuming the keeper. *)
  | Stale_fleet_batch of { distinct_count : int }
      (** Latched when the stale watchdog observes several distinct keepers
          terminating inside the fleet batch window. This is a systemic
          cascade/provider/runtime signal, so the supervisor pauses affected
          keepers with auto-resume backoff instead of restarting each keeper
          independently into the same failure mode. *)
  | Oas_timeout_budget_loop of { count : int }
      (** Latched when the same keeper exhausts the OAS turn budget on
          consecutive cycles. This is a provider/cascade/runtime throughput
          failure, so the supervisor pauses instead of restarting into the
          same slow model and burning another multi-minute budget. *)
  | Provider_runtime_error of { code : string; detail : string }
      (** Latched from the keeper turn terminal reason when the provider,
          adapter, or cascade fails before useful keeper progress. A later
          idle watchdog should preserve this root cause instead of recasting
          the keeper as generically stale. *)
  | Tool_required_unsatisfied of { code : string; detail : string }
      (** Latched when an actionable required-tool turn returned no useful
          keeper tool progress. *)
  | Ambiguous_partial_commit of ambiguous_partial_commit
  | Fiber_unresolved
  | Exception of string

val ambiguous_partial_commit_kind_to_string :
  ambiguous_partial_commit_kind -> string

val failure_reason_to_string : failure_reason -> string

(** #10584: cohort key for grouping failures by variant (ignores
    parameters). [None] returns ["unknown"]. New variants added to
    [failure_reason] force a same-PR update of this function via
    OCaml's exhaustive-match check — Option B mitigation for the
    recurring P0 pattern (#10490, #10574). *)
val failure_reason_cohort_key : failure_reason option -> string

val stale_watchdog_failure_reason :
  prior:failure_reason option -> kill_class:stale_kill_class -> failure_reason option
(** Preserve authoritative terminal failure reasons when the stale watchdog
    fires after a failed turn, but do not carry stale-watchdog cohort labels
    across fresh watchdog kills. Storm/fleet labels are relatched only by the
    current threshold or batch detector. *)

(** Pure control-flow signal for immediate fiber termination (RFC-0002).
    Carries no state — failure reason must be pre-stored via
    [set_failure_reason] before raising. *)
exception Keeper_fiber_crash
