(** Resilience_runtime — composed error → strategy pipeline.

    Cycle 27 / Tier W2.

    {1 What this module is}

    A single-entry-point bridge that composes the existing
    Recovery + Degradation building blocks into a runtime
    decision: given a free-form error message and the current
    degradation level, produce the strategy class
    ([\`Retry | \`Fallback | \`Handoff | \`Abort]) that callers
    should execute, plus the recommended next degradation level
    suggested by the classifier.

    {1 Why this module}

    Tier B6/B7/A11 land the building blocks (classification,
    confidence, degradation) but do not compose them. Without a
    composed entry point, every caller (keeper post-turn, audit
    log writer, dashboard) must duplicate the
    [classify_string → apply_level_to_strategy → extract tag]
    pipeline. This module is the SSOT for that composition.

    {1 Scope of this PR}

    - Pure pipeline: error_string + level → strategy_class.
    - JSON output for audit log envelopes.
    - No Eio fibers, no actual strategy execution — that lands
      in the lib/keeper integration follow-up.

    {1 Deferred}

    - [execute] entry point that runs the strategy (Retry loop,
      Fallback substitution, Handoff escalation). The pure
      classification surface is sufficient for the dashboard
      and audit log paths; execution semantics couple to the
      keeper's turn lifecycle and land separately. *)

(** Discriminator for the four executable strategies. *)
type strategy_class = [ `Retry | `Fallback | `Handoff | `Abort ]

type input = {
  error_message : string;
  current_level : Degradation.any_level;
}

type output = {
  classified : Recovery.error_mode;
  strategy_class : strategy_class;
  strategy_summary : string;
      (** Human-readable one-line summary of the chosen strategy
          for the audit log. *)
  recommended_level : Degradation.any_level option;
      (** Next degradation level suggested by the classifier
          (only [Some] for [DegradationRequired]). Operators
          may use this to authorise a level escalation. *)
}

val classify_only : string -> Recovery.error_mode
(** Pure classifier — re-export of [Recovery.classify_string]
    so callers depending only on this module do not need to
    reach across to [Recovery]. *)

val process : input -> output
(** Full pipeline:
    - classify [error_message] into a [Recovery.error_mode]
    - apply [current_level] via [Degradation.apply_level_to_strategy]
    - extract the strategy class
    - record the recommended next level (if any). *)

val strategy_class_to_string : strategy_class -> string
(** Lowercase string label — ["retry"], ["fallback"],
    ["handoff"], ["abort"]. *)

val output_to_json : output -> Yojson.Safe.t
(** Audit-log JSON envelope:
    {[
      { "classified_mode": "Transient",
        "strategy_class": "retry",
        "strategy_summary": "Retry (max 3 attempts)",
        "recommended_level": "L2" | null }
    ]} *)
