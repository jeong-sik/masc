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
        "keeper_fs_read";
        "keeper_fs_edit";
      ];
      next_action =
        "Run sandboxed filesystem read/edit probes and inspect failures for sandbox-path drift.";
    };
    {
      id = "shell_tools";
      label = "Shell tools";
      required_tools = [
        "keeper_shell";
        "keeper_bash";
      ];
      next_action =
        "Run read-only and execution shell probes under the keeper sandbox policy.";
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
        "masc_coordination_fsm_snapshot";
      ];
      next_action =
        "Run a goal lifecycle and prove list/upsert/transition/verify paths.";
    };
    {
      id = "coding_tools";
      label = "Coding and worktree tools";
      required_tools = [
        "masc_worktree_create";
        "masc_worktree_list";
        "masc_code_search";
        "masc_code_symbols";
        "masc_code_read";
        "masc_code_write";
        "masc_code_edit";
        "masc_code_git";
        "masc_code_shell";
      ];
      next_action =
        "Run a bounded keeper coding task and repair weak worktree/code-write/code-shell paths.";
    };
    {
      id = "pr_review_tools";
      label = "PR and review tools";
      required_tools = [
        "keeper_pr_list";
        "keeper_pr_status";
        "keeper_pr_create";
        "keeper_pr_review_read";
        "keeper_pr_review_comment";
        "keeper_pr_review_reply";
        "keeper_preflight_check";
      ];
      next_action =
        "Exercise PR creation/status/review read-comment-reply with keeper credentials.";
    };
    {
      id = "autoresearch_tools";
      label = "Autoresearch tools";
      required_tools = [
        "masc_autoresearch_start";
        "masc_autoresearch_status";
        "masc_autoresearch_cycle";
        "masc_autoresearch_inject";
        "masc_autoresearch_record_finding";
        "masc_autoresearch_search_findings";
        "masc_autoresearch_stop";
      ];
      next_action =
        "Run an autoresearch loop and prove start/status/cycle/finding/stop paths.";
    };
  ]
