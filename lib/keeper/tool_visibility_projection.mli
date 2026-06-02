(** Projection from internal tool IDs to active schema-visible names.

    This module is the SSOT for schema-visible tool name resolution. All
    production code paths that produce schema-visible text about tools
    (error messages, suggestions, recovery guidance) must route through
    this module rather than calling runtime alias tables directly.

    The consumer migration is complete: [mcp_server_eio_execute] uses
    [filter_schema_visible_suggestions] for "did you mean" error paths,
    and tool guidance uses [visible_name] for hint rendering. *)

(** Surface context. Internal audit emits the raw internal identifier;
    schema-visible rendering goes through alias resolution. *)
type context =
  | Schema_visible
  | Internal_audit

(** Resolution outcome for a tool name lookup against the visible schema.

    - [Use_public_name]   — a public alias is visible on the active schema.
    - [Use_internal_name] — the internal identifier itself is visible.
    - [No_visible_name]   — known internal tool, but no visible binding
                            this turn (caller should report the blocker
                            rather than invent a call).
    - [Unknown_name]      — the input does not match any known route. *)
type schema_resolution =
  | Use_public_name of
      { public_name : string
      ; internal_name : string
      }
  | Use_internal_name of { internal_name : string }
  | No_visible_name of
      { internal_name : string
      ; public_names : string list
      }
  | Unknown_name of string

val visible_set : string list -> (string, unit) Hashtbl.t

val public_aliases_for_internal_name : string -> string list

val public_alias_for_internal : string -> string option
(** First descriptor-backed public alias for an internal name, or [None]. *)

val resolve_visible_name :
  visible_tool_names:string list ->
  string ->
  schema_resolution
(** Resolve a tool name against the visible-schema set. Strips the
    [mcp_masc__] prefix when present, canonicalizes through descriptor
    resolution, then prefers a visible public alias over a visible internal
    name. *)

val visible_name :
  visible_tool_names:string list ->
  string ->
  string option
(** Convenience wrapper around {!resolve_visible_name} that returns the
    chosen schema-visible name when one is visible, or [None] when the
    tool is bound but not visible, or unknown. *)

val render_reference :
  context:context ->
  visible_tool_names:string list ->
  string ->
  string
(** Render a tool name for inclusion in a schema-visible string. In
    [Internal_audit] context the raw name is returned unchanged; in
    [Schema_visible] context, unresolved/unbound names expand into a
    blocker-report instruction so the caller cannot silently invent
    internal-only tool calls. *)

val blocker_guidance :
  visible_tool_names:string list ->
  string ->
  string option
(** When a known internal tool has no visible schema-visible binding on
    this turn, return guidance directing the model to report the
    blocker (and, where available, mention which public alias would
    be needed). Returns [None] for visible / unknown tools. *)

val filter_schema_visible_suggestions : string list -> string list
(** Replace internal names with their public aliases and
    remove any that have no mapping. Used to sanitize "did you mean"
    suggestion lists so the caller never sees internal handler names. *)
