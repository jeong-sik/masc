open Types

let schemas : tool_schema list = [
  {
    name = "masc_worktree_create";
    description = "Create an isolated Git worktree for a task. \
Requires task_id (REQUIRED). Example: task_id='fix-login', task_id='feature/auth'. \
Optional base_branch (default: auto-detect main/develop). \
Use before starting file edits. After work, create PR then call masc_worktree_remove.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name. Leave empty to use your registered name.");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task identifier. REQUIRED. Example: 'fix-login', 'feature/auth', 'PK-12345'");
        ]);
        ("base_branch", `Assoc [
          ("type", `String "string");
          ("description", `String "Base branch (default: auto-detect). Rarely needed.");
          ("default", `String "develop");
        ]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };
  {
    name = "masc_worktree_remove";
    description = "Remove a worktree and its local branch after your work is merged. \
Requires task_id. Use the same task_id from masc_worktree_create. \
After completing work in a worktree created by masc_worktree_create.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID used when creating the worktree");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "task_id"]);
    ];
  };
  {
    name = "masc_worktree_list";
    description = "List all active worktrees in the project, showing which agents are working on what tasks. \
Use when checking for stale worktrees or seeing who is working in parallel. \
Pair with masc_worktree_remove to clean up stale entries.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
]
