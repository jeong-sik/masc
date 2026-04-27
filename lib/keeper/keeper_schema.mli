(** Keeper Schema — JSON Schema fragments for keeper authoring tools.

    Builds tool-input JSON schemas exposed by [tool_keeper_*] handlers and
    the dashboard authoring surface.  Centralises the enum strings (tool
    preset, sandbox profile, network mode, etc.) so a new value lands in
    one place and propagates to every tool that takes the keeper meta as
    input. *)

module Persona_contract = Keeper_persona_authoring_contract
(** Authoring contract used to derive the persona axis schemas. *)

val tool_preset_enum_strings : string list
(** Allowed values for [meta.tool_access.preset]. *)

val sandbox_profile_enum_strings : string list
(** Allowed values for [meta.sandbox.profile]. *)

val network_mode_enum_strings : string list
(** Allowed values for [meta.sandbox.network_mode]. *)

val shared_memory_scope_enum_strings : string list
(** Allowed values for [meta.shared_memory_scope]. *)

val tail_order_enum_strings : string list
(** Allowed values for log-tail ordering options. *)

val string_array_schema : Yojson.Safe.t
(** JSON schema fragment for a free-form [string list] field. *)

val persona_axis_schema : Persona_contract.archetype_axis -> Yojson.Safe.t
(** Schema fragment for one archetype axis (ranged enum + description). *)

val tool_access_schema : string -> Yojson.Safe.t
(** Schema fragment for [meta.tool_access] (preset + per-tool overrides);
    parameterised on the property description so create vs update tools
    can vary the surface without duplicating the body. *)

val keeper_schemas : Types.tool_schema list
(** Per-tool schemas for the keeper authoring surface. *)

val schemas : Types.tool_schema list
(** Alias for [keeper_schemas] used by the catalogue registry. *)
