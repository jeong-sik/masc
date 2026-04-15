(** Tool_shard — Dynamic tool sharding for MASC agents.

    Allows tools to be granted/revoked at runtime like equipment slots.
    Each agent can have multiple active shards that contribute tools.

    @since 2.62.0 *)

(** A named collection of tools that can be granted/revoked. *)
type shard = {
  name : string;
  tools : Types.tool_schema list;
  read_only_tools : string list;
  removable : bool;  (** true = can be revoked at runtime *)
  description : string;
}

module StringMap = Map.Make(String)

(** Predefined shards *)

let base_tools : Types.tool_schema list = [
  (* Stay silent: no-op tool for tool_choice=Any turns.
     Lets the model explicitly skip a turn without being forced
     to call a real tool when there is nothing to do. *)
  {
    name = "keeper_stay_silent";
    description = "Do nothing this turn. Call when you have no pending work and no information \
to share. Costs no resources. Prefer this over calling a tool with no purpose.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  (* Time *)
  {
    name = "keeper_time_now";
    description = "Get current server time. Returns now_iso (ISO8601) and now_unix (float). \
Use to timestamp events, check elapsed time, or include current time in reports.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  (* Context status *)
  {
    name = "keeper_context_status";
    description = "Check your own context window usage and session state. Returns: \
name (your keeper name), context_ratio (0.0-1.0), context_tokens, context_max, \
message_count, generation, last_model_used, continuity_summary, and your three \
canonical playground paths (playground_bundle, playground_mind, playground_repos) \
relative to the server base_path, plus tool_paths (mind, repos, bundle) which you can pass \
directly as path or cwd to keeper tools without prefix. Use when deciding whether to compact context, \
extend turns, hand off to the next generation, or resolve a path without \
string-interpolating your own keeper name.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  (* Memory *)
  {
    name = "keeper_memory_search";
    description = "Search memory for past goals, decisions, progress, or conversation history. \
Returns scored results with metadata. Default searches the structured memory bank. \
Use 'kind' to filter (goal, decision, progress, next, open_question, constraints). \
Use source='history' for raw user messages, source='all' for both.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [("type", `String "string"); ("description", `String "keyword to search for")]);
        ("kind", `Assoc [("type", `String "string"); ("enum", `List [`String "goal"; `String "decision"; `String "progress"; `String "next"; `String "open_question"; `String "constraints"]); ("description", `String "Filter by memory kind")]);
        ("limit", `Assoc [("type", `String "integer"); ("description", `String "max results (1-10, default 5)")]);
        ("source", `Assoc [("type", `String "string"); ("enum", `List [`String "memory"; `String "history"; `String "all"]); ("description", `String "Search scope: memory (default, structured notes), history (raw messages), or all")]);
      ]);
      ("required", `List [`String "query"]);
    ];
  };
  (* Tool self-introspection — lets the keeper enumerate its own capabilities *)
  {
    name = "keeper_tools_list";
    description = "List all tools currently available to you, grouped by category. \
Use when asked 'what can you do?' or when you need to discover your capabilities. \
Returns tool names organized by category. Only includes tools allowed by your \
current preset and policy.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
]

