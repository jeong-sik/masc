open Types

let schemas : tool_schema list = [
  {
    name = "masc_worktree_create";
    description = "Create an isolated Git worktree for your work. This requires the active MASC base repository to have `.git` (resolved with git root detection) and always creates worktrees under `<repo_root>/.worktrees/{agent}-{task}/` with a new branch. If you are in a workspace with multiple repos, run MASC from the target repo root. This is BETTER than file locks: you get complete isolation and can work in parallel. After work, create a PR with `gh pr create` and remove the worktree.";
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
    description = "Remove a worktree after your work is merged. This cleans up both the worktree directory and the local branch. Call this after your PR is merged to keep the repo clean.";
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
    description = "List all active worktrees in the project. Shows which agents are working on what tasks.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
]
