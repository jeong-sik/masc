open Base

(** Tool_team_memory — per-room key/value memory with safe-path
    + secret-token enforcement.

    Three external entries plus the internal pipeline.  Memory is
    stored as plain files under
    \[<masc_dir>/shared/rooms/<room>/memory/<key>\] with strict
    path-traversal + secret-token guards.

    Tools advertised to the catalog:
    - [masc_team_memory_read]: 2 args (room, key) -> content.
    - [masc_team_memory_write]: 3 args (room, key, content) -> ack.
    - [masc_team_memory_search]: 2 args (room, query) -> hits.

    Internal: \[Sg\] (Oas tool-schema-gen alias), 4 schema field
    builders, 3 raw schemas, [parse], [schema_to_tool_schema],
    [default_namespace], validation / safe-path helpers
    ([validate_team_memory_room], [validate_authorized_room_id],
    [resolve_keeper_access], [authorize_team_memory], [is_safe_subpath],
    [nearest_existing_path], [safe_realpath]),
    [encoded_traversal_markers], [contains_encoded_traversal],
    [validate_team_memory_key], [resolve_key_path],
    [is_secret_token_char], [contains_secret_token_prefix].  All
    consumed only inside this file's [dispatch] pipeline. *)

(** {1 Catalog} *)

val schemas : Types.tool_schema list
(** Three tool schemas in declaration order: read, write, search.
    Consumed by {!Config} and {!Tools} during catalog assembly. *)

(** {1 Path resolution (test-visible)} *)

val team_memory_root : config:Coord.config -> string -> string
(** [team_memory_root ~config room] returns the root directory
    path for the named room (\[<masc_dir>/team-memory/<room>/\]).
    Pure path computation — does {b not} create the directory.
    Test fixtures use this to set up / tear down per-room state. *)

(** {1 Dispatch} *)

val dispatch :
  config:Coord.config ->
  agent_name:string ->
  name:string ->
  args:Yojson.Safe.t ->
  Keeper_types.tool_result option
(** [dispatch ~config ~agent_name ~name ~args] handles the three
    team-memory tool calls.  Returns [None] for unrecognised
    [name] so callers can fall through to other dispatchers.

    Authorization: [authorize_team_memory] runs before any I/O —
    failure surfaces as
    \`Some (false, json_error "...")\`.

    Path safety enforced before reads / writes:
    + [validate_team_memory_room] (external tool call room must be the
      flattened default namespace).
    + [validate_authorized_room_id] (post-authorization room id is a
      safe path segment).
    + [validate_team_memory_key] (no slashes / dots / encoded
      traversal markers).
    + [resolve_key_path] (final realpath stays under
      [team_memory_root]).
    + Secret-token-prefix scan on write content (rejects values
      that look like API keys / tokens).

    Error responses are pinned strings — operators see consistent
    diagnostic text across refactors. *)
