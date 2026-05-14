(** Bookkeeping_failure_kind — closed sum for the [kind] label on
    [metric_keeper_turn_slot_bookkeeping_failures].

    The metric registration in [prometheus.ml] already documented the
    closed set verbatim:

        "Total keeper turn-slot release bookkeeping callbacks that
         could not complete while preserving semaphore release
         (labels: op, kind=cancelled|exception)"

    Closes the [kind] label.  The [op] label intentionally stays
    free-form because it carries dynamic context (e.g.
    [drop_holder <label>]) needed to disambiguate which bookkeeping
    callback failed. *)

type t =
  | Cancelled (** Bookkeeping fiber was cancelled mid-flight. *)
  | Exception (** Bookkeeping callback raised an OCaml exception. *)

val to_label : t -> string
