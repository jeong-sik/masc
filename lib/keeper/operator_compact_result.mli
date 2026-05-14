(** Operator_compact_result — closed sum for the [result] label on
    [metric_keeper_operator_compact].

    The metric registration in [prometheus.ml] already documented the
    closed set verbatim:

        "Total operator-invoked masc_keeper_compact calls
         (labels: result=ok|no_checkpoint|precondition|not_found)"

    Locks the contract: a typo or new value at one emit site is now a
    compile error at [to_label] (the type's witness) instead of a
    silent cardinality drift on the Prometheus surface. *)

type t =
  | Ok (** Compaction applied successfully. *)
  | No_checkpoint (** No checkpoint to compact from. *)
  | Precondition (** Preconditions for compaction unmet (e.g. keeper paused). *)
  | Not_found (** Operator referenced a keeper name that does not exist. *)

val to_label : t -> string
