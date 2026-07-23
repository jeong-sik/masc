(** Mcp_tool_runtime_workspace — project startup tool handler.

    Handles project root setup and optional task bootstrapping.

    Extracted from {!Mcp_tool_runtime} to keep the runtime
    router under the lint cap.  The handler returns
    [Tool_result.result option] — [Some] when the tool name matches,
    [None] when the dispatcher should fall through to a default handler.

    RFC-0062 Phase 4c-2: handlers now accept [~tool_name ~start_time]
    and return structured [Tool_result.result] instead of [(bool * string)]. *)

val handle_start :
  tool_name:string -> start_time:float ->
  Mcp_tool_runtime_types.context ->
  Tool_result.result option
(** [handle_start ~tool_name ~start_time ctx] handles [masc_start] —
    the compound "set project root + join + optional task" onboarding flow.

    {2 Argument resolution}

    - [path] / [workspace]: project root.  When both are empty AND
      the runtime already has an initialised project, falls
      back to the existing project rather than erroring.
    - [task_title] (optional): when non-empty, performs a
      compound add-task + claim + plan-set-task.

    {2 Path expansion}

    [~/...] and bare [~] expand against [HOME]
    (defaults to [/tmp] when unset).  Relative paths resolve
    against the initialized workspace base path, or
    [Config_dir_resolver.base_path_or_cwd ()] when none is set.
    Absolute paths are used verbatim.

    {2 Three-step pipeline}

    1. **Set workspace projection**: validates the directory exists and that
       its exact MASC root equals the process-fixed runtime root, initialises
       {!Workspace} when not already initialised, then atomically swaps the
       workspace projection while reusing the one publication-recovery runtime
       via {!Mcp_server.set_workspace_config}.
    2. **Bind agent session**: idempotent when already bound.
       Failure surfaces as a startup error.
    3. **Optional task creation**: when [task_title] non-empty,
       runs [Workspace_task.add_task] + extracts the task id from
       the [["Added task-NNN: title"]] response prefix.

    {2 Error message wording (pinned)}

    - Empty path with no existing project:
      ["path is required when no project scope is set. Provide the project directory path."]
    - Directory missing:
      ["Directory not found: <expanded>"]
    - Step 1 failure:
      ["masc_start failed while setting project scope: <e>"]
    - Step 2 failure:
      ["masc_start failed while binding agent session: <e>"]

    Operator runbooks grep on these prefixes; pinning at the
    contract seam so a future "let's rephrase the errors" PR
    must touch this. *)
