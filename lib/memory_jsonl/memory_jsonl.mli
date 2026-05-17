(** Memory_jsonl — Session-based JSONL backend for OAS Memory.long_term_backend.

    Each session gets its own .jsonl file under
    [<base_dir>/memory/<agent_name>/<session_id>.jsonl]. Lines are
    append-only; the latest entry per key wins on read. Tombstones
    (value=null) mark removals. *)

val encode_line :
  key:string ->
  value:Yojson.Safe.t option ->
  string
(** [encode_line ~key ~value] returns the serialised JSONL line
    (terminated with a newline) for the given (key, value) pair at
    the current timestamp.

    When the serialised [value] exceeds 1 MB it is replaced with a
    typed truncation marker of shape
    {[
      `Assoc [
        ("_truncated", `Bool true);
        ("_original_type", `String "<Assoc|List|String|Int|Float|Bool|Null|Intlit>");
        ("_original_size_bytes", `Int <bytes>);
        ("_preview", `String "<first ~1KB of serialised payload>");
      ]
    ]}
    Downstream decoders can recognise the marker via
    {!value_is_truncated_marker} and branch explicitly. *)

val parse_line :
  string ->
  (string * Yojson.Safe.t option * float) option
(** [parse_line line] returns [Some (key, value, ts)] when [line] is
    a well-formed JSONL record, [None] otherwise. Malformed lines are
    logged at warn level with a bounded snippet. *)

val value_is_truncated_marker : Yojson.Safe.t -> bool
(** [value_is_truncated_marker v] is [true] iff [v] is the typed
    truncation marker produced by {!encode_line} when the serialised
    value exceeded 1 MB. Discriminated structurally by the
    [`Assoc] constructor and a [_truncated] field equal to
    [`Bool true] — no substring matching on payload. *)

val truncation_marker_preview : Yojson.Safe.t -> string option
(** [truncation_marker_preview v] returns [Some preview] (first
    ~1 KB of the original serialised payload) when [v] is a
    truncation marker, [None] otherwise. *)

val truncation_marker_original_type : Yojson.Safe.t -> string option
(** [truncation_marker_original_type v] returns the original
    payload's top-level Yojson constructor name (e.g. ["Assoc"],
    ["List"]) when [v] is a truncation marker, [None] otherwise. *)

val truncation_marker_original_size_bytes : Yojson.Safe.t -> int option
(** [truncation_marker_original_size_bytes v] returns the original
    payload's serialised byte length when [v] is a truncation
    marker, [None] otherwise. *)

val make_backend :
  base_dir:string ->
  agent_name:string ->
  session_id:string ->
  Agent_sdk.Memory.long_term_backend
(** [make_backend ~base_dir ~agent_name ~session_id] builds a
    {!Agent_sdk.Memory.long_term_backend} that persists/retrieves/removes/queries
    against the per-session JSONL file. Persist and remove append; retrieve
    and query fold the file with last-write-wins semantics. Errors from the
    underlying I/O are logged and surfaced through the backend's [Result]
    return types ([persist]/[remove]/[batch_persist]) or as empty
    [retrieve]/[query] results.

    Files exceeding 50 MB log a warning. Individual values exceeding 1 MB
    are replaced with a typed truncation marker (see {!encode_line} and
    {!value_is_truncated_marker}). *)

val make_backend_with_query_observer :
  on_query_result:(((string * Yojson.Safe.t) list, string) result -> unit) ->
  base_dir:string ->
  agent_name:string ->
  session_id:string ->
  Agent_sdk.Memory.long_term_backend
(** Same as {!make_backend}, but [on_query_result] receives the pre-collapse
    [query] outcome so callers can distinguish real empty query results from
    I/O failures without changing the OAS backend contract.

    Files exceeding 50 MB log a warning but are still read. Individual
    values exceeding 1 MB are replaced with a typed truncation marker
    (see {!encode_line} and {!value_is_truncated_marker}). *)
