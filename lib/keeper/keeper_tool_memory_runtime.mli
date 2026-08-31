(** Agent memory tool runtime — search, context status, write. *)

(** Issue #8484: Variant SSOT for memory search scope.  Mirror in
    [Tool_shard.memory_search_source_enum_strings] (cycle avoidance,
    sync regression test catches drift). *)
type memory_search_source =
  | Memory
  | History
  | All

val memory_search_source_of_string_opt : string -> memory_search_source option
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

(** Explicit memory write surface.

    Without [source_path], atomically adds a durable claim to the ordinary
    current Memory OS snapshot. With [source_path], writes only the
    source-bound current store.
    Body is stored as [**title** content] when [title] is non-empty.

    Args (JSON object):
    - [title] — short hook (≤120 chars). May be empty; then [content]
      stands alone.
    - [content] — body. Required; must be non-empty.
    - [source_path] — optional keeper-visible regular file. When present, the
      claim enters the source-bound current store and is revalidated before
      every recall instead of entering the ordinary Memory OS snapshot.

    Returns a JSON string with [{ok, error_kind, ...}]:
    - On success: [ok=true], [rows_written], [outcome], [store].
    - On validation or persistence failure: [ok=false] with the
      corresponding explicit [error_kind]. *)
val keeper_memory_write_with_outcome
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t
(** Validate and atomically upsert an explicit fact in the Keeper's bounded
    Memory OS snapshot. The write stays inside MASC and never enters the
    external-effect Gate or approval replay path. *)

(** Title length cap exposed for sync regression tests. *)
(** Upper bound on the composed [**title** content] body. *)
(** Result of validating a [keeper_memory_write] call's args. Exposed
    so tests can pin the error_kind taxonomy without constructing a
    [Workspace.config]. *)
type memory_write_error_kind =
  | Title_too_long
  | Content_empty
  | Content_too_long
  | Source_path_invalid
  | Source_path_too_long
  | Source_read_failed
  | Persistence_failed
  | No_memory_write_error

val memory_write_error_kind_to_string : memory_write_error_kind -> string

type memory_write_validation =
  | Memory_write_ok of
      { body : string
      ; source_path : string option
      }
  | Memory_write_invalid of
      { error_kind : memory_write_error_kind
      ; extras : (string * Yojson.Safe.t) list
      }

val validate_memory_write_args : Yojson.Safe.t -> memory_write_validation
