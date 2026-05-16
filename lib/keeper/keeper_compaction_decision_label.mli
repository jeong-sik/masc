(** Keeper_compaction_decision_label — closed sum of stable Prometheus
    labels for the seven outcomes of
    {!Keeper_compact_policy.compact_if_needed_typed}.

    Why a separate sum from {!Keeper_compact_policy.compaction_decision}?
    The runtime decision variant embeds float/int values
    ([hold_s], [cooldown_sec], ratio, threshold, etc.) so feeding it
    directly to a Prometheus label would explode cardinality.  This
    module flattens the decision into a stable, bounded label set that
    drives [metric_keeper_compaction_decisions] without leaking
    per-call numerics into the metric series. *)

type t =
  | Applied_ratio
      (** Compaction fired because [context_ratio >= ratio_gate]. *)
  | Applied_message
      (** Compaction fired because [message_count >= message_gate]. *)
  | Applied_token
      (** Compaction fired because [token_count >= token_gate]. *)
  | Applied_tool_heavy
      (** Compaction fired because the tool-heavy gate caught
          accumulated tool results bloating context without tripping
          ratio/message/token. *)
  | Applied_manual
      (** Compaction fired with [Compaction_trigger.Manual] —
          reserved for explicit operator/runtime trigger paths.
          Not currently emitted by [compact_if_needed_typed]
          itself but kept exhaustive so future direct callers stay
          typed. *)
  | Blocked_below_thresholds
      (** Reflection cooldown ready, but no gate was crossed.
          Healthy idle path. *)
  | Skipped_no_checkpoint
      (** Compaction skipped because no checkpoint exists yet (early
          keeper boot). *)
  | Skipped_continuity_reflection
      (** Compaction skipped because reflection cooldown has not
          elapsed since the last continuity update and ratio is
          below the emergency threshold.  Rising rate against a
          rising ratio is the signal that the cooldown gate is
          trapped (cf. PR #15663 V01). *)

val to_label : t -> string
