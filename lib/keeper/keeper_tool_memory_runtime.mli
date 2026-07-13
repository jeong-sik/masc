(** Agent memory tool runtime — search, context status, write. *)

(** Issue #8484: Variant SSOT for memory search scope.  Mirror in
    [Tool_shard.memory_search_source_enum_strings] (cycle avoidance,
    sync regression test catches drift). *)
type memory_search_source =
  | Memory
  | History
  | All

val memory_search_source_to_string : memory_search_source -> string
val memory_search_source_of_string_opt : string -> memory_search_source option
val all_memory_search_sources : memory_search_source list
val valid_memory_search_source_strings : string list

val keeper_memory_search_json
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> ctx_work:Keeper_types.working_context
  -> args:Yojson.Safe.t
  -> string

val keeper_memory_search_with_outcome
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> ctx_work:Keeper_types.working_context
  -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t

val keeper_context_status_json
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> ctx_work:Keeper_types.working_context
  -> string

(** RFC-0035 P4 surface: explicit memory write.

    Promotes a structured note into the keeper memory bank, queryable
    by [keeper_memory_search]. Body is stored as
    [**title** content] when [title] is non-empty. The write is persisted
    directly with typed [Explicit_memory_write] provenance.

    Args (JSON object):
    - [kind] — one of
      [Keeper_memory_policy.writable_memory_kind_strings]. [long_term] is
      reserved for tool-result emission.
    - [title] — short hook (≤120 chars). May be empty; then [content]
      stands alone.
    - [content] — body. Required; must be non-empty.

    Returns a JSON string with [{ok, error_kind, ...}]:
    - On success: [ok=true], [rows_written], [kinds_written], [kind].
    - On validation failure: [ok=false] with [error_kind] in
      [{invalid_memory_kind, title_too_long, content_empty,
        long_term_via_explicit_write_not_yet_supported}].
    - On text-policy rejection or persistence failure: [ok=false] with the
      corresponding explicit [error_kind]. *)
val keeper_memory_write_json
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> args:Yojson.Safe.t
  -> string

val keeper_memory_write_with_outcome
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t

(** Title length cap exposed for sync regression tests. *)
val keeper_memory_write_max_title_chars : int

(** Result of validating a [keeper_memory_write] call's args. Exposed
    so tests can pin the error_kind taxonomy without constructing a
    [Workspace.config]. *)
type memory_write_error_kind =
  | Invalid_memory_kind
  | Title_too_long
  | Content_empty
  | Content_rejected
  | Long_term_via_explicit_write_not_yet_supported
  | Persistence_failed
  | No_memory_write_error

val memory_write_error_kind_to_string : memory_write_error_kind -> string

type memory_write_validation =
  | Memory_write_ok of
      { kind : Keeper_memory_policy.memory_kind
      ; body : string
      }
  | Memory_write_invalid of
      { error_kind : memory_write_error_kind
      ; extras : (string * Yojson.Safe.t) list
      }

val validate_memory_write_args : Yojson.Safe.t -> memory_write_validation
