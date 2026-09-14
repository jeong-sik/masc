(** Which built-in tools declare that calling them again with the same input
    moves the machine on, so the keeper's loop guard does not read the
    repeat as a call getting nowhere.

    The declaration lives in each tool's own [config/tools/<name>.toml], as
    [same_input_advances = true], next to the description that says what a
    repeat does ("Advance the shared MSX machine by frames"). This module
    only reads it; it holds no list of its own, for the reason
    {!Tool_loading_declarations} holds none: a roster somebody maintains
    drifts from the tools it names.

    Absence means {!Tool_definition_toml.Same_input_reads}: a tool that says
    nothing is read the way every tool was read before this axis existed.

    What the declaration reaches, and what it does not. It exempts the tool
    from the adjacent-identical-input axis of the loop guard
    ([Keeper_agent_run.repeated_tool_call_input]) only. The
    input-and-output axis still counts it: a step whose observation comes
    back unchanged three times is still a step that moved nothing, and the
    declaration does not claim otherwise. Measured 2026-09-14 on
    msx-retro-mania: 49 of the day's 58 loop-guard yields were
    [masc_msx_step] and [masc_msx_press] at exactly five identical calls --
    five steps of sixty frames, the ordinary way to let a title play out. *)

(** [repeat_of_tool name] is what [config/tools/<name>.toml] declares;
    [Same_input_reads] for a name with no such file. *)
val repeat_of_tool : string -> Tool_definition_toml.repeat

(** [advances name] is [repeat_of_tool name = Same_input_advances], in the
    shape the loop guard takes. *)
val advances : string -> bool
