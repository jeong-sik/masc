(** Error_event_type — closed sum for the [type] label on
    [metric_error_events] (`masc_error_events_total`).

    Replaces 6 hardcoded string literals scattered across 3 files
    (`tool_metrics_persist.ml`, `run_eio.ml`, `server_runtime_bootstrap.ml`).
    The comment on the metric definition in `prometheus.ml` even
    spelled out the open-ended risk:

        "Error events by type (parsing, missing_config, etc.)"

    "etc." is the workaround #2 admission — future callers can sprinkle
    any string they like.  Close the set here so a new event type
    requires a single edit and the new wire string surfaces at compile
    time at every emission site. *)

type t =
  | Parsing (** JSON / config parse failure. *)
  | Missing_config (** Required runtime configuration absent at boot. *)

(** Stable wire format for the [type] label.  Returns the exact
    strings the legacy code emitted: ["parsing"] / ["missing_config"]. *)
val to_label : t -> string
