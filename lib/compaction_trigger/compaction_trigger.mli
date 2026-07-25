(** Compaction_trigger — explicit context compaction request origin. *)

type capacity_dimension =
  | Input_tokens
  | Serialized_bytes
      (** The two dimensions are independent and differ in measurability.
          [Serialized_bytes] is locally deterministic — serialize and count.
          [Input_tokens] needs a provider count-tokens round trip, which only some
          protocols offer. Neither is derived from the other. *)

type t =
  | Provider_overflow of { limit_tokens : int option }
      (** Typed provider context-window overflow. [limit_tokens] is the
          provider-declared limit when present, never an estimated count. *)
  | Measured_capacity_exceeded of
      { dimension : capacity_dimension
      ; measured : int
      ; limit : int
      }
      (** A declared capacity was exceeded by a measurement, not by a provider
          verdict. Both numbers come from whoever measured: [measured] is what the
          request actually is on [dimension], [limit] is what the target declared.
          [measured > limit] holds by construction — a value at the limit has not
          been exceeded, and the decoder refuses a row that says otherwise. *)
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
  | Unknown_field of string
  | Duplicate_field of string
  | Missing_kind
  | Invalid_kind
  | Unknown_kind of string
  | Missing_provider_limit
  | Invalid_provider_limit
  | Missing_measured_field of string
  | Invalid_measured_field of string
  | Unknown_dimension of string
  | Measured_not_exceeding_limit

val decode_error_to_string : decode_error -> string

val of_detail_json : Yojson.Safe.t -> (t, decode_error) result
(** Exact inverse of {!to_detail_json}. Retired heuristic trigger kinds and
    malformed rows are rejected explicitly. *)