let board_tools : Types.tool_schema list = [
  {
    name = "keeper_board_get";
    description = "Read a single board post with all its comments and votes. \
Use before deciding to comment, vote, or escalate. Returns post content, author, \
timestamp, vote_count, and comment thread. \
post_id format: 'p-xxxx'. Get post_id from keeper_board_list results.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID (format: p-xxxx). Get from keeper_board_list.")]);
      ]);
      ("required", `List [`String "post_id"]);
    ];
  };
  {
    name = "keeper_board_post";
    description = "Create a new board post with content. Use hearth to target a topic channel \
(e.g. 'code-review', 'research', 'ops'). Use for sharing findings, asking questions, \
or starting discussions that other keepers should see.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("content", `Assoc [("type", `String "string"); ("description", `String "Post content (max 4000 chars)")]);
        ("hearth", `Assoc [("type", `String "string"); ("description", `String "Topic channel name (e.g. code-review, research, ops)")]);
        ("thread_id", `Assoc [("type", `String "string"); ("description", `String "Linked conversation thread ID (optional)")]);
        ("classification_reason", `Assoc [("type", `String "string"); ("description", `String "Optional explicit rationale for why this should appear as automation/direct in board views")]);
        ("judgment", `Assoc [("type", `String "object"); ("description", `String "Optional structured LLM judgment metadata. Use summary or reason to preserve why you posted/classified it this way")]);
      ]);
      ("required", `List [`String "content"]);
    ];
  };
  {
    name = "keeper_board_list";
    description = "List recent posts on the MASC Board. Filter by hearth (topic channel) to see \
specific topics. Returns post_id, author, hearth, timestamp, vote_count, comment_count, \
and content preview for each post.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("hearth", `Assoc [("type", `String "string"); ("description", `String "Filter by topic channel (e.g. code-review, research)")]);
        ("limit", `Assoc [("type", `String "integer"); ("description", `String "Max posts to return (default: 20, max: 50)")]);
        ("sort_by", `Assoc [("type", `String "string"); ("enum", `List [`String "recent"; `String "hot"; `String "updated"]); ("description", `String "Sort order (default: recent)")]);
      ]);
    ];
  };
  {
    name = "keeper_board_comment";
    description = "Add a comment to a board post by post_id. Use to respond to questions, \
provide feedback, or continue a discussion thread.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID (format: p-xxxx...). Get from keeper_board_list results.")]);
        ("content", `Assoc [("type", `String "string"); ("description", `String "Comment content")]);
      ]);
      ("required", `List [`String "post_id"; `String "content"]);
    ];
  };
  {
    name = "keeper_board_vote";
    description = "Vote on a board post (up or down). Use to signal agreement/support \
or disagreement with a proposal or finding.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID (format: p-xxxx...). Get from keeper_board_list results.")]);
        ("direction", `Assoc [("type", `String "string"); ("enum", `List [`String "up"; `String "down"]); ("description", `String "Vote direction (default: up)")]);
      ]);
      ("required", `List [`String "post_id"]);
    ];
  };
  {
    name = "keeper_board_stats";
    description = "Get board activity statistics: total posts, comments, votes, \
active hearths. Use to understand overall board health and engagement levels.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "keeper_board_search";
    description = "Search board posts by keyword across titles and content. \
Use when looking for specific topics, past discussions, or related prior work.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [("type", `String "string"); ("description", `String "Search keyword")]);
        ("limit", `Assoc [("type", `String "integer"); ("description", `String "Max results (default: 20)")]);
      ]);
      ("required", `List [`String "query"]);
    ];
  };
  {
    name = "keeper_board_delete";
    description = "Delete a board post by post_id. Use only for generated garbage, \
expired automation, or other explicitly-approved cleanup cases.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID to delete")]);
      ]);
      ("required", `List [`String "post_id"]);
    ];
  };
  {
    name = "keeper_board_cleanup";
    description = "Batch scan and cleanup board posts matching filter criteria. \
Defaults to dry_run=true (report candidates only). \
Set dry_run=false to delete matched posts. \
Safe defaults: only targets posts older than 24h with no comments and no votes.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("max_age_hours", `Assoc [
          ("type", `String "integer");
          ("description", `String "Only target posts older than this many hours (default: 24)");
        ]);
        ("title_pattern", `Assoc [
          ("type", `String "string");
          ("description", `String "Substring filter on post title (case-insensitive)");
        ]);
        ("author_pattern", `Assoc [
          ("type", `String "string");
          ("description", `String "Substring filter on post author (case-insensitive)");
        ]);
        ("dry_run", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true (default), report candidates without deleting");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max posts to process (default: 10, max: 50)");
        ]);
      ]);
      ("required", `List []);
    ];
  };
]

let select_named_schemas (names : string list) (schemas : Types.tool_schema list) :
    Types.tool_schema list =
  names
  |> List.filter_map (fun name ->
         List.find_opt
           (fun (schema : Types.tool_schema) -> String.equal schema.name name)
           schemas)

let filesystem_tools : Types.tool_schema list = [
  {
    name = "keeper_fs_read";
    description = "Read a file as text (truncated at max_bytes). \
path is REQUIRED. \
Paths resolve relative to your playground — use 'repos/X/lib/foo.ml' not '.masc/playground/your-name/repos/X/lib/foo.ml'. \
Good: path='lib/foo.ml', path='repos/masc-mcp/lib/room.ml'. Bad: path=''. \
For multi-file search, use keeper_shell with op=rg.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [("type", `String "string"); ("description", `String "Relative or absolute file path")]);
        ("max_bytes", `Assoc [("type", `String "integer"); ("description", `String ("Max bytes to return (default: " ^ Tool_shard_limits.keeper_fs_read_default_max_bytes_string ^ ")"))]);
      ]);
      ("required", `List [`String "path"]);
    ];
  };
  {
    name = "keeper_fs_edit";
    description = "Write or append to a file. \
path and content REQUIRED (both non-empty). \
mode: 'overwrite' (default) or 'append'. \
Good: path='lib/foo.ml', content='let x = 1'. \
Bad: path='', content=''. Bad: mode='create' (use overwrite). \
Creates parent dirs.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [("type", `String "string"); ("description", `String "Relative or absolute file path to write")]);
        ("content", `Assoc [("type", `String "string"); ("description", `String "File content to write")]);
        ("mode", `Assoc [("type", `String "string"); ("enum", `List [`String "overwrite"; `String "append"]); ("description", `String "Write mode (default: overwrite)")]);
      ]);
      ("required", `List [`String "path"; `String "content"]);
    ];
  };
]

