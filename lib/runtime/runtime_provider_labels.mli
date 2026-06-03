(** Runtime-boundary projection for provider labels.

    Metrics and dashboards may receive provider labels from historical JSONL
    rows. OAS owns the concrete provider-kind vocabulary; MASC consumers should
    ask this boundary helper for canonical labels instead of parsing
    provider-kind strings directly. *)

val canonical_provider_label : string -> string option
