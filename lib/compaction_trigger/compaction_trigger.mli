(** Compaction_trigger — explicit context compaction request origin. *)

type serving_input_capacity =
  | Boundary_unknown of
      { input_tokens : int
      ; accepted_through : int
      ; rejected_from : int option
      }
  | Input_rejected of
      { input_tokens : int
      ; accepted_through : int
      ; rejected_from : int
      }
(** Provider-neutral token-capacity evidence produced by AGENT_CORE admission. The
    measured request and accepted/rejected boundary remain distinct from both
    a model context-window declaration and serialized request-body bytes. *)

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
          [Agent_core.Retry.Request_body_too_large] carries them from the
          serialization AGENT_CORE performs before any HTTP call, so
          [actual_bytes > limit_bytes] already held upstream and
          {!of_detail_json} rejects a record where it does not.

          Separate from {!Provider_overflow} because the unit differs. A byte
          refusal says nothing about the provider's token window, so folding it
          into [limit_tokens] would have to report [None] — an unknown limit for
          a limit that is known exactly. *)
  | Request_body_refused_by_provider of { status : int }
      (** The provider explicitly refused the serialized request for its size.
          [status] is preserved from the HTTP response. Unlike
          {!Request_body_over_capacity}, neither the request bytes nor a byte
          limit are known, so this constructor must not fabricate either one. *)
  | Serving_input_capacity of serving_input_capacity
      (** AGENT_CORE exhausted admission candidates and returned a measured token
          boundary. Only [Boundary_unknown] and [Input_rejected] can construct
          this trigger; unavailable or stale measurements are not compaction
          requests. *)
  | Manual

(** Closed label set for Otel_metric_store / SSE [trigger] label.
    Use this anywhere cardinality matters. *)
val to_label : t -> string

(** Human-readable rendering. Use for [Log.*] string interpolation only. *)
val to_human : t -> string

(** Structured JSON detail for durable observation. *)
val to_detail_json : t -> Yojson.Safe.t

(** Every key {!to_detail_json} can emit, across all constructors. A consumer
    that filters or validates the encoded object reads this rather than
    restating the keys, so a field added to a constructor cannot be dropped by
    a stale allowlist. Not the per-kind key set — {!of_detail_json} still
    rejects a key that does not belong to the decoded [kind]. *)
val wire_field_names : string list

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
  | Missing_provider_refusal_status
  | Invalid_provider_refusal_status
  | Request_body_within_capacity of
      { actual_bytes : int
      ; limit_bytes : int
      }
  | Missing_serving_capacity_field of string
  | Invalid_serving_capacity_field of string
  | Serving_capacity_not_over_limit of
      { input_tokens : int
      ; accepted_through : int
      }
  | Invalid_boundary_unknown of
      { input_tokens : int
      ; rejected_from : int
      }
  | Invalid_input_rejected_boundary of
      { input_tokens : int
      ; accepted_through : int
      ; rejected_from : int option
      }

val decode_error_to_string : decode_error -> string

val of_detail_json : Yojson.Safe.t -> (t, decode_error) result
(** Exact inverse of {!to_detail_json}. Retired heuristic trigger kinds and
    malformed rows are rejected explicitly. *)
