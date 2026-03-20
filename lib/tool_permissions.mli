(** Tool permission filter

    Enforces capability-based access control on tool dispatch.
    Installs as a pre-hook that short-circuits unauthorized calls.

    Enforces admin-capability gating on protected tool calls.
    All other tools are unrestricted.

    @since 2.95.0
*)

(** [admin_tools] is the list of tool names requiring admin capability. *)
val admin_tools : string list

(** [requires_admin tool_name] returns true if the tool needs admin cap. *)
val requires_admin : string -> bool

(** Capability checker: [agent_name -> capability_name -> bool]. *)
type capability_checker = string -> string -> bool

(** [set_capability_checker f] sets the function used to check agent
    capabilities.  Default denies all.  In production, wire this to
    [Agent_identity.has_capability] via the agent registry. *)
val set_capability_checker : capability_checker -> unit

(** [check ~agent_name ~tool_name] returns [Ok ()] if allowed,
    [Error reason] if denied. *)
val check : agent_name:string -> tool_name:string -> (unit, string) result

(** [install ~get_agent_name] installs the permission pre-hook.
    [get_agent_name] returns the current session's agent name. *)
val install : get_agent_name:(unit -> string option) -> unit
