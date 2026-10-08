(** Error_event_type — closed sum for the [type] label on
    [metric_error_events] (`masc_error_events_total`).

    A typed set keeps callers from passing free-form strings: a new event
    type is one edit here, and its wire string is checked at every
    emission site. *)

type t =
  | Parsing (** JSON / config parse failure. *)

(** Stable wire format for the [type] label: ["parsing"]. *)
val to_label : t -> string
