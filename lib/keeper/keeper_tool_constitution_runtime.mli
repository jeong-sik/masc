(** Keeper tools for the world constitution (RFC-0442).

    A keeper writes a norm its world agreed on, or takes one back. Whether the
    world agreed is settled on the board before either call; these tools carry
    the decision to the one place a conversation cannot reach — the system
    prompt every keeper in the world reads. *)

val render_byte_ceiling : int
(** Bytes the rendered articles may occupy. The articles ride every turn of
    every keeper in the world, so this is the one brake RFC-0442 keeps. A world
    at the ceiling takes no new article until someone decides what to drop;
    nothing expires on its own, because a silent deletion is worse than a
    blocked write nobody can miss. *)

val write_with_outcome :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t

val remove_with_outcome :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t
(** Removing an article that is not held is a failure, not a quiet success. A
    keeper that mistyped an id needs to learn that here rather than believe a
    norm is gone. *)
