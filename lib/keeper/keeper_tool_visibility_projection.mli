(** Projection from internal tool IDs to active schema-allowed names.

    This module is the SSOT for schema-allowed tool name resolution. All
    production code paths that produce schema-allowed text about tools
    (error messages, suggestions, recovery guidance) must route through
    this module rather than calling runtime alias tables directly.

    The consumer migration is partial (RFC-0284 §2.3): [mcp_server_eio_execute]
    uses [filter_schema_visible_suggestions] for "did you mean" error paths,
    and tool guidance uses [allowed_name] for hint rendering. The cross-module
    enforcement guard is tracked in RFC-0284 §4.2. *)

(** Surface context. Internal audit emits the raw internal identifier;
    schema-allowed rendering goes through alias resolution. *)
type context =
  | Schema_allowed
  | Internal_audit

(** Resolution outcome for a tool name lookup against the allowed schema.

    - [Use_public_name]   — a public alias is allowed on the active schema.
    - [Use_internal_name] — the internal identifier itself is allowed.
    - [No_allowed_name]   — known internal tool, but no allowed binding
                            this turn (caller should report the blocker
                            rather than invent a call).
    - [Unknown_name]      — the input does not match any known route. *)
type schema_resolution =
  | Use_public_name of
      { public_name : string
      ; internal_name : string
      }
  | Use_internal_name of { internal_name : string }
  | No_allowed_name of
      { internal_name : string
      ; public_names : string list
      }
  | Unknown_name of string

val allowed_set : string list -> (string, unit) Hashtbl.t

val public_aliases_for_internal_name : string -> string list

val public_alias_for_internal : string -> string option
(** First descriptor-backed public alias for an internal name, or [None]. *)

val resolve_allowed_name :
  allowed_tool_names:string list ->
  string ->
  schema_resolution
(** Resolve a tool name against the allowed-schema set. Strips the
    [mcp_masc__] prefix when present, canonicalizes through descriptor
    resolution, then prefers an allowed public alias over an allowed internal
    name. *)

val allowed_name :
  allowed_tool_names:string list ->
  string ->
  string option
(** Convenience wrapper around {!resolve_allowed_name} that returns the
    chosen schema-allowed name when one is allowed, or [None] when the
    tool is bound but not allowed, or unknown. *)

val render_reference :
  context:context ->
  allowed_tool_names:string list ->
  string ->
  string
(** Render a tool name for inclusion in a schema-allowed string. In
    [Internal_audit] context the raw name is returned unchanged; in
    [Schema_allowed] context, unresolved/unbound names expand into a
    blocker-report instruction so the caller cannot silently invent
    internal-only tool calls. *)

val blocker_guidance :
  allowed_tool_names:string list ->
  string ->
  string option
(** When a known internal tool has no allowed schema binding on
    this turn, return guidance directing the model to report the
    blocker (and, where available, mention which public alias would
    be needed). Returns [None] for visible / unknown tools. *)

val filter_schema_visible_suggestions : string list -> string list
(** Replace internal names with their public aliases and
    remove any that have no mapping. Used to sanitize "did you mean"
    suggestion lists so the caller never sees internal handler names. *)
