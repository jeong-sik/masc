
(** Tool_shard_limits — SSOT integer constants shared between
    [Tool_shard] (the MCP tool surface) and [Keeper_tool_filesystem_runtime]
    (the runtime handler).

    Lives in a leaf module with no dependencies so both sides can
    import the same value without forming the
    [Tool_shard ↔ Keeper_tool_filesystem_runtime] dependency cycle that motivated
    the extraction in the first place. *)

val read_file_default_max_bytes : int
(** Default byte budget for [Read] when the caller omits [max_bytes]. Currently
    20_000.

    Pinned at the contract seam because the value appears in
    two unrelated places: the JSON schema for [Read]'s [max_bytes] parameter
    (where it is rendered into the [description] string for the LLM) and the runtime guard in
    [Keeper_tool_filesystem_runtime]. Surfacing it here keeps both consumers
    locked to the same number. *)

val read_file_default_max_bytes_string : string
(** [string_of_int read_file_default_max_bytes]. Pre-rendered
    so the schema description string can include it without a
    per-schema-render allocation, and so the schema stays a
    structural constant rather than a function call result. *)

val read_file_max_max_bytes : int
(** Ceiling for an explicit [max_bytes] on [Read]. A caller asking for more is
    clamped to this. *)

val verification_evidence_max_bytes : int
(** Byte cap for one evidence artifact in a verification snapshot. Equal to
    {!read_file_max_max_bytes} by construction, not by coincidence: the
    completion authority reads files live through [Read] and an operator later
    reviews the snapshot, so a verdict must not be able to rest on bytes the
    snapshot did not keep (#27397). *)
