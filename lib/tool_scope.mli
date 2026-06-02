(** Tool scope classification — external MCP surface vs internal agent runtime.

    Tool scope is intentionally not tied to Keeper, Board, Goal, Task, Sandbox,
    Provider, or Model domains. Concrete runtimes provide their own allowlists
    behind their runtime boundary. *)

type scope =
  | Surface
  | Agent_internal

val classify : name:string -> scope
(** [classify ~name] returns the scope for the named tool. Default [Surface]. *)

val scope_to_string : scope -> string

val agent_internal_names : unit -> string list