let shell_tools : Types.tool_schema list = [
  {
    name = "keeper_shell";
    description = "Run a safe project shell command. \
ops: pwd, ls, cat, rg, git_status, find, head, tail, wc, tree, git_log, git_diff, bash, git_clone, gh. \
Read-only ops default to the keeper playground. \
IMPORTANT: paths resolve automatically — use 'repos/X' not '.masc/playground/your-name/repos/X'. Never include the playground prefix in path or cwd. \
Use cwd to target an explicit allowed directory or cloned repo. \
find REQUIRES pattern param (e.g. pattern=\"*.ml\"). \
bash op: single command only, no chaining (&&, ||, |, ; are blocked), no redirects (>, >>). \
git_clone: clone a repo into your playground (url required, sandboxed to .masc/playground/<name>/). \
gh op: run a gh CLI subcommand with cmd=\"<subcommand>\" (e.g. cmd=\"pr list --state open\"). Always run `gh pr list` first before referencing a PR number to avoid hallucinations. Dangerous commands (repo delete, auth logout, secret set/delete) are blocked. \
If path not found, clone the repo first with op=git_clone. \
Use rg for pattern search, find for path discovery, head/tail for line ranges, \
git_log/git_diff for repo history, bash for curl/jq/env/which, gh for GitHub PR/issue/CI.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("op", `Assoc [("type", `String "string"); ("enum", `List [`String "pwd"; `String "ls"; `String "cat"; `String "rg"; `String "git_status"; `String "find"; `String "head"; `String "tail"; `String "wc"; `String "tree"; `String "git_log"; `String "git_diff"; `String "bash"; `String "git_clone"; `String "gh"]); ("description", `String "Command to run")]);
        ("cmd", `Assoc [("type", `String "string"); ("description", `String "gh subcommand for op=gh, e.g. 'pr list --state open'. Do NOT put --repo in cmd; current working dir determines the repo.")]);
        ("path", `Assoc [("type", `String "string"); ("description", `String "Target path for ls/cat/rg/find/head/tail/wc/tree")]);
        ("cwd", `Assoc [("type", `String "string"); ("description", `String "Optional working directory for pwd/git_status/git_log/git_diff/git_worktree/bash. Must stay within keeper playground or an explicit allowed path.")]);
        ("pattern", `Assoc [("type", `String "string"); ("description", `String "Search pattern for rg, or name glob for find (REQUIRED for find, e.g. \"*.ml\")")]);
        ("limit", `Assoc [("type", `String "integer"); ("description", `String "Result limit for ls/rg/find/tree, or line count for git_log")]);
        ("lines", `Assoc [("type", `String "integer"); ("description", `String "Number of lines for head/tail (default 20, max 200)")]);
        ("max_bytes", `Assoc [("type", `String "integer"); ("description", `String "Max bytes for cat")]);
        ("command", `Assoc [("type", `String "string"); ("description", `String "Single shell command for bash op. No chaining (&&/||/;/|) or redirects (>/>>) allowed. Read-only.")]);
        ("timeout_sec", `Assoc [("type", `String "number"); ("description", `String "Timeout seconds for bash op (default: 30, max: 180)")]);
        ("url", `Assoc [("type", `String "string"); ("description", `String "Git repo URL for git_clone op (e.g. 'https://github.com/org/repo'). Clones into .masc/playground/<your_name>/.")]);
      ]);
      ("required", `List [`String "op"]);
    ];
  };
]

