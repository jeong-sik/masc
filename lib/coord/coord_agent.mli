(** Agent registry status and capability queries.

    Reads from [Coord_state] / [Coord_utils] and renders the result
    as a [Yojson.Safe.t] document for the MCP resource handlers and
    the [tool_agent] tool. *)

open Types
include module type of Coord_utils
include module type of Coord_state

(** Render the full agents/rooms snapshot as a JSON document with
    [{ count; agents = [...] }] shape. *)
val get_agents_status : config -> Yojson.Safe.t

(** Register or update an agent's capability list; returns a
    human-readable status line. *)
val register_capabilities :
  config -> agent_name:string -> capabilities:string list -> string

(** Update an agent's [status] and/or [capabilities]. *)
val update_agent_r :
  config ->
  agent_name:string ->
  ?status:string ->
  ?capabilities:string list ->
  unit ->
  string Types.masc_result

(** Find every registered agent advertising [capability]; returns
    [{ count; capability; agents = [...] }] or an error envelope. *)
val find_agents_by_capability :
  config -> capability:string -> Yojson.Safe.t
