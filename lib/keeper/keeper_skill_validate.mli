(** Read-only static validation of proposed SKILL.md bytes in an exported
    artifact. Uses the canonical authoring validator, without publishing a
    reference, modifying a Skill source, or executing a composition. *)
val handle :
  config:Workspace.config -> args:Yojson.Safe.t -> Keeper_tool_execution.t
