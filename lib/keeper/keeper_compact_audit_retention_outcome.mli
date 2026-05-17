(** Keeper_compact_audit_retention_outcome — closed sum classifying how the
    [MASC_COMPACTION_AUDIT_RETENTION_DAYS] env override was resolved at
    subscriber startup.

    Motivation (V10, MED): the previous parsing branch silently coerced any
    invalid value (non-integer, negative, zero, or out-of-range) to the
    caller-supplied default. Operator misconfiguration was invisible until
    forensic data loss was observed (e.g. setting "30d" instead of "30"
    would silently fall back to the default 14, dropping ~16 days of
    audit history compared to the intended window).

    Resolution returns one of four variants so the caller can:
    - emit a Prometheus counter labelled by [to_label]
    - log a [Log.Keeper.warn] on [Parse_error] / [Out_of_range] with the
      raw value and the default that was substituted
    - keep the silent-default behaviour for [Unset_default] (normal path)

    Out-of-range bounds: a parsed integer is considered in-range iff
    [1 <= n <= 3650]. Rationale: 1 day is the smallest non-trivial
    rolling window; 3650 days (~10 years) is well beyond any operational
    retention need and catches obvious unit confusion (e.g. seconds
    instead of days). Values outside this band are almost certainly
    misconfiguration and warrant operator visibility. *)

type t =
  | Parsed_ok of int
      (** Env var present, parsed as integer, within [1, 3650]. *)
  | Unset_default of int
      (** Env var absent; carries the default that was applied. *)
  | Parse_error of { raw : string; default_used : int }
      (** Env var present but not parseable as an integer (e.g. "30d"). *)
  | Out_of_range of { raw : string; parsed : int; default_used : int }
      (** Env var parsed as integer but outside [1, 3650] (e.g. 0, -5,
          1_000_000). *)

val to_label : t -> string
(** Lowercase snake_case label for the [outcome] Prometheus label.
    One of: ["parsed_ok"], ["unset_default"], ["parse_error"],
    ["out_of_range"]. *)
