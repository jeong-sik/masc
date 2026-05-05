
(** Tool_access_role — Role-based tool access policy builder.

    Maps each authentication role (Worker, Admin) to a
    Tool_access_policy.t that determines which tools the role can invoke.

    The role policy is derived from [Tool_permission_map.permission_for_tool], so
    Tool_catalog-declared required_permission metadata and auth-layer
    fallbacks stay aligned instead of maintaining a second hardcoded tool list.

    @since 2.204.0 — Phase 0 of Tool Gate architecture (#4381) *)

val admin_only_tools : unit -> string list
(** Tools requiring Admin role. Derived from [Tool_permission_map.permission_for_tool]. *)

val worker_only_tools : unit -> string list
(** Tools requiring at least Worker role. Derived from [Tool_permission_map.permission_for_tool]. *)

val policy_for_role : Masc_domain.agent_role -> Tool_access_policy.t
(** Build the access policy for a role.
    - Admin: all tools allowed
    - Worker: all except admin-only tools

    Note: Keeper_denied and Keeper_internal filtering is handled separately
    by keeper_exec_tools and the mode gate (allow_direct_call), not by
    role policies. *)
