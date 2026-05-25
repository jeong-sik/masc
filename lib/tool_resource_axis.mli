(** Tool_resource_axis -- normalize tool calls onto bounded local lanes.

    This module owns resource classification. Callers may pass public
    LLM-native aliases ([Bash], [Grep], [Write], ...), public MCP names, or
    internal handler names; classification normalizes aliases before looking at
    command payloads. *)

type t =
  | Ungated
  | Shell
  | Github
  | Docker
  | Filesystem_read
  | Filesystem_write
  | Board_write
  | Coordination_write
  | Web
  | Generic_write

val to_string : t -> string

val classify :
  tool_name:string -> arguments:Yojson.Safe.t -> is_read_only:bool -> t
