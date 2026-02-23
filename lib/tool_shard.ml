(** Tool_shard — Dynamic tool sharding for MASC agents.

    Allows tools to be granted/revoked at runtime like equipment slots.
    Each agent can have multiple active shards that contribute tools.

    @since 2.62.0 *)

(** A named collection of tools that can be granted/revoked. *)
type shard = {
  name : string;
  tools : Llm_client.tool_def list;
  removable : bool;  (** true = can be revoked at runtime *)
  description : string;
}

(** Predefined shards *)

let base_tools : Llm_client.tool_def list = [
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

let board_tools : Llm_client.tool_def list = [
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
]

let filesystem_tools : Llm_client.tool_def list = [
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

let shell_tools : Llm_client.tool_def list = [
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

let weather_tools : Llm_client.tool_def list = [
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

(** All predefined shards by name *)
let all_shards : (string, shard) Hashtbl.t =
  let tbl = Hashtbl.create 16 in
  List.iter (fun s -> Hashtbl.add tbl s.name s) [
    shard_base;
    shard_board;
    shard_filesystem;
    shard_shell;
    shard_weather;
  ];
  tbl

(** Get a shard by name *)
let get_shard (name : string) : shard option =
  Hashtbl.find_opt all_shards name

(** Default shards for a new keeper (full access) *)
let default_shard_names : string list = [
  "base";
  "board";
  "filesystem";
  "shell";
  "weather";
]

(** Combine tools from multiple shard names *)
let tools_of_shards (shard_names : string list) : Llm_client.tool_def list =
  shard_names
  |> List.filter_map (fun name -> Hashtbl.find_opt all_shards name)
  |> List.concat_map (fun (s : shard) -> s.tools)

(** {1 Dynamic Shard Management} *)

(** Grant a shard to an agent. Returns new active_shards list.
    Fails if shard doesn't exist or is already granted. *)
let[@warning "-32"] grant_shard (active_shards : string list) (shard_name : string) :
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
let[@warning "-32"] revoke_shard (active_shards : string list) (shard_name : string) :
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
let[@warning "-32"] list_all_shards () : (string * bool * int) list =
  Hashtbl.fold (fun name (shard : shard) acc ->
    (name, shard.removable, List.length shard.tools) :: acc
  ) all_shards []

(** Full tool set (all 11 tools) — backward compatible *)
let keeper_llm_tools : Llm_client.tool_def list =
  tools_of_shards default_shard_names
