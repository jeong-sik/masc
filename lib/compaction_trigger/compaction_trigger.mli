(** Compaction_trigger — explicit context compaction request origin. *)

type t =
  | Provider_overflow of { limit_tokens : int option }
      (** Typed provider context-window overflow. [limit_tokens] is the
          provider-declared limit when present, never an estimated count. *)
  | Manual

(** Closed label set for Otel_metric_store / SSE [trigger] label.
    Use this anywhere cardinality matters. *)
val to_label : t -> string

(** Human-readable rendering. Use for [Log.*] string interpolation only. *)
val to_human : t -> string

(** Structured JSON detail for durable observation. *)
val to_detail_json : t -> Yojson.Safe.t

type decode_error =
  | Expected_object
  | Missing_kind
  | Invalid_kind
  | Unknown_kind of string
  | Missing_provider_limit
  | Invalid_provider_limit

val decode_error_to_string : decode_error -> string

val of_detail_json : Yojson.Safe.t -> (t, decode_error) result
(** Exact inverse of {!to_detail_json}. Retired heuristic trigger kinds and
    malformed rows are rejected explicitly. *)
