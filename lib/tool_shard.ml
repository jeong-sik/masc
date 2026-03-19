(** Tool_shard — Dynamic tool sharding for MASC agents.

    Allows tools to be granted/revoked at runtime like equipment slots.
    Each agent can have multiple active shards that contribute tools.

    @since 2.62.0 *)

(** A named collection of tools that can be granted/revoked. *)
type shard = {
  name : string;
  tools : Cascade.tool_def list;
  removable : bool;  (** true = can be revoked at runtime *)
  description : string;
}

(** Predefined shards *)

let base_tools : Cascade.tool_def list = [
  (* Time *)
  {
    tool_name = "keeper_time_now";
    tool_description = "Get current server time in ISO8601 and unix timestamp.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  (* Context status *)
  {
    tool_name = "keeper_context_status";
    tool_description = "Get keeper context usage and lifecycle status.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  (* Memory *)
  {
    tool_name = "keeper_memory_search";
    tool_description = "Search recent user messages in keeper memory by keyword.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [("type", `String "string")]);
        ("limit", `Assoc [("type", `String "integer")]);
      ]);
      ("required", `List [`String "query"]);
    ];
  };
]

let board_tools : Cascade.tool_def list = [
  {
    tool_name = "keeper_board_get";
    tool_description = "Read a board post with its comments before deciding whether to comment, vote, or escalate.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID to inspect")]);
      ]);
      ("required", `List [`String "post_id"]);
    ];
  };
  {
    tool_name = "keeper_board_post";
    tool_description = "Create a post on the MASC Board. Use hearth to target a topic channel.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("content", `Assoc [("type", `String "string"); ("description", `String "Post content (max 4000 chars)")]);
        ("hearth", `Assoc [("type", `String "string"); ("description", `String "Topic hearth name (e.g. trpg, code-review)")]);
        ("thread_id", `Assoc [("type", `String "string"); ("description", `String "Linked conversation thread ID (optional)")]);
      ]);
      ("required", `List [`String "content"]);
    ];
  };
  {
    tool_name = "keeper_board_list";
    tool_description = "List recent posts on the MASC Board. Filter by hearth to see topic-specific posts.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("hearth", `Assoc [("type", `String "string"); ("description", `String "Filter by hearth topic (e.g. trpg)")]);
        ("limit", `Assoc [("type", `String "integer"); ("description", `String "Max posts to return (default: 20, max: 50)")]);
        ("sort_by", `Assoc [("type", `String "string"); ("description", `String "Sort: recent (newest), hot (score+recency), updated (most active)")]);
      ]);
    ];
  };
  {
    tool_name = "keeper_board_comment";
    tool_description = "Add a comment/reply to an existing Board post.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID to comment on")]);
        ("content", `Assoc [("type", `String "string"); ("description", `String "Comment content")]);
      ]);
      ("required", `List [`String "post_id"; `String "content"]);
    ];
  };
  {
    tool_name = "keeper_board_vote";
    tool_description = "Vote on an existing Board post to signal support or disagreement.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID to vote on")]);
        ("direction", `Assoc [("type", `String "string"); ("description", `String "up or down (default: up)")]);
      ]);
      ("required", `List [`String "post_id"]);
    ];
  };
]

let filesystem_tools : Cascade.tool_def list = [
  {
    tool_name = "keeper_fs_read";
    tool_description = "Read a file under current project root. Use for source inspection before edits.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [("type", `String "string"); ("description", `String "Relative or absolute file path")]);
        ("max_bytes", `Assoc [("type", `String "integer"); ("description", `String "Max bytes to return (default: 20000)")]);
      ]);
      ("required", `List [`String "path"]);
    ];
  };
  {
    tool_name = "keeper_fs_edit";
    tool_description = "Write/append a file under current project root. Use for concrete code changes.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [("type", `String "string"); ("description", `String "Relative or absolute file path")]);
        ("content", `Assoc [("type", `String "string"); ("description", `String "New file content or append payload")]);
        ("mode", `Assoc [("type", `String "string"); ("description", `String "overwrite (default) or append")]);
      ]);
      ("required", `List [`String "path"; `String "content"]);
    ];
  };
]

let shell_tools : Cascade.tool_def list = [
  {
    tool_name = "keeper_shell_readonly";
    tool_description = "Run a structured read-only project command. Supported ops: pwd, ls, cat, rg, git_status.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("op", `Assoc [("type", `String "string"); ("description", `String "One of: pwd, ls, cat, rg, git_status")]);
        ("path", `Assoc [("type", `String "string"); ("description", `String "Optional target path for ls/cat/rg")]);
        ("pattern", `Assoc [("type", `String "string"); ("description", `String "Search pattern for rg")]);
        ("limit", `Assoc [("type", `String "integer"); ("description", `String "Optional result limit for ls/rg")]);
        ("max_bytes", `Assoc [("type", `String "integer"); ("description", `String "Optional max bytes for cat")]);
      ]);
      ("required", `List [`String "op"]);
    ];
  };
  {
    tool_name = "keeper_bash";
    tool_description = "Run a shell command from project root. Use for build/test/check commands.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("cmd", `Assoc [("type", `String "string"); ("description", `String "Shell command string to run via zsh -lc")]);
        ("timeout_sec", `Assoc [("type", `String "number"); ("description", `String "Timeout seconds (default: 30, max: 180)")]);
      ]);
      ("required", `List [`String "cmd"]);
    ];
  };
  {
    tool_name = "keeper_github";
    tool_description = "Run gh CLI commands from project root. Use for PR/review/comment operations.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("cmd", `Assoc [("type", `String "string"); ("description", `String "gh subcommand string, e.g. 'pr view 123 --comments'")]);
        ("args", `Assoc [("type", `String "array"); ("items", `Assoc [("type", `String "string")]); ("description", `String "Optional argv list for gh (without leading gh)")]);
        ("timeout_sec", `Assoc [("type", `String "number"); ("description", `String "Timeout seconds (default: 30, max: 180)")]);
      ]);
    ];
  };
]

