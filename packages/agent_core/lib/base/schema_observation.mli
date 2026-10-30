(** Diagnostic-only observation of actual schema work. This module changes no
    cache, admission, scheduling or encoding policy. It stores scalar events and
    weak physical schema identities; never schemas, JSON, handlers or contexts in
    its event buffer. Install explicitly around an owned finite diagnostic run. *)

type t
type object_id = private int64
type scope
type report

type mode = Disabled | Identity_only | Timed
type completion = Returned | Returned_error | Raised | Cancelled
type site =
  | Bridge_plain_constructor
  | Bridge_execution_env_constructor
  | Sdk_prepare_json
  | Sdk_wire_json
  | Sdk_byte_count_lookup
  | Sdk_byte_count_encode
  | Sdk_byte_count_publication
  | Reserve_encode
  | Prefix_digest_encode
  | Prompt_metrics_encode
  | Provider_snapshot_encode
  | Phase0_bytes
  | Final_attribution_bytes
  | Built_surface
  | Agent_core_surface
  | Request_surface
  | Worker_queue_and_await
  | Worker_work

type json_lookup = Existing_json | Created_json
type byte_lookup = Existing_byte_count | Missing_byte_count
type publication = Published_byte_count | Concurrent_byte_count_won
type cache_outcome =
  | Json_lookup of json_lookup
  | Byte_lookup of { json : json_lookup; count : byte_lookup }
  | Byte_publication of publication

val create : mode:mode -> t
val within : t -> (unit -> 'a) -> 'a
(** [Disabled] calls the operation without binding, IDs, clocks or rows. Raw
    non-Eio callers without a binding retain their existing behavior. *)

val enabled : unit -> bool
val observer_work : (unit -> 'a option) -> 'a option
(** Run ONLY diagnostic bookkeeping when bound, isolating ordinary observer
    errors and counting incomplete coverage. Never wrap product work here.
    Reserved exceptions propagate. Nested bookkeeping estimates overlap. *)
val fresh_object_id : unit -> object_id option
(** Process-unique monotonic identity for a bound observer. [None] means no
    active observer, or exhausted identity space (also counted incomplete).
    Keeper's weak descriptor adapter uses this instead of casting its own IDs. *)

val object_id_to_string : object_id -> string
val schema : Types.tool_schema -> object_id option
(** Physical identity in a weak registry, never name/JSON equality. *)

val with_wake :
  keeper:string -> trace_id:string -> absolute_turn:int ->
  execution_scope:string option -> cause:string option -> (unit -> 'a) -> 'a
val with_attempt :
  routing_run_id:string -> lane_attempt_index:int -> runtime_id:string ->
  (unit -> 'a) -> 'a
val with_provider_turn : ordinal:int -> (unit -> 'a) -> 'a
(** A fresh observer candidate ID and the resolved SDK ordinal. This is not
    evidence that a request dispatched. *)
val with_definition :
  descriptor_id:object_id -> addon_owner_id:object_id option ->
  (unit -> 'a) -> 'a
val with_site : site -> (unit -> 'a) -> 'a
val current_scope : unit -> scope option
val with_scope : scope -> (unit -> 'a) -> 'a
val scope_to_json : scope -> Yojson.Safe.t
val capture : (unit -> 'a) -> (unit -> 'a)
(** Capture the observer and immutable scalar scope before actor/pool handoff.
    The caller owns the returned closure and therefore its operation's lifetime;
    neither operation nor product objects enter observer state. *)

val measure : site:site -> ?schema:Types.tool_schema -> (unit -> 'a) -> 'a
(** Record the actual operation once, preserving its result/backtrace. Timed
    allocation is a calling-domain interval, never process allocation. It is
    unavailable if the domain changes. Mutex/yielding callers must treat even
    same-domain intervals as potentially interleaved. *)
val constructor :
  site:site -> (unit -> (Types.tool_schema, 'error) result) ->
  (Types.tool_schema, 'error) result
val encode :
  site:site -> schema:Types.tool_schema -> (unit -> string) -> string
(** Time the existing encoder and return its original string. Only byte length
    enters the row; no shadow encoding or retained string is introduced. *)
val surface : site:site -> (unit -> Types.tool_schema list) -> unit
(** Ordered physical IDs including occurrences. The thunk is not called when
    disabled/unbound. The list and its keys are discarded before publication. *)
val cache : schema:Types.tool_schema -> cache_outcome -> unit
(** Call AFTER releasing the product cache mutex. Never invoke this module,
    its weak table or its event mutex inside that critical section. *)

val snapshot : t -> report
(** Immutable scalar snapshot. Join owned work before the final snapshot;
    publication to disk belongs to the diagnostic owner outside measured spans. *)
val report_to_json : report -> Yojson.Safe.t
val write_report_json : write:(string -> unit) -> report -> unit
(** Emit the same v1 JSON value as {!report_to_json}, compactly and with a
    final LF, preserving every event and its order. Only header fields and one
    event are encoded at a time; no complete JSON tree or report string is
    built. The largest individual event still determines transient chunk size.

    The caller owns output, flushing, closing and atomic publication. [write]
    is called synchronously and is not retained. Its exceptions, including
    cancellation, propagate unchanged; a failure can leave partial output for
    the caller's publication boundary to discard. Run outside measured work,
    after joining the observer's owned operations. *)
val report_of_json : Yojson.Safe.t -> (report, string) result
(** Strict versioned inverse: exact fields, closed tags, finite valid clocks,
    unique ordered event IDs and matching observer/scope identities. *)
