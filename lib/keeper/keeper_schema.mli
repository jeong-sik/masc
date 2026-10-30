(** Keeper Schema — JSON Schema fragments for keeper authoring tools.

    Builds tool-input JSON schemas exposed by [tool_keeper_*] handlers and
    the dashboard authoring surface. *)

val schemas : Masc_domain.tool_schema list
(** Per-tool schemas for the keeper authoring surface. *)
