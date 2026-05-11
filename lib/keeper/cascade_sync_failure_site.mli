(** Cascade_sync_failure_site — closed sum for [site] label on
    [metric_keeper_cascade_sync_failures] (now 3 sites across
    keeper_turn_cascade_budget.ml + keeper_unified_turn.ml). *)

type t =
  | Resume_sync
  | Pause_sync
  | Ambiguous_partial_pause
  (** Post-mutating-tool ambiguous-pause path in keeper_unified_turn.ml.
          Operator-disposition equivalent of post-commit ambiguity. *)

val to_label : t -> string
