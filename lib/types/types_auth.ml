(** Rate limit config *)
type rate_limit_config = {
  per_minute: int;
  burst_allowed: int;
  priority_agents: string list;
  (* Role-based multipliers *)
  reader_multiplier: float;
  worker_multiplier: float;
  admin_multiplier: float;
  (* Tool category limits *)
  broadcast_per_minute: int;
  task_ops_per_minute: int;
} [@@deriving show]

let default_rate_limit = {
  per_minute = 10;
  burst_allowed = 5;
  priority_agents = [];
  reader_multiplier = 0.5;   (* Readers get 50% of base *)
  worker_multiplier = 1.0;   (* Workers get 100% *)
  admin_multiplier = 2.0;    (* Admins get 200% *)
  broadcast_per_minute = 15;
  task_ops_per_minute = 30;
}

let rate_limit_config_to_yojson c =
  `Assoc [
    ("per_minute", `Int c.per_minute);
    ("burst_allowed", `Int c.burst_allowed);
    ("priority_agents", `List (List.map (fun s -> `String s) c.priority_agents));
    ("reader_multiplier", `Float c.reader_multiplier);
    ("worker_multiplier", `Float c.worker_multiplier);
    ("admin_multiplier", `Float c.admin_multiplier);
    ("broadcast_per_minute", `Int c.broadcast_per_minute);
    ("task_ops_per_minute", `Int c.task_ops_per_minute);
  ]

let rate_limit_config_of_yojson json =
  let open Yojson.Safe.Util in
  try
    let per_minute = json |> member "per_minute" |> to_int_option |> Option.value ~default:10 in
    let burst_allowed = json |> member "burst_allowed" |> to_int_option |> Option.value ~default:5 in
    let priority_agents =
      match json |> member "priority_agents" with
      | `Null -> default_rate_limit.priority_agents
      | `List items -> List.map to_string items
      | _ -> raise (Type_error ("priority_agents must be a list", json))
    in
    let reader_multiplier = json |> member "reader_multiplier" |> to_float_option |> Option.value ~default:0.5 in
    let worker_multiplier = json |> member "worker_multiplier" |> to_float_option |> Option.value ~default:1.0 in
    let admin_multiplier = json |> member "admin_multiplier" |> to_float_option |> Option.value ~default:2.0 in
    let broadcast_per_minute = json |> member "broadcast_per_minute" |> to_int_option |> Option.value ~default:15 in
    let task_ops_per_minute = json |> member "task_ops_per_minute" |> to_int_option |> Option.value ~default:30 in
    Ok { per_minute; burst_allowed; priority_agents; reader_multiplier; worker_multiplier; admin_multiplier;
         broadcast_per_minute; task_ops_per_minute }
  with e -> Error (Printexc.to_string e)

(** Rate limit categories *)
type rate_limit_category =
  | GeneralLimit
  | BroadcastLimit
  | TaskOpsLimit
[@@deriving show { with_path = false }]

(** Get base limit for category *)
let limit_for_category config = function
  | GeneralLimit -> config.per_minute
  | BroadcastLimit -> config.broadcast_per_minute
  | TaskOpsLimit -> config.task_ops_per_minute

(** Map tool to rate limit category *)
let category_for_tool = function
  | "masc_broadcast" -> BroadcastLimit
  (* plan_set_task / plan_clear_task added in #8873: per-task plan-slot
     writes are semantically equivalent to set_current_task /
     complete_task, so they belong to the same TaskOpsLimit (30/min)
     bucket rather than silently falling through to GeneralLimit
     (10/min). masc_batch_add_tasks intentionally omitted pending a
     maintainer call on whether a batch burns 1 or N tokens. *)
  | "masc_add_task"
  | "masc_claim_next"
  | "masc_claim_task"
  | "masc_set_current_task"
  | "masc_complete_task"
  | "masc_release_task"
  | "masc_cancel_task"
  | "masc_update_priority"
  | "masc_plan_set_task"
  | "masc_plan_clear_task"
  | "masc_transition" -> TaskOpsLimit
  | _ -> GeneralLimit

(** Rate limit error - returned when limit exceeded *)
type rate_limit_error = {
  limit: int;
  current: int;
  wait_seconds: int;
  category: rate_limit_category;
} [@@deriving show]

(** MASC Error types - compile-time error handling *)
type masc_error =
  | NotInitialized
  | AlreadyInitialized
  | AgentNotFound of string
  | AgentNotJoined of string
  | AgentAlreadyJoined of string
  | TaskNotFound of string
  | TaskAlreadyClaimed of { task_id: string; by: string }
  | TaskNotClaimed of string
  | TaskInvalidState of string  (* For cancelled tasks or invalid state transitions *)
  | TaskRoleMismatch of { task_id: string; required: string; actual: string }
  | PortalNotOpen of string
  | PortalAlreadyOpen of { agent: string; target: string }
  | PortalClosed of string
  | InvalidJson of string
  | IoError of string
  | InvalidAgentName of string
  | InvalidTaskId of string
  | InvalidFilePath of string
  (* Auth errors *)
  | Unauthorized of string        (* Missing or invalid token *)
  | Forbidden of { agent: string; action: string }  (* Valid token but no permission *)
  | TokenExpired of string
  | InvalidToken of string
  (* Rate limit errors *)
  | RateLimitExceeded of rate_limit_error
  (* Cache errors — file/memory caching *)
  | CacheError of cache_error
  (* Storage/backend errors — PG, file, git *)
  | StorageError of string
  (* Input validation errors — parsing, format *)
  | ValidationError of string

(** Cache-specific errors *)
and cache_error =
  | CacheReadFailed of string
  | CacheWriteFailed of string
  | CacheExpired of { key: string; age_hours: float }
  | CacheCorrupted of string
[@@deriving show { with_path = false }]

(** Convert error to user-friendly message *)
let rec masc_error_to_string = function
  | NotInitialized -> "❌ MASC not initialized. Use masc_init first."
  | AlreadyInitialized -> "MASC already initialized."
  | AgentNotFound name -> Printf.sprintf "❌ Agent not found: %s" name
  | AgentNotJoined name -> Printf.sprintf "❌ Agent not joined: %s. Use masc_join first." name
  | AgentAlreadyJoined name -> Printf.sprintf "⚠ %s is already in the room" name
  | TaskNotFound id -> Printf.sprintf "❌ Task not found: %s. Call masc_status to refresh your task list." id
  | TaskAlreadyClaimed { task_id; by } ->
      Printf.sprintf
        "❌ Task %s is currently owned by %s. Ask that agent to finish it, or claim a different task."
        task_id by
  | TaskNotClaimed id ->
      Printf.sprintf
        "❌ Task %s is still todo. Claim/start it first, then mark it done."
        id
  | TaskInvalidState msg -> Printf.sprintf "❌ Invalid task state: %s" msg
  | TaskRoleMismatch { task_id; required; actual } ->
      Printf.sprintf "❌ Role mismatch for %s: requires %s, agent has %s" task_id required actual
  | PortalNotOpen agent -> Printf.sprintf "❌ No portal open for %s. Use masc_portal_open first." agent
  | PortalAlreadyOpen { agent; target } -> Printf.sprintf "⚠ Portal already open: %s ↔ %s" agent target
  | PortalClosed agent -> Printf.sprintf "❌ Portal is closed for %s. Use masc_portal_open to reopen." agent
  | InvalidJson msg -> Printf.sprintf "❌ Invalid JSON: %s" msg
  | IoError msg -> Printf.sprintf "❌ IO error: %s" msg
  | InvalidAgentName reason -> Printf.sprintf "❌ Invalid agent name: %s" reason
  | InvalidTaskId reason -> Printf.sprintf "❌ Invalid task ID: %s" reason
  | InvalidFilePath reason -> Printf.sprintf "❌ Invalid file path: %s" reason
  | Unauthorized reason -> Printf.sprintf "🔐 Unauthorized: %s" reason
  | Forbidden { agent; action } -> Printf.sprintf "🚫 Forbidden: %s cannot %s" agent action
  | TokenExpired agent -> Printf.sprintf "⏰ Token expired for %s. Use masc_auth_refresh." agent
  | InvalidToken reason -> Printf.sprintf "🔑 Invalid token: %s" reason
  | RateLimitExceeded { limit; current; wait_seconds; category } ->
      Printf.sprintf "⏳ Rate limit exceeded (%s): %d/%d requests. Wait %d seconds."
        (show_rate_limit_category category) current limit wait_seconds
  | CacheError e -> cache_error_to_string e
  | StorageError msg -> Printf.sprintf "Storage error: %s" msg
  | ValidationError msg -> Printf.sprintf "Validation error: %s" msg

(** Convert cache error to user-friendly message *)
and cache_error_to_string = function
  | CacheReadFailed path -> Printf.sprintf "❌ Cache: Read failed [path=%s]" path
  | CacheWriteFailed path -> Printf.sprintf "❌ Cache: Write failed [path=%s]" path
  | CacheExpired { key; age_hours } -> Printf.sprintf "❌ Cache: Expired [key=%s, age=%.1fh]" key age_hours
  | CacheCorrupted path -> Printf.sprintf "❌ Cache: Corrupted [path=%s]" path

(** Result type alias for MASC operations *)
type 'a masc_result = ('a, masc_error) result

