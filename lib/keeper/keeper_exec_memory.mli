(** Keeper memory tool handlers — search, context status, write. *)

(** Issue #8484: Variant SSOT for memory search scope.  Mirror in
    [Tool_shard.memory_search_source_enum_strings] (cycle avoidance,
    sync regression test catches drift). *)
type memory_search_source = Memory | History | All

val memory_search_source_to_string : memory_search_source -> string
val memory_search_source_of_string_opt : string -> memory_search_source option
val all_memory_search_sources : memory_search_source list
val valid_memory_search_source_strings : string list

val keeper_memory_search_json :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  ctx_work:Keeper_types.working_context ->
  args:Yojson.Safe.t ->
  string

val keeper_context_status_json :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  ctx_work:Keeper_types.working_context ->
  string

(** RFC-0035 P4 surface: explicit memory write.

    Promotes a structured note into the keeper memory bank, queryable
    by [keeper_memory_search]. Body is stored as
    [**title** content] when [title] is non-empty, mirroring the
    auto-write path's text shape (priorities, dedup, cap drops are
    handled by [Keeper_memory_bank.append_memory_notes_from_reply]).

    Args (JSON object):
    - [kind] — one of
      [Keeper_memory_policy.valid_memory_kind_strings] EXCEPT
      [long_term] (long_term is reserved for tool-result emission).
    - [title] — short hook (≤120 chars). May be empty; then [content]
      stands alone.
    - [content] — body. Required; must be non-empty.

    Returns a JSON string with [{ok, error_kind, ...}]:
    - On success: [ok=true], [rows_written], [kinds_written], [kind].
    - On validation failure: [ok=false] with [error_kind] in
      [{invalid_memory_kind, title_too_long, content_empty,
        long_term_via_explicit_write_not_yet_supported}].
    - On cap drop: [ok=false], [error_kind=rows_dropped_by_cap]. *)
val keeper_memory_write_json :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string

(** Title length cap exposed for sync regression tests. *)
val keeper_memory_write_max_title_chars : int

(** Result of validating a [keeper_memory_write] call's args. Exposed
    so tests can pin the error_kind taxonomy without constructing a
    [Coord.config]. *)
type memory_write_validation =
  | Memory_write_ok of {
      kind : string;
      body : string;
      snapshot : Keeper_memory_policy.keeper_state_snapshot;
    }
  | Memory_write_invalid of {
      error_kind : string;
      extras : (string * Yojson.Safe.t) list;
    }

val validate_memory_write_args : Yojson.Safe.t -> memory_write_validation

(** Build the single-field snapshot for a given memory kind.
    Exposed for sync regression tests pinning the field-to-kind
    mapping (mirrors
    [Keeper_memory_bank.memory_candidates_from_snapshot]). *)
val single_field_snapshot_for_kind :
  kind:string ->
  text:string ->
  Keeper_memory_policy.keeper_state_snapshot option
