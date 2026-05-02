
(** Tool_shard_limits — SSOT integer constants shared between
    [Tool_shard] (the MCP tool surface) and [Keeper_exec_fs]
    (the runtime handler).

    Lives in a leaf module with no dependencies so both sides can
    import the same value without forming the
    [Tool_shard ↔ Keeper_exec_fs] dependency cycle that motivated
    the extraction in the first place. *)

val keeper_fs_read_default_max_bytes : int
(** Default byte budget for [keeper_fs_read] when the caller
    omits [max_bytes]. Currently 20_000.

    Pinned at the contract seam because the value appears in
    two unrelated places: the JSON schema for [keeper_fs_read]'s
    [max_bytes] parameter (where it is rendered into the
    [description] string for the LLM) and the runtime guard in
    [Keeper_exec_fs]. Surfacing it here keeps both consumers
    locked to the same number. *)

val keeper_fs_read_default_max_bytes_string : string
(** [string_of_int keeper_fs_read_default_max_bytes]. Pre-rendered
    so the schema description string can include it without a
    per-schema-render allocation, and so the schema stays a
    structural constant rather than a function call result. *)
