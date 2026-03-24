open Types

let schemas : tool_schema list = [
  {
    name = "masc_worktree_create";
    description = "Create an isolated Git worktree for your work under <repo_root>/.worktrees/{agent}-{task}/ with a new branch. \
Use when starting a new task that needs file isolation from other agents. \
After work, create a PR with `gh pr create` and call masc_worktree_remove.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name (e.g., 'claude')");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID or feature name (e.g., 'PK-12345' or 'fix-login')");
        ]);
        ("base_branch", `Assoc [
          ("type", `String "string");
          ("description", `String "Base branch to create worktree from (default: 'develop' or 'main')");
          ("default", `String "develop");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "task_id"]);
    ];
  };
  {
    name = "masc_worktree_remove";
    description = "Remove a worktree and its local branch after your work is merged. \
Use when your PR has been merged and the worktree is no longer needed. \
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