(* ============================================ *)
(* Authentication & Authorization Types         *)
(* ============================================ *)

(** Agent role - enforced permission levels *)
type agent_role =
  | Reader    (* Can read state, cannot modify *)
  | Worker    (* Can claim tasks, lock files, broadcast *)
  | Admin     (* Full access: init, reset, manage agents *)
[@@deriving show { with_path = false }]

let agent_role_to_string = function
  | Reader -> "reader"
  | Worker -> "worker"
  | Admin -> "admin"

let agent_role_of_string = function
  | "reader" -> Ok Reader
  | "worker" -> Ok Worker
  | "admin" -> Ok Admin
  | s -> Error ("Unknown agent role: " ^ s)

(** Issue #8386: schema enums for [agent_role] used to be hand-rolled
    in [tool_schemas_misc.ml:208], matching the same drift class as
    #8354 (task_status) and #8372 (agent_status). [agent_role] is
    nullary across all constructors so the simple [List.map] trick
    works. Adding a 4th constructor will fail compilation in
    [agent_role_to_string] and in the test asserts. *)
let all_agent_roles = [ Reader; Worker; Admin ]
let valid_agent_role_strings = List.map agent_role_to_string all_agent_roles

let agent_role_to_yojson r = `String (agent_role_to_string r)

let agent_role_of_yojson = function
  | `String s -> agent_role_of_string s
  | _ -> Error "Expected string for agent_role"

