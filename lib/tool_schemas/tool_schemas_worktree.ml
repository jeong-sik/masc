open Types

let schemas : tool_schema list = [
  {
    name = "masc_worktree_create";
    description = "Create an isolated Git worktree for a task. \
Requires task_id (REQUIRED). Example: task_id='fix-login', task_id='feature/auth'. \
The worktree is rooted in your playground clone — typically at \
.masc/playground/<your-name>/repos/<repo>/.worktrees/<agent>-<task_id>. \
Repo resolution: pass repo_name to target a specific clone, otherwise \
the first git clone under your repos/ is used (alphabetical). Clone \
the target repo first with keeper_shell op=git_clone if your repos/ \
directory is empty. After work, create a PR then call \
masc_worktree_remove.";
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
        ("repo_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional. Disambiguates which playground clone to use when you have multiple repos under .masc/playground/<your-name>/repos/. Example: repo_name='masc-mcp'. Allowed characters: [A-Za-z0-9._-]. Must be a single directory name — no slashes, no path traversal. The special values '.' and '..' match the character class above but are rejected at runtime in tool_worktree.handle_worktree_create and Room_worktree.worktree_create_r. Leave empty to auto-pick the first clone alphabetically.");
          (* Negative lookahead is not supported by JSON Schema Draft 7
             (used by most MCP clients), so the pattern below only
             enforces the character class. The ".", ".." special cases
             are enforced at runtime so the three layers (schema,
             tool dispatch, Room resolver) agree on the same rule even
             though the schema cannot express it. *)
          ("pattern", `String "^[A-Za-z0-9._-]+$");
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