let coding_keeper_bridge_tools : Types.tool_schema list = [
  {
    name = "keeper_bash";
    description = "Execute ONE shell command. \
NO chaining (&&, ||, ;), NO pipes (|), NO redirects (> >>). \
Violations are blocked. Good: cmd='dune build', cmd='ls -la lib/'. \
Bad: cmd='cd x && dune build', cmd='rg foo | wc -l'. \
Runs in the keeper playground by default; use cwd to target an explicit allowed directory. \
Paths resolve automatically — never include '.masc/playground/your-name/' in cwd. Use 'repos/X' instead. \
For read-only ops use keeper_shell, for file edits use keeper_fs_edit.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("cmd", `Assoc [("type", `String "string"); ("description", `String "Single command only. No chaining/pipe/redirect. Example: 'dune build', 'rg pattern lib/'")]);
        ("cwd", `Assoc [("type", `String "string"); ("description", `String "Optional working directory for the command. Must stay within keeper playground or an explicit allowed path.")]);
        ("timeout_sec", `Assoc [("type", `String "number"); ("description", `String "Timeout seconds (default: 30, max: 180)")]);
      ]);
      ("required", `List [`String "cmd"]);
    ];
  };
]

(** Pre-flight validation for keeper autonomous work. *)
let keeper_preflight_tools : Types.tool_schema list = [
  {
    name = "keeper_preflight_check";
    description = "Validate prerequisites before starting autonomous work: \
gh auth, repo access, keeper identity, preset level, clone target path. \
Returns structured JSON with all check results. Read-only, no side effects.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("repo", `Assoc [("type", `String "string"); ("description", `String "GitHub repo (owner/name) to check access for")]);
      ]);
      ("required", `List [`String "repo"]);
    ];
  };
]

(** PR review tools — read diffs, leave comments, approve/request changes. *)
let keeper_pr_review_tools : Types.tool_schema list = [
  {
    name = "keeper_pr_review_read";
    description = "Read PR metadata, diff, reviews, and comments. \
Returns title, body, changed files, review threads, and truncated diff (max 64KB). Read-only.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("repo", `Assoc [("type", `String "string"); ("description", `String "GitHub repo (owner/name)")]);
        ("number", `Assoc [("type", `String "integer"); ("description", `String "PR number")]);
      ]);
      ("required", `List [`String "repo"; `String "number"]);
    ];
  };
  {
    name = "keeper_pr_review_comment";
    description = "Submit a PR review with optional inline comments. \
Events: COMMENT, APPROVE, REQUEST_CHANGES. Requires delivery or coding preset.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("repo", `Assoc [("type", `String "string"); ("description", `String "GitHub repo (owner/name)")]);
        ("number", `Assoc [("type", `String "integer"); ("description", `String "PR number")]);
        ("body", `Assoc [("type", `String "string"); ("description", `String "Review body text")]);
        ("event", `Assoc [("type", `String "string"); ("enum", `List [`String "COMMENT"; `String "APPROVE"; `String "REQUEST_CHANGES"]); ("description", `String "Review event type")]);
        ("path", `Assoc [("type", `String "string"); ("description", `String "File path for inline comment (optional)")]);
        ("line", `Assoc [("type", `String "integer"); ("description", `String "Line number for inline comment (optional)")]);
      ]);
      ("required", `List [`String "repo"; `String "number"; `String "body"; `String "event"]);
    ];
  };
  {
    name = "keeper_pr_review_reply";
    description = "Reply to a specific PR review comment. Requires delivery or coding preset.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("repo", `Assoc [("type", `String "string"); ("description", `String "GitHub repo (owner/name)")]);
        ("number", `Assoc [("type", `String "integer"); ("description", `String "PR number")]);
        ("comment_id", `Assoc [("type", `String "integer"); ("description", `String "Comment ID to reply to")]);
        ("body", `Assoc [("type", `String "string"); ("description", `String "Reply body text")]);
      ]);
      ("required", `List [`String "repo"; `String "number"; `String "comment_id"; `String "body"]);
    ];
  };
]

let coding_workspace_tool_names : string list =
  [ "masc_worktree_create"; "masc_worktree_list"; "masc_code_search";
    "masc_code_symbols"; "masc_code_read" ]

let coding_workspace_tools : Types.tool_schema list =
  select_named_schemas coding_workspace_tool_names
    (Tool_schemas_worktree.schemas @ Tool_code.schemas)

