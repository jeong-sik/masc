(** Tool_permission_map — Shared tool→permission resolution.

    Centralizes the permission mapping used by both auth enforcement and
    role-policy derivation so they do not maintain separate hardcoded tool
    lists. *)

val declared_permission_for_tool : string -> Types.permission option
(** Tool_catalog-declared permission, when present. *)

val legacy_permission_for_tool : string -> Types.permission option
(** Compatibility fallback for tools that do not yet declare
    [required_permission] in Tool_catalog metadata. *)

val known_tool_names : string list
(** Tool names covered by either Tool_catalog metadata or the legacy
    fallback table. Useful for policy derivation that must include
    permission-mapped tools even when they are not on a public surface. *)

val permission_for_tool : string -> Types.permission option
(** Effective required permission for a tool:
    Tool_catalog metadata first, legacy fallback second. *)
