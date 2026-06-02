
(** Tool_permission_map — Shared tool→permission resolution.

    Centralizes the permission mapping used by both auth enforcement and
    role-policy derivation so they do not maintain separate hardcoded tool
    lists. *)

val known_tool_names : string list
(** Tool names covered by Tool_catalog surfaces or explicit metadata. Useful
    for policy derivation that must include permission-mapped tools even when
    they are not on a public surface. *)

val permission_for_tool : string -> Masc_domain.permission option
(** Effective required permission for a tool from Tool_catalog metadata. *)
