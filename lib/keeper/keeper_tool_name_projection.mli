(** Keeper_tool_name_projection -- model-facing names for keeper tools.

    This module is the narrow boundary between internal handler IDs
    ([keeper_bash], [keeper_shell], ...) and names the model may spell in
    the active tool schema ([Bash], [Read], ...). It deliberately delegates
    alias truth to {!Keeper_tool_alias}; do not add another mapping table
    here. *)

type context =
  | Model_facing
      (** Prompt, recovery, nudge, and tool-call correction text. *)
  | Internal_audit
      (** Logs, metrics, docs, and tests that explicitly discuss internals. *)

type model_resolution =
  | Use_public_name of
      { public_name : string
      ; internal_name : string
      }
      (** A public alias is visible; model-facing text should use it. *)
  | Use_internal_name of { internal_name : string }
      (** The internal name itself is visible in this turn's active schema. *)
  | No_visible_name of
      { internal_name : string
      ; public_names : string list
      }
      (** The internal tool is known, but no callable model-facing name is
          visible in this turn. *)
  | Unknown_name of string
      (** The supplied name is not recognised as public, public-MCP, or
          internal. *)

val public_aliases_for_internal_name : string -> string list
(** All public LLM-native aliases backed by [internal_name], in
    {!Keeper_tool_alias.public_names} order. *)

val resolve_model_name
  :  visible_tool_names:string list
  -> string
  -> model_resolution
(** Resolve an internal handler name to the name model-facing text may
    mention under the current active schema. Public aliases win over
    visible internal names, so mixed surfaces still prefer public names. *)

val model_name
  :  visible_tool_names:string list
  -> string
  -> string option
(** Convenience wrapper over {!resolve_model_name}. Returns [None] when the
    tool is known but absent from the active schema, or unknown. *)

val render_reference
  :  context:context
  -> visible_tool_names:string list
  -> string
  -> string
(** Render a short reference suitable for user/model-facing text. In
    [Model_facing] context, hidden internal names are never returned as the
    callable suggestion. In [Internal_audit] context, the internal name is
    returned verbatim because the caller has explicitly opted into internal
    nomenclature. *)

val blocker_guidance
  :  visible_tool_names:string list
  -> string
  -> string option
(** If [internal_name] has no model-callable name in the active schema,
    return guidance that tells the model to report the blocker instead of
    inventing an internal tool call. *)
