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

    Atomically adds a durable claim to the current Memory OS snapshot, the only
    store an explicit write reaches.
    Body is stored as [**title** content] when [title] is non-empty.

    Args (JSON object):
    - [title] — short hook (≤120 chars). May be empty; then [content]
      stands alone.
    - [content] — body. Required; must be non-empty.
    - [valid_for_days] — optional producer-declared lifetime.

    Returns a JSON string with [{ok, error_kind, ...}]:
    - On success: [ok=true], [rows_written], [outcome], [store].
    - On validation or persistence failure: [ok=false] with the
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

(** Upper bound on the composed [**title** content] body. *)
val keeper_memory_write_max_body_chars : int

(** Result of validating a [keeper_memory_write] call's args. Exposed
    so tests can pin the error_kind taxonomy without constructing a
    [Workspace.config]. *)
type memory_write_error_kind =
  | Title_too_long
  | Content_empty
  | Content_too_long
  | Invalid_valid_for_days
  | Persistence_failed
  | No_memory_write_error

val memory_write_error_kind_to_string : memory_write_error_kind -> string

type memory_write_validation =
  | Memory_write_ok of
      { body : string
      ; valid_for_days : int option
      }
  | Memory_write_invalid of
      { error_kind : memory_write_error_kind
      ; extras : (string * Yojson.Safe.t) list
      }

val validate_memory_write_args : Yojson.Safe.t -> memory_write_validation
