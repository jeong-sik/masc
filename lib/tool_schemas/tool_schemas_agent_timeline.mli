(** Tool_schemas_agent_timeline — the agent-timeline tool declaration.

    The wire name is written once here; the advertised set and the set
    [Tool_agent_timeline.dispatch] routes both derive from {!definitions}. *)

type operation = Agent_timeline [@@deriving enumerate]
(** Closed vocabulary routed by [Tool_agent_timeline.dispatch]. *)

val operations : operation list
(** Exhaustive projection of the operations. *)

val operation_name : operation -> string
(** Canonical wire name for an operation. *)

val definitions : (operation * Masc_domain.tool_schema) list
(** Each operation paired with its declaration. Decoded once at module
    initialization; a missing or malformed file refuses the boot. *)

val schemas : Masc_domain.tool_schema list
(** The declarations from {!definitions}. *)

val operation_of_tool_name : string -> operation option
(** Parse a canonical wire name at the dispatch boundary. *)