(** Agent credential - stored in .masc/auth/ *)
type agent_credential = {
  agent_name: string;
  token: string;        (* SHA256 hash of secret *)
  role: agent_role;
  created_at: string;
  expires_at: string option; [@default None]
} [@@deriving show]

let agent_credential_to_yojson c =
  let base = [
    ("agent_name", `String c.agent_name);
    ("token", `String c.token);
    ("role", agent_role_to_yojson c.role);
    ("created_at", `String c.created_at);
  ] in
  match c.expires_at with
  | Some exp -> `Assoc (base @ [("expires_at", `String exp)])
  | None -> `Assoc base

let agent_credential_of_yojson json =
  let open Yojson.Safe.Util in
  try
    let agent_name = json |> member "agent_name" |> to_string in
    let token = json |> member "token" |> to_string in
    let role_str = json |> member "role" |> to_string in
    let created_at = json |> member "created_at" |> to_string in
    let expires_at = json |> member "expires_at" |> to_string_option in
    match agent_role_of_string role_str with
    | Ok role -> Ok { agent_name; token; role; created_at; expires_at }
    | Error e -> Error e
  with e -> Error (Printexc.to_string e)

(** Auth config - room-level settings *)
type auth_config = {
  enabled: bool;
  room_secret_hash: string option; [@default None]  (* SHA256 of room secret *)
  require_token: bool; [@default false]
  default_role: agent_role; [@default Worker]
  token_expiry_hours: int; [@default 24]
} [@@deriving show]

let default_auth_config = {
  enabled = false;
  room_secret_hash = None;
  require_token = false;
  default_role = Worker;
  token_expiry_hours = 24;
}

let auth_config_to_yojson c =
  `Assoc [
    ("enabled", `Bool c.enabled);
    ("room_secret_hash", Json_util.string_opt_to_json c.room_secret_hash);
    ("require_token", `Bool c.require_token);
    ("default_role", agent_role_to_yojson c.default_role);
    ("token_expiry_hours", `Int c.token_expiry_hours);
  ]

let auth_config_of_yojson json =
  let open Yojson.Safe.Util in
  try
    let enabled = json |> member "enabled" |> to_bool in
    let room_secret_hash = json |> member "room_secret_hash" |> to_string_option in
    let require_token = json |> member "require_token" |> to_bool_option |> Option.value ~default:false in
    let default_role_str = json |> member "default_role" |> to_string_option |> Option.value ~default:"worker" in
    let token_expiry_hours = json |> member "token_expiry_hours" |> to_int_option |> Option.value ~default:24 in
    match agent_role_of_string default_role_str with
    | Ok default_role -> Ok { enabled; room_secret_hash; require_token; default_role; token_expiry_hours }
    | Error e -> Error e
  with e -> Error (Printexc.to_string e)

(** Permission matrix - what each role can do *)
type permission =
  | CanInit
  | CanReset
  | CanJoin
  | CanLeave
  | CanReadState
  | CanAddTask
  | CanClaimTask
  | CanCompleteTask
  | CanBroadcast
  | CanOpenPortal
  | CanSendPortal
  | CanCreateWorktree
  | CanRemoveWorktree
  | CanVote
  | CanAdmin
[@@deriving show { with_path = false }]

(** Get permissions for a role *)
let permissions_for_role = function
  | Reader -> [CanReadState; CanJoin; CanLeave]
  | Worker -> [
      CanReadState; CanJoin; CanLeave;
      CanAddTask; CanClaimTask; CanCompleteTask;
      CanBroadcast;
      CanOpenPortal; CanSendPortal;
      CanCreateWorktree; CanRemoveWorktree;
      CanVote;
    ]
  | Admin -> [
      CanInit; CanReset;
      CanReadState; CanJoin; CanLeave;
      CanAddTask; CanClaimTask; CanCompleteTask;
      CanBroadcast;
      CanOpenPortal; CanSendPortal;
      CanCreateWorktree; CanRemoveWorktree;
      CanVote;
      CanAdmin;
    ]

(** Check if role has permission *)
let has_permission role permission =
  List.mem permission (permissions_for_role role)

(* ============================================ *)
(* Rate limit role integration                  *)
(* ============================================ *)

(** Get role multiplier for rate limits *)
let multiplier_for_role config = function
  | Reader -> config.reader_multiplier
  | Worker -> config.worker_multiplier
  | Admin -> config.admin_multiplier

(** Compute effective limit for role and category *)
let effective_limit config ~role ~category =
  let base = limit_for_category config category in
  let mult = multiplier_for_role config role in
  int_of_float (float_of_int base *. mult)
