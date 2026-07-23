(** Lazy artifact hydrator projection.

    Reads ToolResult blocks whose [content] is a [Tool_output.Stored]
    blob marker and re-inflates the bytes from [Tool_blob_store]
    just before the LLM call. Older messages keep their markers, which
    cap the on-disk + on-wire token cost of historical context.

    Applied only to the provider-bound message projection. Persisted keeper
    history and OAS checkpoints retain their content-addressed markers. *)

val default_keep_recent : int

val keep_recent_from_env : unit -> int
(** Resolved budget. Reads [MASC_TOOL_HYDRATE_RECENT] (defaults to
    [default_keep_recent]). Negative or unparseable values fall back to
    the default. *)

val hydrate_recent :
  store:Tool_blob_store.t ->
  keep_recent:int ->
  Agent_sdk.Types.message list ->
  Agent_sdk.Types.message list
(** Walk the message list right-to-left
    and hydrates the last [keep_recent] [Stored] markers it encounters.

    Hydration misses (sha256 not in the store) leave the marker in
    place; the LLM still has the metadata fields (sha256, byte count,
    preview) to reason about the missing payload.

    Storage read errors are logged and leave the marker in place, so a
    corrupted artifact cannot break the provider-bound projection without
    becoming a silent failure. Cancellation propagates. *)
