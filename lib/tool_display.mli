(** Human-facing label for a wire tool name.

    Pure and display-only: the result is drawn in the TUI and never sent to a
    model, placed in a tool schema, or matched against a registry. The wire
    name stays the only identity.

    Rule: split on ['_'], upper-case the first ASCII letter of each non-empty
    segment, keep the rest of each segment as-is, join. Prefixes are kept, so
    ["keeper_task_done"] becomes ["KeeperTaskDone"] and an already Pascal name
    such as ["WebFetch"] is returned unchanged. This is not injective over all
    strings (["a_b"] and ["aB"] both give ["AB"]); callers that need a unique
    label must check the set of names they label.

    Coupling: TUI PTY needles that wait for activity rows (test/tui_keyboard_*.py)
    match these labels. Changing this rule means updating those needles too. *)

val label : string -> string
