(** Read-only static validation of proposed SKILL.md bytes in an exported
    artifact. [descriptors] is the caller's frozen admitted Tool surface.
    Alternatively, [draft_sha256] loads the exact source frozen during
    composition prepare using [draft_context]'s owned authority. Without it
    only the exported-artifact mode is available.
    Uses the canonical authoring validator, without publishing a
    reference, modifying a Skill source, or executing a composition. *)
val handle :
  descriptors:Keeper_tool_descriptor.t list ->
  draft_context:(Keeper_capability_surface.t * string) option ->
  config:Workspace.config -> args:Yojson.Safe.t -> Keeper_tool_execution.t
