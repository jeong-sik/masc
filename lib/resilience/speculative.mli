(** Speculative — branch-execution scaffolding.

    Cycle 27 / Tier A11 (partial — types + sequential simulator;
    parallel race in companion follow-up A11b).

    {1 What this module is}

    A scaffolding for speculative execution: try several candidate
    branches, pick the first that succeeds within budget, abort
    the rest. Lifts the keeper out of strictly-sequential planning
    when several plausible paths exist (per the
    [Recovery.AmbiguityError] mode and the design doc's
    "Speculate" recovery strategy slot).

    {b STUB STATUS (Tier A11 first PR)}: the {!execute} below is
    a sequential simulator. Real Eio.Switch-based parallel race
    + abort lands in Tier A11b — that PR adds the [eio] dependency
    to [lib/resilience/dune] and integrates with the keeper's
    structured-concurrency entry point. The signatures here are
    deliberately aligned with the future parallel implementation
    so the swap is API-compatible.

    {1 Why a sequential simulator first}

    A standalone Eio dependency on [lib/resilience] would expand
    the build closure for every consumer of [Recovery] /
    [Confidence]. Keeping A11's first PR Eio-free preserves the
    file-disjoint property declared in plan §16, and lets type
    machinery + selection contract land independently of Eio
    integration concerns.

    @stability Evolving (stub)
    @since 0.18.10 *)

(** {1 Budget policy}

    Caps applied to a single {!execute} invocation. *)

type budget_policy = {
  time_cap_ms : int;
      (** Hard ceiling on wall-clock time per invocation. The
          sequential simulator does not enforce this; the future
          parallel implementation will. *)
  tokens_cap : int option;
      (** Optional token budget; [None] is unbounded. The simulator
          does not enforce; informs callers that hold the budget
          on the keeper side. *)
  branches_max : int;
      (** Maximum number of branches to try. {!execute} truncates
          the branch list to this length before iterating. Set
          to [0] to short-circuit (returns [GracefulFailure]
          with empty [errors]). *)
}

val default_budget : budget_policy
(** [{ time_cap_ms = 30_000; tokens_cap = None; branches_max = 4 }]. *)

(** {1 Branch}

    A branch is a thunk that produces a value or an error string.
    The first branch to return [Ok _] wins. *)

type 'a branch = unit -> ('a, string) result

(** {1 Selection diagnostics}

    Always returned alongside the outcome so callers can render
    which branch won, how many were attempted, and what the
    failing-branch errors were. *)

type 'a selection = {
  winner_index : int option;
      (** [Some i] when branch at index [i] returned [Ok _].
          [None] when no branch succeeded within budget. *)
  attempted : int;
      (** Number of branches actually evaluated (≤
          [budget.branches_max]). *)
  errors : string list;
      (** Errors from non-winning branches in evaluation order. *)
}
[@@warning "-69"]

(** {1 Execute}

    Run branches under budget. STUB: sequential, first-success
    wins. Future tier replaces with Eio.Switch-based race + abort.

    Outcome semantics:
    - First branch to return [Ok value] →
      [FullSuccess { value; confidence = full; artifacts = [] }].
    - All branches fail →
      [GracefulFailure { fallback = None; reason = "all_branches_failed";
                          recovery_strategy = "Speculate";
                          confidence = zero }].
    - Empty branch list (or [branches_max = 0]) →
      [GracefulFailure { ... reason = "no_branches"; ... }]. *)

val execute :
  budget:budget_policy ->
  'a branch list ->
  ('a, string) Shared_types.Resilience_outcome.t * 'a selection
