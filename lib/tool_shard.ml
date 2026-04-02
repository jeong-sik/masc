(** Tool_shard — Dynamic tool sharding for MASC agents.

    Allows tools to be granted/revoked at runtime like equipment slots.
    Each agent can have multiple active shards that contribute tools.

    @since 2.62.0 *)

(** A named collection of tools that can be granted/revoked. *)
type shard = {
  name : string;
  tools : Types.tool_schema list;
  removable : bool;  (** true = can be revoked at runtime *)
  description : string;
}

(** Predefined shards *)

let base_tools : Types.tool_schema list = [
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
    description = "Check your own context window usage and session state. Returns context_ratio (0.0-1.0), \
token_count, message_count, generation, continuity_summary. Use when deciding whether to \
compact context, extend turns, or hand off to the next generation.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  (* Memory *)
  {
    name = "keeper_memory_search";
    description = "Search recent user messages in your conversation history by keyword. \
Returns matching message snippets. Use to recall earlier instructions or context \
from this session without re-reading full history.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [("type", `String "string")]);
        ("limit", `Assoc [("type", `String "integer")]);
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
timestamp, vote_count, and comment thread.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID to inspect")]);
      ]);
      ("required", `List [`String "post_id"]);
    ];
  };
  {
    name = "keeper_board_post";
    description = "Create a new post on the MASC Board. Use hearth to target a topic channel \
(e.g. 'code-review', 'research', 'ops'). Use for sharing findings, asking questions, \
or starting discussions that other keepers should see.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("content", `Assoc [("type", `String "string"); ("description", `String "Post content (max 4000 chars)")]);
        ("hearth", `Assoc [("type", `String "string"); ("description", `String "Topic channel name (e.g. code-review, research, ops)")]);
        ("thread_id", `Assoc [("type", `String "string"); ("description", `String "Linked conversation thread ID (optional)")]);
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
        ("sort_by", `Assoc [("type", `String "string"); ("description", `String "Sort: recent (newest), hot (score+recency), updated (most active)")]);
      ]);
    ];
  };
  {
    name = "keeper_board_comment";
    description = "Add a comment to an existing board post. Use to respond to questions, \
provide feedback, or continue a discussion thread.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID to comment on")]);
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
        ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID to vote on")]);
        ("direction", `Assoc [("type", `String "string"); ("description", `String "up or down (default: up)")]);
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
    description = "Read a file from the project. Returns file content as text (truncated at max_bytes). \
Use to inspect source code, configs, logs, or any file before making decisions. \
For searching across files, use keeper_shell_readonly with op=rg instead.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [("type", `String "string"); ("description", `String "Relative or absolute file path")]);
        ("max_bytes", `Assoc [("type", `String "integer"); ("description", `String "Max bytes to return (default: 20000)")]);
      ]);
      ("required", `List [`String "path"]);
    ];
  };
  {
    name = "keeper_fs_edit";
    description = "Write or append to a file in the project. Use to create new files or update \
existing ones. For small targeted edits prefer this over keeper_bash with echo/cat. \
Mode 'overwrite' replaces the entire file; 'append' adds to the end.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [("type", `String "string"); ("description", `String "Relative or absolute file path to write")]);
        ("content", `Assoc [("type", `String "string"); ("description", `String "File content to write")]);
        ("mode", `Assoc [("type", `String "string"); ("description", `String "Write mode: 'overwrite' (default) or 'append'")]);
      ]);
      ("required", `List [`String "path"; `String "content"]);
    ];
  };
]

let shell_tools : Types.tool_schema list = [
  {
    name = "keeper_shell_readonly";
    description = "Run a read-only project command. Safe, no side effects. \
ops: pwd (working dir), ls (directory listing), cat (file content), \
rg (ripgrep search across files), git_status (repo state). \
To read a single file, prefer keeper_fs_read (handles truncation). \
Use this tool for multi-file search (rg), directory listing (ls), or repo state (git_status).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("op", `Assoc [("type", `String "string"); ("description", `String "One of: pwd, ls, cat, rg, git_status")]);
        ("path", `Assoc [("type", `String "string"); ("description", `String "Target path for ls/cat/rg")]);
        ("pattern", `Assoc [("type", `String "string"); ("description", `String "Search pattern for rg")]);
        ("limit", `Assoc [("type", `String "integer"); ("description", `String "Result limit for ls/rg")]);
        ("max_bytes", `Assoc [("type", `String "integer"); ("description", `String "Max bytes for cat")]);
      ]);
      ("required", `List [`String "op"]);
    ];
  };
]

