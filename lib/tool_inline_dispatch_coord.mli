(** Tool_inline_dispatch_coord — room lifecycle tool handlers.

    Three [masc_*] handlers covering the agent room lifecycle:
    {!handle_start} (project root + join + optional task),
    {!handle_join} (idempotent re-join), {!handle_leave}
    (graceful exit).

    Extracted from {!Tool_inline_dispatch} to keep the dispatch
    table file under the lint cap.  All three return
    [tool_result option] = [Some (success, message)] or [None]
    when the dispatcher should fall through to a default handler. *)

val handle_start :
  Tool_inline_dispatch_types.context ->
  Tool_inline_dispatch_types.tool_result option
(** [handle_start ctx] handles [masc_start] — the compound
    "set project root + join + optional task" onboarding flow.

    {2 Argument resolution}

    - [path] / [room]: project root.  When both are empty AND
      the runtime already has an initialised project, falls
      back to the existing project rather than erroring.
    - [task_title] (optional): when non-empty, performs a
      compound add-task + claim + plan-set-task.

    {2 Path expansion}

    [~/...] and bare [~] expand against [HOME]
    (defaults to [/tmp] when unset).  Relative paths resolve
    against [Sys.getcwd ()].  Absolute paths are used verbatim.

    {2 Three-step pipeline}

    1. **Set project root**: validates the directory exists,
       initialises {!Coord} when not already initialised, and
       atomically swaps [state.room_config].
    2. **Join**: idempotent — re-join is a no-op when already
       in the room.  Failure surfaces with hint
       [["Hint: try masc_join separately."]].
    3. **Optional task creation**: when [task_title] non-empty,
       runs [Coord_task.add_task] + extracts the task id from
       the [["Added task-NNN: title"]] response prefix.

    {2 Error message wording (pinned)}

    - Empty path with no existing project:
      ["path is required when no project scope is set. Provide the project directory path."]
    - Directory missing:
      ["Directory not found: <expanded>"]
    - Step 1 failure:
      ["masc_start failed while setting project scope: <e>"]
    - Step 2 failure:
      ["masc_start failed at join: <e>\nHint: try masc_join separately."]

    Operator runbooks grep on these prefixes; pinning at the
    contract seam so a future "let's rephrase the errors" PR
    must touch this. *)

val handle_join :
  Tool_inline_dispatch_types.context ->
  Tool_inline_dispatch_types.tool_result option
(** [handle_join ctx] handles [masc_join] — register the agent
    in the project namespace.  Idempotent: re-joining is a
    no-op success.  Reads [path] / [room] / [agent] /
    [capabilities] (string list) from [ctx.arguments]. *)

val handle_leave :
  Tool_inline_dispatch_types.context ->
  Tool_inline_dispatch_types.tool_result option
(** [handle_leave ctx] handles [masc_leave] — graceful agent
    exit. *)
