(** Keeper Schema — JSON Schema fragments for keeper authoring tools.

    Builds tool-input JSON schemas exposed by [tool_keeper_*] handlers and
    the dashboard authoring surface. *)

val network_mode_enum_strings : string list
(** Allowed values for explicit sandbox-management tool inputs. *)

val string_array_schema : Yojson.Safe.t
(** JSON schema fragment for a free-form [string list] field. *)

val schemas : Masc_domain.tool_schema list
(** Per-tool schemas for the keeper authoring surface. *)
