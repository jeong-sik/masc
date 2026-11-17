(** Canonical identity for exact approval requests. *)

val request_fingerprint : Yojson.Safe.t -> string
(** SHA-256 of JSON with recursively sorted object fields. Array order and
    scalar values remain unchanged. *)

type exact_request
(** A complete captured Gate identity. This is data, not an approval or an
    executable request. The original physical origin witness is retained;
    queue matching still compares logical origin, as existing submission does. *)

val exact_request :
  base_path:string -> keeper_name:string -> operation:string ->
  input:Yojson.Safe.t -> origin:Keeper_approval_origin.t ->
  task_id:string option -> goal_id:string option ->
  continuation_channel:Keeper_continuation_channel.t ->
  (exact_request, string) result
(** Pure capture. The workspace path must be absolute and is normalized through
    the shared workspace identity rules; no current-directory fallback is used.
    Sort complete input object fields without coercing numeric representations,
    reject duplicate keys/nonfinite numbers, and compute its existing request
    fingerprint. The current wire schema retains the input as opaque JSON text
    so outer store canonicalization cannot change its numbers. Origin and
    continuation channel must round-trip through their strict canonical codecs, even when
    supplied through typed constructors. [None] task/goal means none
    was observed, never a lookup of current state. *)

val base_path : exact_request -> string
val keeper_name : exact_request -> string
val operation : exact_request -> string
val input : exact_request -> Yojson.Safe.t
val input_hash : exact_request -> string
val origin : exact_request -> Keeper_approval_origin.t
val task_id : exact_request -> string option
val goal_id : exact_request -> string option
val continuation_channel : exact_request -> Keeper_continuation_channel.t

val exact_request_to_json : exact_request -> Yojson.Safe.t
val exact_request_of_json : Yojson.Safe.t -> (exact_request, string) result
(** Strict current-schema codec: exact fields, canonical nested codecs, complete
    scalar-preserving input JSON text and a recomputed hash. No queue, filesystem
    or runtime is consulted. *)
val equal_exact_request : exact_request -> exact_request -> bool
(** Equal complete captured values, including the physical origin witness.
    This is stricter than the queue's logical-origin matching rule. *)

val matches_entry :
  exact_request -> base_path:string -> keeper_name:string -> operation:string ->
  input:Yojson.Safe.t -> input_hash:string -> origin:Keeper_approval_origin.t ->
  task_id:string option -> goal_id:string option ->
  continuation_channel:Keeper_continuation_channel.t -> bool
(** Existing queue identity fields plus complete scalar-preserving input equality.
    Uses [same_logical_source] for origin and exact typed-channel JSON equality.
    Malformed input refuses. The caller supplies fields, so this pure matcher
    has no dependency on Queue entry/state types. It grants no authority. *)