let voice_tools : Cascade.tool_def list = [
  {
    tool_name = "keeper_voice_speak";
    tool_description = "Speak a short utterance as this keeper via the voice bridge, falling back to text when voice is unavailable.";
    parameters = `Assoc [
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
    tool_name = "keeper_voice_agent";
    tool_description = "Get your own voice configuration (assigned voice, available voices). No network required.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    tool_name = "keeper_voice_sessions";
    tool_description = "List active voice sessions from the voice bridge.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    tool_name = "keeper_voice_session_start";
    tool_description = "Start a voice session for this keeper using the configured voice bridge.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("session_name", `Assoc [("type", `String "string"); ("description", `String "Optional session name")]);
      ]);
    ];
  };
  {
    tool_name = "keeper_voice_session_end";
    tool_description = "End the active voice session for this keeper and release bridge resources.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
]

let weather_tools : Cascade.tool_def list = [
  {
    tool_name = "keeper_weather_note";
    tool_description = "Get weather capability note and recent weather-related questions.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("location", `Assoc [("type", `String "string")]);
      ]);
    ];
  };
]

let taskboard_tools : Cascade.tool_def list = [
  {
    tool_name = "keeper_tasks_list";
    tool_description = "List tasks on the MASC backlog. Filter by status: todo, claimed, in_progress, done, cancelled.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("status", `Assoc [("type", `String "string"); ("description", `String "Filter by status (optional). One of: todo, claimed, in_progress, done, cancelled")]);
        ("include_done", `Assoc [("type", `String "boolean"); ("description", `String "Include completed tasks (default: false)")]);
      ]);
    ];
  };
  {
    tool_name = "keeper_tasks_audit";
    tool_description = "Audit task board health: find claimed/in_progress tasks whose assignees are no longer active agents (orphans).";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    tool_name = "keeper_task_force_release";
    tool_description = "Force-release a task back to Todo regardless of current assignee. Gardener privilege for orphan cleanup.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [("type", `String "string"); ("description", `String "Task ID to force-release")]);
        ("reason", `Assoc [("type", `String "string"); ("description", `String "Reason for force release")]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };
  {
    tool_name = "keeper_task_force_done";
    tool_description = "Force-mark a task as Done regardless of current assignee. Use for tasks confirmed complete but not transitioned.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [("type", `String "string"); ("description", `String "Task ID to force-complete")]);
        ("notes", `Assoc [("type", `String "string"); ("description", `String "Completion notes")]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };
  {
    tool_name = "keeper_broadcast";
    tool_description = "Broadcast a message to the MASC room. Use for status reports and announcements.";
    parameters = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("message", `Assoc [("type", `String "string"); ("description", `String "Message to broadcast")]);
      ]);
      ("required", `List [`String "message"]);
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
  description = "File I/O: read, edit";
}

let shard_shell : shard = {
  name = "shell";
  tools = shell_tools;
  removable = true;
  description = "Shell access: bash, github";
}

let shard_weather : shard = {
  name = "weather";
  tools = weather_tools;
  removable = true;
  description = "Weather queries";
}

let shard_voice : shard = {
  name = "voice";
  tools = voice_tools;
  removable = true;
  description = "Voice bridge speak output";
}

let shard_taskboard : shard = {
  name = "taskboard";
  tools = taskboard_tools;
  removable = true;
  description = "Task board management: list, audit, force-release, force-done, broadcast";
}



let agent_shards : (string, string list) Hashtbl.t = Hashtbl.create 32



(** Default shards for a new keeper (full access) *)
let default_shard_names : string list = [
  "base";
  "board";
  "filesystem";
  "shell";
  "weather";
  "voice";
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
    shard_weather;
    shard_voice;
    shard_taskboard;
  ];
  tbl

(** Get a shard by name *)
let get_shard (name : string) : shard option =
  Hashtbl.find_opt all_shards name

(** Combine tools from multiple shard names *)
let tools_of_shards (shard_names : string list) : Cascade.tool_def list =
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

(** Full tool set (all 11 tools) — backward compatible *)
let keeper_llm_tools : Cascade.tool_def list =
  tools_of_shards default_shard_names

(** {1 MCP Schemas} *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_tool_grant";
    description = "Grant a tool shard to an agent. \
Shards: base (core), board, filesystem, shell, weather, voice, taskboard.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to grant shard to");
        ]);
        ("shard_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Shard to grant: base, board, filesystem, shell, weather, voice, taskboard");
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
          ("description", `String "Shard to revoke (must be removable). One of: board, filesystem, shell, weather, voice, taskboard");
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