(** Coding tools — shell/github bridges plus worktree-first code workflow.
    Always granted. *)
let coding_tools : Types.tool_schema list =
  coding_keeper_bridge_tools @ coding_workspace_tools

let voice_tools : Types.tool_schema list = [
  {
    name = "keeper_voice_speak";
    description = "Speak a short utterance via the voice bridge. Blocks until playback finishes and returns played_seconds. Do NOT call again until you receive the result — concurrent calls are serialized by a global lock. Duplicate identical messages within 30s are silently skipped.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("message", `Assoc [("type", `String "string"); ("description", `String "Text to speak")]);
        ("provider", `Assoc [("type", `String "string"); ("description", `String "Optional voice provider override")]);
        ("priority", `Assoc [("type", `String "integer"); ("description", `String "Optional queue priority")]);
      ]);
      ("required", `List [`String "message"]);
    ];
  };
  {
    name = "keeper_voice_listen";
    description = "Record user speech via microphone and transcribe to text. Starts recording, waits for speech, stops on silence (2s), then returns transcribed text.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("timeout_seconds", `Assoc [("type", `String "number"); ("description", `String "Max recording duration in seconds (default 15)")]);
        ("language_code", `Assoc [("type", `String "string"); ("description", `String "ISO language hint, e.g. ko, en")]);
      ]);
    ];
  };
  {
    name = "keeper_voice_agent";
    description = "Get your own voice configuration (assigned voice, available voices). No network required.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "keeper_voice_sessions";
    description = "List active voice sessions from the voice bridge.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "keeper_voice_session_start";
    description = "Start a voice session for this keeper using the configured voice bridge.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("session_name", `Assoc [("type", `String "string"); ("description", `String "Optional session name")]);
      ]);
    ];
  };
  {
    name = "keeper_voice_session_end";
    description = "End the active voice session for this keeper and release bridge resources.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
]

let library_tools : Types.tool_schema list = [
  {
    name = "keeper_library_search";
    description = "Search the knowledge library by keyword. Returns matching document titles, \
relevance scores (0-1), and text snippets. Use to discover relevant docs \
before reading full content with keeper_library_read.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [("type", `String "string"); ("description", `String "Search query string")]);
      ]);
      ("required", `List [`String "query"]);
    ];
  };
  {
    name = "keeper_library_read";
    description = "Read a full document from the knowledge library by exact topic name. \
Use after keeper_library_search identifies a relevant document, or with \
a known topic name. Returns full document text.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [("type", `String "string"); ("description", `String "Exact document topic name (from search results or known)")]);
      ]);
      ("required", `List [`String "topic"]);
    ];
  };
]

