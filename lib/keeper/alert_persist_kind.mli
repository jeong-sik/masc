(** Alert_persist_kind — closed sum for the [kind] label on
    [metric_keeper_alert_persist_failures].

    Replaces 3 hardcoded string literals in [keeper_alerting.ml]
    (`"alert"` / `"failed_channels"` / `"deadletter"`).  The closed
    sum forces every emit site through the compiler so adding a
    new persistence failure category requires a single edit and
    the new wire string surfaces immediately. *)

type t =
  | Alert (** Primary alert payload persist failure. *)
  | Failed_channels (** Per-channel delivery failure record persist failure. *)
  | Deadletter (** Deadletter store persist failure. *)

val to_label : t -> string