let coding_keeper_bridge_tools : Types.tool_schema list = [
  {
    name = "keeper_bash";
    description = "Run a shell command from project root with full shell access. \
Use for builds (dune build, make), tests (dune test), git operations, \
and any command that may modify files. Returns exit_code and output. \
For read-only exploration, prefer keeper_shell_readonly (safer). \
To write a file, prefer keeper_fs_edit (path-checked, audited). \
For worktree-isolated code operations, prefer masc_code_shell (restricted path).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("cmd", `Assoc [("type", `String "string"); ("description", `String "Shell command string to run via zsh -lc")]);
        ("timeout_sec", `Assoc [("type", `String "number"); ("description", `String "Timeout seconds (default: 30, max: 180)")]);
      ]);
      ("required", `List [`String "cmd"]);
    ];
  };
  {
    name = "keeper_github";
    description = "Run gh CLI commands for GitHub operations. Use for creating issues, \
opening PRs, posting review comments, checking CI status. \
Returns gh command output. Example: cmd='pr list --state open'.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("cmd", `Assoc [("type", `String "string"); ("description", `String "gh subcommand string, e.g. 'issue create --title ...'")]);
        ("args", `Assoc [("type", `String "array"); ("items", `Assoc [("type", `String "string")]); ("description", `String "Optional argv list for gh (without leading gh)")]);
        ("timeout_sec", `Assoc [("type", `String "number"); ("description", `String "Timeout seconds (default: 30, max: 180)")]);
      ]);
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
    description = "Speak a short utterance as this keeper via the voice bridge, falling back to text when voice is unavailable.";
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
        ("status", `Assoc [("type", `String "string"); ("description", `String "Filter by status (optional). One of: todo, claimed, in_progress, done, cancelled")]);
        ("include_done", `Assoc [("type", `String "boolean"); ("description", `String "Include completed tasks (default: false)")]);
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
      ("properties", `Assoc []);
    ];
  };
  {
    name = "keeper_task_force_release";
    description = "Release a stuck task back to Todo status, removing the current assignee. \
Use when an agent went offline and left a task claimed. Broadcasts the \
release to the room. Provide a reason for audit.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [("type", `String "string"); ("description", `String "Task ID to force-release")]);
        ("reason", `Assoc [("type", `String "string"); ("description", `String "Reason for force release")]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };
  {
    name = "keeper_task_force_done";
    description = "Mark a task Done when the work is confirmed complete but the assignee \
did not transition it (e.g. they finished but went offline). Requires notes \
explaining the completion evidence. Broadcasts to room.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [("type", `String "string"); ("description", `String "Task ID to force-complete")]);
        ("notes", `Assoc [("type", `String "string"); ("description", `String "Evidence that the task is actually complete")]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };
  {
    name = "keeper_broadcast";
    description = "Send a message visible to all agents in the MASC room. Use for status \
updates, announcements, warnings, or coordination. All keepers will see this.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("message", `Assoc [("type", `String "string"); ("description", `String "Message to broadcast")]);
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
The task must be claimed by you. Provide a clear summary of what was \
accomplished so other agents can verify.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [("type", `String "string"); ("description", `String "Task ID to complete")]);
        ("result", `Assoc [("type", `String "string"); ("description", `String "Summary of what was accomplished")]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };
]

(** Predefined shards *)

let shard_base : shard = {
  name = "base";
  tools = base_tools;
  removable = false;  (* Always present *)
  description = "Core tools: time, context, memory";
}

let shard_board : shard = {
  name = "board";
  tools = board_tools;
  removable = true;
  description = "MASC Board: post, list, comment";
}

let shard_filesystem : shard = {
  name = "filesystem";
  tools = filesystem_tools;
  removable = true;
  description = "File I/O: read and write";
}

let shard_shell : shard = {
  name = "shell";
  tools = shell_tools;
  removable = true;
  description = "Read-only shell: pwd, ls, cat, rg, git_status";
}

let shard_coding : shard = {
  name = "coding";
  tools = coding_tools;
  removable = true;
  description =
    "Coding tools: github/shell bridge + worktree/code inspection";
}

let shard_voice : shard = {
  name = "voice";
  tools = voice_tools;
  removable = true;
  description = "Voice bridge speak output";
}

let shard_library : shard = {
  name = "library";
  tools = library_tools;
  removable = true;
  description = "Knowledge library: search, read documents";
}

let governance_keeper_tool_names : string list =
  [
    "masc_cases";
    "masc_case_status";
    "masc_ruling_status";
    "masc_governance_status";
    "masc_governance_feed";
    "masc_case_brief_submit";
    "masc_petition_submit";
  ]

let governance_tools : Types.tool_schema list =
  (* Council module removed — governance tool schemas no longer available *)
  ignore governance_keeper_tool_names;
  []

let shard_taskboard : shard = {
  name = "taskboard";
  tools = taskboard_tools;
  removable = true;
  description = "Task board management: list, audit, force-release, force-done, broadcast";
}

let shard_governance : shard = {
  name = "governance";
  tools = governance_tools;
  removable = true;
  description =
    "Governance compatibility stub: council removed, no governance tools exposed";
}

(** Autoresearch tools: filtered subset for keeper use (excludes swarm_start). *)
let autoresearch_keeper_tools : Types.tool_schema list =
  Tool_autoresearch_schemas.schemas
  |> List.filter (fun (t : Types.tool_schema) ->
       t.name <> "masc_autoresearch_swarm_start")

let shard_autoresearch : shard = {
  name = "autoresearch";
  tools = autoresearch_keeper_tools;
  removable = true;
  description = "Autonomous experiment loop: start, cycle, status, inject, stop";
}

let agent_shards : (string, string list) Hashtbl.t = Hashtbl.create 32

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
  "governance";
  "coding";
  "autoresearch";
]

let get_agent_shards (agent_name : string) : string list =
  Hashtbl.find_opt agent_shards agent_name
  |> Option.value ~default:default_shard_names

let set_agent_shards (agent_name : string) (shards : string list) : unit =
  Hashtbl.replace agent_shards agent_name (List.sort_uniq String.compare shards)

(** All predefined shards by name *)
let all_shards : (string, shard) Hashtbl.t =
  let tbl = Hashtbl.create 16 in
  List.iter (fun s -> Hashtbl.add tbl s.name s) [
    shard_base;
    shard_board;
    shard_filesystem;
    shard_shell;
    shard_coding;
    shard_voice;
    shard_library;
    shard_taskboard;
    shard_governance;
    shard_autoresearch;
  ];
  tbl

(** Get a shard by name *)
let get_shard (name : string) : shard option =
  Hashtbl.find_opt all_shards name

(** Combine tools from multiple shard names *)
let tools_of_shards (shard_names : string list) : Types.tool_schema list =
  shard_names
  |> List.filter_map (fun name -> Hashtbl.find_opt all_shards name)
  |> List.concat_map (fun (s : shard) -> s.tools)

(** {1 Dynamic Shard Management} *)

(** Grant a shard to an agent. Returns new active_shards list.
    Fails if shard doesn't exist or is already granted. *)
let grant_shard (active_shards : string list) (shard_name : string) :
  (string list, string) result =
  match Hashtbl.find_opt all_shards shard_name with
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
  match Hashtbl.find_opt all_shards shard_name with
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
  Hashtbl.fold (fun name (shard : shard) acc ->
    (name, shard.removable, List.length shard.tools) :: acc
  ) all_shards []

(** Default keeper tool set from [default_shard_names]. *)
let keeper_model_tools : Types.tool_schema list =
  tools_of_shards default_shard_names

(** {1 MCP Schemas} *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_tool_grant";
    description = "Grant a tool shard to an agent. \
Shards: base (core), board, filesystem, shell, governance, voice, taskboard, coding, autoresearch.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to grant shard to");
        ]);
        ("shard_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Shard to grant: base, board, filesystem, shell, governance, voice, taskboard, coding, autoresearch");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "shard_name"]);
    ];
  };
  {
    name = "masc_tool_revoke";
    description = "Revoke a tool shard from an agent. \
Cannot revoke 'base' shard (always present).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to revoke shard from");
        ]);
        ("shard_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Shard to revoke (must be removable). One of: board, filesystem, shell, governance, voice, taskboard, coding, autoresearch");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "shard_name"]);
    ];
  };
  {
    name = "masc_tool_list";
    description = "List all available tool shards with their capabilities.";
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
