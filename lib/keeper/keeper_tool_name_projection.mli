(** Projection from internal keeper tool IDs to active model-facing names.

    This module is the SSOT for model-facing tool name resolution. All
    production code paths that produce model-visible text about tools
    (error messages, suggestions, recovery guidance) must route through
    this module rather than calling [Keeper_tool_alias] directly.

    The consumer migration is complete: [mcp_server_eio_execute] uses
    [filter_model_visible_suggestions] for "did you mean" error paths,
    and [keeper_tool_guidance] uses [model_facing_name] for hint rendering. *)

(** Surface context. Internal audit emits the raw internal identifier;
    model-facing rendering goes through alias resolution. *)
type context =
  | Model_facing
  | Internal_audit

(** Resolution outcome for a tool name lookup against the visible schema.

    - [Use_public_name]   — a public alias is visible on the active schema.
    - [Use_internal_name] — the internal identifier itself is visible.
    - [No_visible_name]   — known internal tool, but no visible binding
                            this turn (model should report the blocker
                            rather than invent a call).
    - [Unknown_name]      — the input does not match any known route. *)
type model_resolution =
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

val resolve_model_name :
  visible_tool_names:string list ->
  string ->
  model_resolution
(** Resolve a tool name against the visible-schema set. Strips the
    [mcp_masc__] prefix when present, canonicalizes through descriptor
    resolution, then prefers a visible public alias over a visible internal
    name. *)

val model_name :
  visible_tool_names:string list ->
  string ->
  string option
(** Convenience wrapper around {!resolve_model_name} that returns the
    chosen model-facing name when one is visible, or [None] when the
    tool is bound but not visible, or unknown. *)

val render_reference :
  context:context ->
  visible_tool_names:string list ->
  string ->
  string
(** Render a tool name for inclusion in a model-visible string. In
    [Internal_audit] context the raw name is returned unchanged; in
    [Model_facing] context, unresolved/unbound names expand into a
    blocker-report instruction so the model cannot silently invent
    internal-only tool calls. *)

val blocker_guidance :
  visible_tool_names:string list ->
  string ->
  string option
(** When a known internal tool has no visible model-facing binding on
    this turn, return guidance directing the model to report the
    blocker (and, where available, mention which public alias would
    be needed). Returns [None] for visible / unknown tools. *)

val filter_model_visible_suggestions : string list -> string list
(** Replace internal [keeper_*] names with their public aliases and
    remove any that have no mapping. Used to sanitize "did you mean"
    suggestion lists so the model never sees internal handler names. *)
