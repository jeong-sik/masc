(** Compaction_trigger — explicit context compaction request origin. *)

type t =
  | Provider_overflow of { limit_tokens : int option }
      (** Typed provider context-window overflow. [limit_tokens] is the
          provider-declared limit when present, never an estimated count. *)
  | Request_body_over_capacity of
      { actual_bytes : int
      ; limit_bytes : int
      }
      (** The serialized request body exceeded the byte capacity the target
          declares. Both integers are measured, never estimated:
          [Agent_sdk.Retry.Request_body_too_large] carries them from the
          serialization OAS performs before any HTTP call, so
          [actual_bytes > limit_bytes] already held upstream and
          {!of_detail_json} rejects a record where it does not.

          Separate from {!Provider_overflow} because the unit differs. A byte
          refusal says nothing about the provider's token window, so folding it
          into [limit_tokens] would have to report [None] — an unknown limit for
          a limit that is known exactly. *)
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
  | Missing_request_body_bytes of string
  | Invalid_request_body_bytes of string
  | Request_body_within_capacity of
      { actual_bytes : int
      ; limit_bytes : int
      }

val decode_error_to_string : decode_error -> string

val of_detail_json : Yojson.Safe.t -> (t, decode_error) result
(** Exact inverse of {!to_detail_json}. Retired heuristic trigger kinds and
    malformed rows are rejected explicitly. *)
