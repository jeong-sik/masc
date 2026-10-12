(** Read-only static validation of proposed SKILL.md bytes in an exported
    artifact. [descriptors] is the caller's frozen admitted Tool surface.
    Uses the canonical authoring validator, without publishing a
    reference, modifying a Skill source, or executing a composition. *)
val handle :
  descriptors:Keeper_tool_descriptor.t list ->
  config:Workspace.config -> args:Yojson.Safe.t -> Keeper_tool_execution.t
