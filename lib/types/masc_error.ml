(** Unified error type for MASC MCP *)

include Rate_limit_types

let default_rate_limit = {
  per_minute = 10;
  burst_allowed = 5;
  priority_agents = [];
  worker_multiplier = 1.0;
  admin_multiplier = 2.0;
  broadcast_per_minute = 15;
  task_ops_per_minute = 30;
}

let rate_limit_config_to_yojson c =
  `Assoc [
    ("per_minute", `Int c.per_minute);
    ("burst_allowed", `Int c.burst_allowed);
    ("priority_agents", `List (List.map (fun s -> `String s) c.priority_agents));
    ("worker_multiplier", `Float c.worker_multiplier);
    ("admin_multiplier", `Float c.admin_multiplier);
    ("broadcast_per_minute", `Int c.broadcast_per_minute);
    ("task_ops_per_minute", `Int c.task_ops_per_minute);
  ]

let rate_limit_config_of_yojson json =
  let open Yojson.Safe.Util in
  try
    let field name = json |> member name in
    let int_field name default =
      match field name with
      | `Null -> default
      | value -> to_int value
    in
    let float_field name default =
      match field name with
      | `Null -> default
      | value -> to_float value
    in
    let string_list_field name default =
      match field name with
      | `Null -> default
      | value -> value |> to_list |> filter_string
    in
    let per_minute = int_field "per_minute" default_rate_limit.per_minute in
    let burst_allowed = int_field "burst_allowed" default_rate_limit.burst_allowed in
    let priority_agents =
      string_list_field "priority_agents" default_rate_limit.priority_agents
    in
    let worker_multiplier =
      float_field "worker_multiplier" default_rate_limit.worker_multiplier
    in
    let admin_multiplier =
      float_field "admin_multiplier" default_rate_limit.admin_multiplier
    in
    let broadcast_per_minute =
      int_field "broadcast_per_minute" default_rate_limit.broadcast_per_minute
    in
    let task_ops_per_minute =
      int_field "task_ops_per_minute" default_rate_limit.task_ops_per_minute
    in
    Ok { per_minute; burst_allowed; priority_agents; worker_multiplier;
         admin_multiplier; broadcast_per_minute; task_ops_per_minute }
  with e -> Error (Printexc.to_string e)

let show_rate_limit_category = show_rate_limit_category
let show_rate_limit_error = show_rate_limit_error

let limit_for_category config = function
  | GeneralLimit -> config.per_minute
  | BroadcastLimit -> config.broadcast_per_minute
  | TaskOpsLimit -> config.task_ops_per_minute

let category_for_tool_opt = function
  | "masc_broadcast" -> Some BroadcastLimit
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
  | "masc_transition" -> Some TaskOpsLimit
  | _ -> None

let category_for_tool tool =
  match category_for_tool_opt tool with
  | Some category -> category
  | None -> GeneralLimit

type cache_error =
  | CacheReadFailed of string
  | CacheWriteFailed of string
  | CacheExpired of { key: string; age_hours: float }
  | CacheCorrupted of string

module Task_error = struct
  type t =
    | NotFound of string
    | AlreadyClaimed of { task_id: string; by: string }
    | NotClaimed of string
    | InvalidState of string
    | InvalidId of string

  let to_string = function
    | NotFound id ->
        Printf.sprintf
          "[TaskError] Task not found: %s. Call masc_status to refresh your task list."
          id
    | AlreadyClaimed { task_id; by } ->
        Printf.sprintf
          "[TaskError] Task %s is currently owned by %s. Ask that agent to finish it, or claim a different task."
          task_id by
    | NotClaimed id ->
        Printf.sprintf
          "[TaskError] Task %s is still todo. Claim/start it first, then mark it done."
          id
    | InvalidState msg -> Printf.sprintf "[TaskError] Invalid task state: %s" msg
    | InvalidId reason -> Printf.sprintf "[TaskError] Invalid task ID: %s" reason
end

module Agent_error = struct
  type t =
    | NotFound of string
    | NotJoined of string
    | AlreadyJoined of string
    | InvalidName of string

  let to_string = function
    | NotFound name -> Printf.sprintf "[AgentError] Agent not found: %s" name
    | NotJoined name ->
        Printf.sprintf "[AgentError] Agent not joined: %s. Use masc_join first." name
    | AlreadyJoined name -> Printf.sprintf "[AgentError] Agent already joined: %s" name
    | InvalidName reason -> Printf.sprintf "[AgentError] Invalid agent name: %s" reason
end

module Auth_error = struct
  type t =
    | Unauthorized of string
    | Forbidden of { agent: string; action: string }
    | TokenExpired of string
    | InvalidToken of string

  let to_string = function
    | Unauthorized reason -> Printf.sprintf "[AuthError] Unauthorized: %s" reason
    | Forbidden { agent; action } -> Printf.sprintf "[AuthError] Forbidden: %s cannot %s" agent action
    | TokenExpired agent ->
        Printf.sprintf "[AuthError] Token expired for %s. Use masc_auth_refresh." agent
    | InvalidToken reason -> Printf.sprintf "[AuthError] Invalid token: %s" reason
end

module Portal_error = struct
  type t =
    | NotOpen of string
    | AlreadyOpen of { agent: string; target: string }
    | Closed of string

  let to_string = function
    | NotOpen agent ->
        Printf.sprintf
          "[PortalError] No portal open for %s. Use masc_portal_open first."
          agent
    | AlreadyOpen { agent; target } -> Printf.sprintf "[PortalError] Portal already open: %s <-> %s" agent target
    | Closed agent ->
        Printf.sprintf
          "[PortalError] Portal is closed for %s. Use masc_portal_open to reopen."
          agent
end

module System_error = struct
  type t =
    | NotInitialized
    | AlreadyInitialized
    | InvalidJson of string
    | IoError of string
    | InvalidFilePath of string
    | StorageError of string
    | ValidationError of string

  let to_string = function
    | NotInitialized -> "[SystemError] MASC not initialized. Use masc_init first."
    | AlreadyInitialized -> "[SystemError] MASC already initialized."
    | InvalidJson msg -> Printf.sprintf "[SystemError] Invalid JSON: %s" msg
    | IoError msg -> Printf.sprintf "[SystemError] IO error: %s" msg
    | InvalidFilePath reason -> Printf.sprintf "[SystemError] Invalid file path: %s" reason
    | StorageError msg -> Printf.sprintf "[SystemError] Storage error: %s" msg
    | ValidationError msg -> Printf.sprintf "[SystemError] Validation error: %s" msg
end

type t =
  | Task of Task_error.t
  | Agent of Agent_error.t
  | Auth of Auth_error.t
  | Portal of Portal_error.t
  | System of System_error.t
  | RateLimitExceeded of rate_limit_error
  | CacheError of cache_error

let to_string = function
  | Task e -> Task_error.to_string e
  | Agent e -> Agent_error.to_string e
  | Auth e -> Auth_error.to_string e
  | Portal e -> Portal_error.to_string e
  | System e -> System_error.to_string e
  | RateLimitExceeded e ->
      Printf.sprintf "[RateLimit] Rate limit exceeded (%s): %d/%d requests. Wait %d seconds."
        (show_rate_limit_category e.category) e.current e.limit e.wait_seconds
  | CacheError e -> (match e with
      | CacheReadFailed path -> Printf.sprintf "[CacheError] Read failed [path=%s]" path
      | CacheWriteFailed path -> Printf.sprintf "[CacheError] Write failed [path=%s]" path
      | CacheExpired { key; age_hours } -> Printf.sprintf "[CacheError] Expired [key=%s, age=%.1fh]" key age_hours
      | CacheCorrupted path -> Printf.sprintf "[CacheError] Corrupted [path=%s]" path)

let show = to_string

let to_yojson err =
  `String (to_string err)

let code = function
  | Auth _ -> 401
  | Task _ | Agent _ | Portal _ | System _ -> 400
  | RateLimitExceeded _ -> 429
  | _ -> 500
