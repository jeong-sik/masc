(** Compaction_trigger — closed sum type for context compaction reason.

    Replaces the prior [string] / [string option] representation in
    [compaction_event.trigger] and [pre_compact_event.trigger] so the
    Prometheus [trigger] label has bounded cardinality (5 values) while
    structured numerical detail (ratio, counts, thresholds) is preserved
    in the JSON receipt via [to_detail_json]. *)

type t =
  | Ratio_threshold of
      { ratio : float
      ; threshold : float
      }
  | Message_count of
      { count : int
      ; threshold : int
      }
  | Token_count of
      { count : int
      ; threshold : int
      }
  | Tool_heavy of
      { messages : int
      ; ratio : float
      }
  | Manual

(** Closed label set (5 values) for Prometheus / SSE [trigger] label.
    Use this anywhere cardinality matters. *)
val to_label : t -> string

(** Human-readable rendering with embedded numerical detail.  Use for
    [Log.*] string interpolation only — NOT for Prometheus labels. *)
val to_human : t -> string

(** Structured JSON detail with all numerical fields preserved.  Use
    inside SSE broadcasts and JSON receipts so dashboards can plot
    actual ratios/counts rather than parse strings. *)
val to_detail_json : t -> Yojson.Safe.t

(** Inverse of {!to_detail_json}.  Returns [None] if the JSON cannot be
    parsed as a known trigger kind.  Used by persistence-recovery code
    paths (e.g. dashboard log replay) where the typed variant must be
    reconstructed from a stored JSON record. *)
val of_detail_json : Yojson.Safe.t -> t option
