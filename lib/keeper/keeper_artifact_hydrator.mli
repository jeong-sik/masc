(** Lazy artifact hydrator reducer.

    Reads ToolResult blocks whose [content] is a [Tool_output.Stored]
    sentinel marker and re-inflates the bytes from [Tool_blob_store]
    just before the LLM call. Older messages keep their markers, which
    cap the on-disk + on-wire token cost of historical context.

    Inserted at the front of the keeper's reducer pipeline (BEFORE
    [prune_tool_outputs]) so the standard cap still applies to hydrated
    bytes — hydration restores the most recent K, the cap then trims
    each to the per-output budget. *)

val default_keep_recent : int

(** Resolved budget. Reads [MASC_TOOL_HYDRATE_RECENT] (defaults to
    [default_keep_recent]). Negative or unparseable values fall back to
    the default. *)
val keep_recent_from_env : unit -> int

(** Build a [Custom] reducer that walks the message list right-to-left
    and hydrates the last [keep_recent] [Stored] markers it encounters.

    Hydration misses (sha256 not in the store) leave the marker in
    place; the LLM still has the metadata fields (sha256, byte count,
    preview) to reason about the missing payload.

    Storage exceptions are caught — a corrupted store cannot break the
    reducer pipeline. *)
val hydrate_recent : store:Tool_blob_store.t -> keep_recent:int -> Oas.Context_reducer.t

(** Returns a configured reducer if a blob store can be resolved from
    [MASC_BASE_PATH], else [None]. The [None] case lets callers compose
    the pipeline conditionally without a separate enable flag. *)
val reducer_from_env : unit -> Oas.Context_reducer.t option
