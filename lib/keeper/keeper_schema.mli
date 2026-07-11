(** Keeper Schema — JSON Schema fragments for keeper authoring tools.

    Builds tool-input JSON schemas exposed by [tool_keeper_*] handlers and
    the dashboard authoring surface. *)

val network_mode_enum_strings : string list
(** Allowed values for explicit sandbox-management tool inputs. *)

val sandbox_stop_scope_enum_strings : string list
(** Allowed container scopes for the explicit sandbox-stop tool. *)


val tail_order_enum_strings : string list
(** Allowed values for log-tail ordering options. *)

val string_array_schema : Yojson.Safe.t
(** JSON schema fragment for a free-form [string list] field. *)

val tool_access_schema : string -> Yojson.Safe.t
(** Schema fragment for [meta.tool_access] (string-array tool candidate profile list);
    parameterised on the property description so create vs update tools
    can vary the surface without duplicating the body. *)

val keeper_schemas : Masc_domain.tool_schema list
(** Per-tool schemas for the keeper authoring surface. *)

val schemas : Masc_domain.tool_schema list
(** Alias for [keeper_schemas] used by the catalogue registry. *)
