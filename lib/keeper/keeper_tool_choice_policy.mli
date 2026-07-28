(** Keeper-owned provider tool-choice normalization.

    Keeper exposes a broad optional tool surface. A provider-level strict
    [Any] or named [Tool] choice would force a tool call even when the Keeper
    can answer or finish without one. Both request preflight and actual runtime
    dispatch must consume this same projection. *)

val relax_strict_for_keeper :
  Agent_sdk.Types.tool_choice option -> Agent_sdk.Types.tool_choice option
