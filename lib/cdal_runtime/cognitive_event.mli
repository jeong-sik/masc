(** Cognitive event types for SDK consumers (RFC-0036 PR-B,
    Master Report transport schema).

    A typed, JSON-codecable enumeration of the cognitive events that
    a downstream coordinator host (boundary-allow: e.g. masc-mcp)
    emits when its cognitive layer fires (gravity ranking, intent
    prediction, mode transition, disclosure level change). The SDK
    does not produce these events itself in this PR; the type lives
    here so both the host emitter and any future SDK-side consumer
    (Hooks, Tracing) share a single schema.

    Design choices:

    - Variants carry only structural data, not closures or
      file-handle references — the type must remain JSON-stable
      across pin bumps.
    - {!Intent_predicted} carries [intent_label : string] rather
      than referring to {!Context_intent.intent}. This keeps
      {!Cognitive_event} independent of {!Context_intent}'s
      enum lifecycle: hosts that classify with a richer
      taxonomy (e.g. RFC-0036 Extension A's [Cognitive_op]
      variant) can still serialise events without depending on
      a particular SDK pin.
    - No timestamps in the variants. Callers add timing via the
      surrounding {!Tracing} or {!Hooks} envelope.

    @stability Evolving
    @since 0.190.27 *)

(** A cognitive event emitted by the host. *)
type t =
  | Gravity_ranked of
      { ranked_count : int
      ; query_terms : int
      }
  | Intent_predicted of
      { intent_label : string
      ; confidence : float
      }
  | Mode_transitioned of
      { from_mode : string
      ; to_mode : string
      }
  | Disclosure_level of { level : int }
[@@deriving yojson, show]

(** [name t] returns the variant tag as a stable lowercase string,
    suitable for log labels and Prometheus counters. *)
val name : t -> string

(** [is_well_formed t] checks the lightweight invariants this module
    enforces:

    - [Gravity_ranked]: [ranked_count] and [query_terms] non-negative.
    - [Intent_predicted]: [intent_label] non-empty,
      [confidence] in the closed interval [0.0, 1.0].
    - [Mode_transitioned]: [from_mode] and [to_mode] non-empty and
      not equal.
    - [Disclosure_level]: [level] in the closed interval [0, 3]
      (Master Report defines L0 / L1 / L2 / L3 disclosure tiers).

    The function returns [Ok ()] on a well-formed event and [Error
    msg] otherwise. Decoders that want to reject malformed inputs
    should call this after {!of_yojson}. *)
val is_well_formed : t -> (unit, string) result
