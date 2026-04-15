(** Keeper GitHub tool handler (primitive gh CLI wrapper).

    Shared helpers live in {!Keeper_gh_shared}. PR workflow handlers have
    been extracted to {!Keeper_tool_pr_workflow}, {!Keeper_tool_pr_submit},
    and {!Keeper_tool_pr_review}. This module will be absorbed into
    {!Keeper_tool_github} once the final extraction lands. *)

val handle_keeper_github :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string
