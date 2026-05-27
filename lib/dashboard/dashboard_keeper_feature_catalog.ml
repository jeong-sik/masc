type feature_spec = {
  id : string;
  label : string;
  required_tools : string list;
  next_action : string;
}

let tool_features =
  [
    {
      id = "base_tools";
      label = "Base context tools";
      required_tools = [
        "keeper_time_now";
        "keeper_context_status";
        "keeper_memory_search";
      ];
      next_action =
        "Exercise base keeper context tools and repair missing tool-call evidence.";
    };
    {
      id = "board_tools";
      label = "Board tools";
      required_tools = [
        "keeper_board_get";
        "keeper_board_list";
        "keeper_board_post";
        "keeper_board_comment";
        "keeper_board_vote";
      ];
      next_action =
        "Run a board workflow that reads, lists, posts, comments, and votes successfully.";
    };
    {
      id = "filesystem_tools";
      label = "Filesystem tools";
      required_tools = [
        "tool_read_file";
        "tool_edit_file";
        "tool_write_file";
      ];
      next_action =
        "Run sandboxed filesystem read/edit probes and inspect failures for sandbox-path drift.";
    };
    {
      id = "search_files_tools";
      label = "SearchFiles tools";
      required_tools = [
        "tool_search_files";
        "tool_execute";
      ];
      next_action =
        "Run SearchFiles and Execute probes under the keeper sandbox policy.";
    };
    {
      id = "library_tools";
      label = "Library tools";
      required_tools = [
        "keeper_library_search";
        "keeper_library_read";
      ];
      next_action =
        "Exercise library search/read from an autonomous keeper turn.";
    };
    {
      id = "web_search_tools";
      label = "Web search tools";
      required_tools = [
        "masc_web_search";
      ];
      next_action =
        "Run a current-information keeper search, then fetch a selected result with masc_web_fetch and verify both tools succeed.";
    };
    {
      id = "web_fetch_tools";
      label = "Web fetch tools";
      required_tools = [
        "masc_web_fetch";
      ];
      next_action =
        "Run a web page fetch and verify successful masc_web_fetch evidence.";
    };
    {
      id = "taskboard_tools";
      label = "Taskboard tools";
      required_tools = [
        "keeper_tasks_list";
        "keeper_tasks_audit";
        "keeper_task_claim";
        "keeper_task_done";
        "keeper_task_submit_for_verification";
        "keeper_task_force_release";
        "keeper_task_create";
      ];
      next_action =
        "Run a claim-to-verification task lifecycle and prove each taskboard tool succeeds.";
    };
    {
      id = "approval_tools";
      label = "Approval pending queue read tool";
      required_tools = [
        "masc_approval_pending";
      ];
      next_action =
        "Exercise approval pending-queue readback through the current public keeper/MCP tool surface.";
    };
    {
      id = "goal_tools";
      label = "Goal and planning tools";
      required_tools = [
        "masc_goal_list";
        "masc_goal_upsert";
        "masc_goal_transition";
        "masc_goal_verify";
      ];
      next_action =
        "Run a goal lifecycle and prove list/upsert/transition/verify paths.";
    };
  ]