let taskboard_tools : Types.tool_schema list = [
  {
    name = "keeper_tasks_list";
    description = "List tasks on the MASC backlog. Returns task_id, title, status, assignee, \
and priority for each task. Use to see what work is available or in progress.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("status", `Assoc [("type", `String "string"); ("enum", `List [`String "todo"; `String "claimed"; `String "in_progress"; `String "done"; `String "cancelled"]); ("description", `String "Filter by task status")]);
        ("include_done", `Assoc [("type", `String "boolean"); ("description", `String "Include completed tasks (default: false)")]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max tasks to return (default: 50)");
          ("minimum", `Int 1);
          ("maximum", `Int 100);
          ("default", `Int 50);
        ]);
      ]);
    ];
  };
  {
    name = "keeper_tasks_audit";
    description = "Find orphaned tasks: claimed/in_progress tasks assigned to agents that are \
offline (no heartbeat >10 min). Returns orphan list with assignee and last_seen. \
Use keeper_task_force_release to reassign orphaned tasks.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max orphans to return (default: 20)");
          ("minimum", `Int 1);
          ("maximum", `Int 50);
          ("default", `Int 20);
        ]);
      ]);
    ];
  };
  {
    name = "keeper_task_force_release";
    description = "Release a stuck task back to Todo status, removing the current assignee. \
Applies when the assignee is offline (no heartbeat >10 min). Broadcasts the release to the room.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [("type", `String "string"); ("description", `String "Task ID from keeper_tasks_list or keeper_tasks_audit"); ("minLength", `Int 1)]);
        ("reason", `Assoc [("type", `String "string"); ("description", `String "Why this task is being released (audit trail)"); ("minLength", `Int 1)]);
      ]);
      ("required", `List [`String "task_id"; `String "reason"]);
    ];
  };
  {
    name = "keeper_task_force_done";
    description = "Mark a task Done when the assignee completed the work but did not transition it \
(e.g. went offline after finishing). Broadcasts completion to room.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [("type", `String "string"); ("description", `String "Task ID from keeper_tasks_list or keeper_tasks_audit"); ("minLength", `Int 1)]);
        ("notes", `Assoc [("type", `String "string"); ("description", `String "Completion evidence: PR merged, test output, file diff"); ("minLength", `Int 1)]);
      ]);
      ("required", `List [`String "task_id"; `String "notes"]);
    ];
  };
  {
    name = "keeper_broadcast";
    description = "Send a message visible to all agents in the MASC room. \
Use for status updates, announcements, warnings, or coordination.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("message", `Assoc [("type", `String "string"); ("description", `String "Message content to broadcast"); ("minLength", `Int 1)]);
      ]);
      ("required", `List [`String "message"]);
    ];
  };
  {
    name = "keeper_task_claim";
    description = "Claim the next unclaimed todo task that matches your capabilities. \
Returns claimed task details (task_id, title, description) or empty if none available. \
After claiming, do the work and call keeper_task_done when finished.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "keeper_task_done";
    description = "Mark your claimed task as complete with a result summary. \
The task must be claimed by you. Other agents verify completion from the result field.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [("type", `String "string"); ("description", `String "Task ID returned by keeper_task_claim"); ("minLength", `Int 1)]);
        ("result", `Assoc [("type", `String "string"); ("description", `String "What was done: files changed, tests run, outcome observed"); ("minLength", `Int 1)]);
      ]);
      ("required", `List [`String "task_id"; `String "result"]);
    ];
  };
  {
    name = "keeper_task_create";
    description = "Create a new task on the MASC backlog. The task appears for any keeper to claim. \
Duplicate titles are rejected automatically (dedup by normalized title).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("title", `Assoc [("type", `String "string"); ("description", `String "Task title: verb + object + scope (e.g. 'Fix CI timeout in keeper_agent_run.ml')"); ("minLength", `Int 5); ("maxLength", `Int 200)]);
        ("description", `Assoc [("type", `String "string"); ("description", `String "What to do, why, and acceptance criteria. Another keeper reads this to start working."); ("minLength", `Int 10)]);
        ("priority", `Assoc [
          ("type", `String "integer");
          ("description", `String "1=critical 2=high 3=medium 4=low 5=backlog");
          ("minimum", `Int 1);
          ("maximum", `Int 5);
          ("default", `Int 3);
        ]);
      ]);
      ("required", `List [`String "title"; `String "description"]);
    ];
  };
]

(** Predefined shards *)

let shard_base : shard = {
  name = "base";
  tools = base_tools;
  read_only_tools = [
    "keeper_stay_silent"; "keeper_time_now"; "keeper_context_status";
    "keeper_memory_search"; "keeper_tools_list";
  ];
  removable = false;
  description = "Core tools: time, context, memory";
}

let shard_board : shard = {
  name = "board";
  tools = board_tools;
  read_only_tools = [
    "keeper_board_get"; "keeper_board_list";
    "keeper_board_stats"; "keeper_board_search";
  ];
  removable = true;
  description = "MASC Board: post, list, comment";
}

let shard_filesystem : shard = {
  name = "filesystem";
  tools = filesystem_tools;
  read_only_tools = ["keeper_fs_read"];
  removable = true;
  description = "File I/O: read and write";
}

let shard_shell : shard = {
  name = "shell";
  tools = shell_tools;
  read_only_tools = ["keeper_shell"];
  removable = true;
  description = "Shell ops: pwd, ls, cat, rg, git_status, git_clone";
}

let shard_coding : shard = {
  name = "coding";
  tools = coding_tools;
  read_only_tools = [];
  removable = true;
  description =
    "Coding tools: github/shell bridge + worktree/code inspection";
}

let shard_voice : shard = {
  name = "voice";
  tools = voice_tools;
  read_only_tools = ["keeper_voice_sessions"];
  removable = true;
  description = "Voice bridge speak output";
}

let shard_library : shard = {
  name = "library";
  tools = library_tools;
  read_only_tools = ["keeper_library_search"; "keeper_library_read"];
  removable = true;
  description = "Knowledge library: search, read documents";
}

let shard_taskboard : shard = {
  name = "taskboard";
  tools = taskboard_tools;
  read_only_tools = ["keeper_tasks_list"; "keeper_tasks_audit"];
  removable = true;
  description = "Task board management: list, audit, force-release, force-done, broadcast";
}

(** Autoresearch tools available to keepers. *)
let autoresearch_keeper_tools : Types.tool_schema list =
  Tool_autoresearch_schemas.schemas

let shard_autoresearch : shard = {
  name = "autoresearch";
  tools = autoresearch_keeper_tools;
  read_only_tools = [];
  removable = true;
  description = "Autonomous experiment loop: start, cycle, status, inject, stop";
}

(** Per-agent shard overrides.  Read-modify-write is serialised by
    [agent_shards_mutex] so concurrent keeper setup calls cannot lose updates.

    Stdlib.Mutex (not Eio.Mutex) because these helpers are also called from
    non-Eio contexts — unit tests and some startup wiring — where Eio.Mutex
    raises Effect.Unhandled(Cancel.Get_context). Critical sections are short
    StringMap ops, so Stdlib blocking is acceptable.
    See memory/feedback_ocaml5-mutex-selection.md. *)
let agent_shards : string list StringMap.t ref = ref StringMap.empty
let agent_shards_mutex = Stdlib.Mutex.create ()

(** Default shards for a new keeper.
    All keepers get all shards unconditionally. Safety is handled by
    eval_gate deny lists, not by shard membership. *)
let default_shard_names : string list = [
  "base";
  "board";
  "filesystem";
  "shell";
  "library";
  "taskboard";
  "coding";
  "autoresearch";
]

let get_agent_shards (agent_name : string) : string list =
  Stdlib.Mutex.protect agent_shards_mutex (fun () ->
    StringMap.find_opt agent_name !agent_shards
    |> Option.value ~default:default_shard_names)

let set_agent_shards (agent_name : string) (shards : string list) : unit =
  Stdlib.Mutex.protect agent_shards_mutex (fun () ->
    agent_shards :=
      StringMap.add agent_name
        (List.sort_uniq String.compare shards) !agent_shards)

let remove_agent_shards (agent_name : string) : unit =
  Stdlib.Mutex.protect agent_shards_mutex (fun () ->
    agent_shards := StringMap.remove agent_name !agent_shards)

(** All predefined shards by name *)
let all_shards : shard StringMap.t =
  List.fold_left (fun map s -> StringMap.add s.name s map) StringMap.empty [
    shard_base;
    shard_board;
    shard_filesystem;
    shard_shell;
    shard_coding;
    shard_voice;
    shard_library;
    shard_taskboard;
    shard_autoresearch;
  ]

let all_read_only_keeper_tools () : string list =
  StringMap.fold (fun _name shard acc ->
    shard.read_only_tools @ acc
  ) all_shards []
  |> List.sort_uniq String.compare

let recovery_minimum_shard_names () : string list =
  StringMap.fold (fun name shard acc ->
    if not shard.removable then name :: acc else acc
  ) all_shards []
  |> List.rev

(** Get a shard by name *)
let get_shard (name : string) : shard option =
  StringMap.find_opt name all_shards

(** Combine tools from multiple shard names *)
let tools_of_shards (shard_names : string list) : Types.tool_schema list =
  shard_names
  |> List.filter_map (fun name -> StringMap.find_opt name all_shards)
  |> List.concat_map (fun (s : shard) -> s.tools)

(** {1 Dynamic Shard Management} *)

(** Grant a shard to an agent. Returns new active_shards list.
    Fails if shard doesn't exist or is already granted. *)
let grant_shard (active_shards : string list) (shard_name : string) :
  (string list, string) result =
  match StringMap.find_opt shard_name all_shards with
  | None -> Error (Printf.sprintf "Unknown shard: %s" shard_name)
  | Some _ ->
    if List.mem shard_name active_shards then
      Error (Printf.sprintf "Shard already granted: %s" shard_name)
    else
      Ok (active_shards @ [shard_name])

(** Revoke a shard from an agent. Returns new active_shards list.
    Fails if shard is not removable or not currently granted. *)
let revoke_shard (active_shards : string list) (shard_name : string) :
  (string list, string) result =
  match StringMap.find_opt shard_name all_shards with
  | None -> Error (Printf.sprintf "Unknown shard: %s" shard_name)
  | Some shard ->
    if not shard.removable then
      Error (Printf.sprintf "Cannot revoke non-removable shard: %s" shard_name)
    else if not (List.mem shard_name active_shards) then
      Error (Printf.sprintf "Shard not currently granted: %s" shard_name)
    else
      Ok (List.filter (fun n -> n <> shard_name) active_shards)

(** List all available shards with their status *)
let list_all_shards () : (string * bool * int) list =
  StringMap.fold (fun name (shard : shard) acc ->
    (name, shard.removable, List.length shard.tools) :: acc
  ) all_shards []
  |> List.rev

(** Default keeper tool set from [default_shard_names]. *)
let keeper_model_tools : Types.tool_schema list =
  tools_of_shards default_shard_names

(** {1 MCP Schemas} *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_tool_grant";
    description = "Grant a capability group to an agent. \
Groups: base (core), board, filesystem, shell, voice, taskboard, coding, autoresearch.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to grant shard to");
        ]);
        ("shard_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Group to grant: base, board, filesystem, shell, voice, taskboard, coding, autoresearch");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "shard_name"]);
    ];
  };
  {
    name = "masc_tool_revoke";
    description = "Revoke a capability group from an agent. \
Cannot revoke 'base' (always present).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to revoke shard from");
        ]);
        ("shard_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Group to revoke (must be removable). One of: board, filesystem, shell, voice, taskboard, coding, autoresearch");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "shard_name"]);
    ];
  };
  {
    name = "masc_tool_list";
    description = "List all available capability groups with their tool counts.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
]

(** {1 MCP Execute} *)

let active_shards_of_agent agent_name_opt =
  match agent_name_opt with
  | Some name -> get_agent_shards name
  | None -> default_shard_names

(** Execute tool_shard MCP tools. *)
let execute (tool_name : string) (arguments : Yojson.Safe.t) : (bool * Yojson.Safe.t) =
  let module U = Yojson.Safe.Util in
  let read_required_string key =
    match U.member key arguments with
    | `String v when String.trim v <> "" -> Some v
    | _ -> None
  in
  match tool_name with
  | "masc_tool_list" ->
    let agent_name = read_required_string "agent_name" in
    let all = list_all_shards () in
    let active_shards = active_shards_of_agent agent_name in
    let shard_list = List.map (fun (name, removable, tool_count) ->
      `Assoc [
        ("name", `String name);
        ("removable", `Bool removable);
        ("tool_count", `Int tool_count);
      ]
    ) all in
    let active_shards =
      List.filter_map (fun (name, _, _) ->
        Option.map (fun () -> `String name) (if List.mem name active_shards then Some () else None)
      ) all
    in
    (true, `Assoc [
      ("shards", `List shard_list);
      ("agent_name", `String (Option.value ~default:"" agent_name));
      ("active_shards", `List active_shards);
    ])

  | "masc_tool_grant" | "masc_tool_revoke" ->
    let op_fn, status_label =
      if tool_name = "masc_tool_grant" then (grant_shard, "granted")
      else (revoke_shard, "revoked")
    in
    let agent_name = read_required_string "agent_name" in
    let shard_name = read_required_string "shard_name" in
    (match agent_name, shard_name with
    | Some agent_name, Some shard_name ->
        (match op_fn (get_agent_shards agent_name) shard_name with
        | Ok next_shards ->
            set_agent_shards agent_name next_shards;
            (true, `Assoc [
              ("status", `String status_label);
              ("agent_name", `String agent_name);
              ("shard", `String shard_name);
              ("active_shards", `List (List.map (fun s -> `String s) next_shards));
            ])
        | Error msg ->
            (false, `Assoc [("status", `String "error"); ("message", `String msg)]))
    | _ ->
        (false, `Assoc [("status", `String "error"); ("message", `String "agent_name and shard_name are required")]))

  | _ -> (false, `String "Unknown tool")

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let _tool_spec_read_only = [ "masc_tool_list" ]
let _tool_spec_destructive = [ "masc_tool_grant"; "masc_tool_revoke" ]

let tool_required_permission = function
  | "masc_tool_list" -> Some Types.CanReadState
  | "masc_tool_grant" | "masc_tool_revoke" -> Some Types.CanAdmin
  | _ -> None

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_shard
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:(List.mem s.name _tool_spec_read_only)
           ~is_idempotent:(List.mem s.name _tool_spec_read_only)
           ~is_destructive:(List.mem s.name _tool_spec_destructive)
           ?required_permission:(tool_required_permission s.name)
           ()))
    schemas
