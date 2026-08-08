(** Typed envelope for opaque provider state whose retention semantics must
    survive provider-neutral context reduction.

    The envelope says how an opaque {!Types.RedactedThinking} payload relates
    to neighboring content blocks without teaching reducers about individual
    provider wire formats.

    @since 0.211.3 *)

type retention = Exact_next_block

type t =
  { retention : retention
  ; payload : Yojson.Safe.t
  }

type malformed_reason =
  | Invalid_json
  | Expected_object
  | Duplicate_field of string
  | Unexpected_field of string
  | Unsupported_schema
  | Unsupported_version
  | Unsupported_retention
  | Missing_payload

type decoded =
  | Not_replay
  | Malformed_replay of malformed_reason
  | Replay of t

(** Validate one exact JSON object schema before any field lookup. Duplicate
    and unexpected keys retain their typed malformed reason so provider-owned
    payload decoders can share the envelope's cardinality contract.
    @since 0.211.6 *)
val exact_object_fields
  :  allowed:string list
  -> Yojson.Safe.t
  -> ((string * Yojson.Safe.t) list, malformed_reason) result

(** Wrap provider-owned JSON that must stay adjacent to the following content
    block.
    @since 0.211.3 *)
val encode_exact_next_block : payload:Yojson.Safe.t -> string

(** Decode only the OAS replay envelope. Arbitrary provider-owned redacted
    payloads return [Not_replay]; a recognized but invalid envelope returns a
    typed [Malformed_replay] result.
    @since 0.211.3 *)
val decode : string -> decoded
