open Types

let schemas : tool_schema list = [
  {
    name = "masc_worktree_create";
    description = "Create an isolated Git worktree for a task. \
Requires task_id (REQUIRED). Example: task_id='fix-login', task_id='feature/auth'. \
The worktree is rooted in your sandbox repo clone — typically at \
repos/<repo>/.worktrees/<agent>-<task_id>. \
Repo resolution: pass repo_name to target a specific clone, otherwise \
the first git clone under your repos/ is used (alphabetical). If \
repo_name matches a workspace git repo under your base_path, MASC \
auto-provisions the sandbox clone on demand; otherwise clone the \
target repo first with keeper_shell op=git_clone. After work, create \
a PR then call \
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
          ("description", `String "Base branch (default: auto). Rarely needed. Auto resolves origin/HEAD, then origin/main, origin/master, origin/develop.");
          ("default", `String "auto");
        ]);
        ("repo_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Required. Selects the sandbox repo clone under repos/. Example: repo_name='masc-mcp'. Allowed characters: [A-Za-z0-9._-]. Must be a single directory name — no slashes, no path traversal. The special values '.' and '..' match the character class above but are rejected at runtime in tool_worktree.handle_worktree_create and Coord_worktree.worktree_create_r. If the sandbox clone is missing and a matching workspace repo exists under base_path, MASC auto-provisions repos/<repo_name>/ first. Omitting repo_name is an error.");
          (* Negative lookahead is not supported by JSON Schema Draft 7
             (used by most MCP clients), so the pattern below only
             enforces the character class. The ".", ".." special cases
             are enforced at runtime so the three layers (schema,
             tool dispatch, Coord resolver) agree on the same rule even
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
          ("description", `String "Optional. Leave empty to use your registered agent name.");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID used when creating the worktree");
        ]);
      ]);
      ("required", `List [`String "task_id"]);
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
