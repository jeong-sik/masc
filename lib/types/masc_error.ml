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
  try
    let int_field name default =
      Json_util.get_int json name |> Option.value ~default
    in
    let float_field name default =
      Json_util.get_float json name |> Option.value ~default
    in
    let string_list_field name default =
      match Json_util.get_array json name with
      | Some (`List values) ->
          List.filter_map (function `String s -> Some s | _ -> None) values
      | _ -> default
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

let limit_for_category config = function
  | GeneralLimit -> config.per_minute
  | BroadcastLimit -> config.broadcast_per_minute
  | TaskOpsLimit -> config.task_ops_per_minute

let category_for_tool_opt = function
  | "masc_broadcast" -> Some BroadcastLimit
  | "masc_add_task"
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
    | InvalidName of string

  let to_string = function
    | NotFound name -> Printf.sprintf "[AgentError] Agent not found: %s" name
    | InvalidName reason -> Printf.sprintf "[AgentError] Invalid agent name: %s" reason
end

module Auth_error = struct
  (** Typed classification of [Unauthorized] reasons.  Replaces substring
      matching in dashboard auth JSON rendering.  Each variant maps to a
      stable dashboard error code string. *)
  type unauthorized_reason =
    | Actor_mismatch   (** Token owner ≠ requested agent *)
    | Missing_token    (** No bearer token provided *)
    | Generic          (** Catch-all for other unauthorized causes *)

  type t =
    | Unauthorized of { reason: unauthorized_reason; message: string }
    | Forbidden of { agent: string; action: string }
    | TokenExpired of string
    | InvalidToken of string

  let unauthorized_reason_to_string = function
    | Actor_mismatch -> "actor_mismatch"
    | Missing_token -> "missing_token"
    | Generic -> "unknown"

  let to_string = function
    | Unauthorized { message; _ } -> Printf.sprintf "[AuthError] Unauthorized: %s" message
    | Forbidden { agent; action } -> Printf.sprintf "[AuthError] Forbidden: %s cannot %s" agent action
    | TokenExpired agent ->
        Printf.sprintf "[AuthError] Token expired for %s. Use masc_auth_refresh." agent
    | InvalidToken reason -> Printf.sprintf "[AuthError] Invalid token: %s" reason
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
    | LockContention of { key : string; attempts : int }
      (** Distributed lock acquire budget exhausted under transient
          fleet contention.  Carries the structured key + attempt count
          so callers can dispatch on the typed variant instead of
          substring-matching the IoError message (RFC-0088
          "String/Substring 분류기" anti-pattern removal). *)

  let to_string = function
    | NotInitialized -> "[SystemError] MASC not initialized. Use masc_init first."
    | AlreadyInitialized -> "[SystemError] MASC already initialized."
    | InvalidJson msg -> Printf.sprintf "[SystemError] Invalid JSON: %s" msg
    | IoError msg -> Printf.sprintf "[SystemError] IO error: %s" msg
    | InvalidFilePath reason -> Printf.sprintf "[SystemError] Invalid file path: %s" reason
    | StorageError msg -> Printf.sprintf "[SystemError] Storage error: %s" msg
    | ValidationError msg -> Printf.sprintf "[SystemError] Validation error: %s" msg
    | LockContention { key; attempts } ->
        Printf.sprintf
          "[SystemError] Failed to acquire distributed lock for key: %s \
           (%d attempts exhausted; transient contention, retry later)"
          key attempts
end

type t =
  | Task of Task_error.t
  | Agent of Agent_error.t
  | Auth of Auth_error.t
  | System of System_error.t
  | RateLimitExceeded of rate_limit_error
  | CacheError of cache_error

let to_string = function
  | Task e -> Task_error.to_string e
  | Agent e -> Agent_error.to_string e
  | Auth e -> Auth_error.to_string e
  | System e -> System_error.to_string e
  | RateLimitExceeded e ->
      Printf.sprintf "[RateLimit] Rate limit exceeded (%s): %d/%d requests. Wait %d seconds."
        (Rate_limit_types.rate_limit_category_to_string e.category) e.current e.limit e.wait_seconds
  | CacheError e -> (match e with
      | CacheReadFailed path -> Printf.sprintf "[CacheError] Read failed [path=%s]" path
      | CacheWriteFailed path -> Printf.sprintf "[CacheError] Write failed [path=%s]" path
      | CacheExpired { key; age_hours } -> Printf.sprintf "[CacheError] Expired [key=%s, age=%.1fh]" key age_hours
      | CacheCorrupted path -> Printf.sprintf "[CacheError] Corrupted [path=%s]" path)

let show = to_string

let to_yojson err =
  `String (to_string err)

let code = function
  | Auth (Auth_error.Forbidden _) -> 403
  | Auth (Auth_error.Unauthorized _
         | Auth_error.TokenExpired _
         | Auth_error.InvalidToken _) -> 401
  | Task (Task_error.NotFound _) -> 404
  | Agent (Agent_error.NotFound _) -> 404
  | Task (Task_error.AlreadyClaimed _
         | Task_error.NotClaimed _
         | Task_error.InvalidState _
         | Task_error.InvalidId _) -> 400
  | Agent (Agent_error.InvalidName _) -> 400
  | System (System_error.NotInitialized
           | System_error.AlreadyInitialized
           | System_error.InvalidJson _
           | System_error.IoError _
           | System_error.InvalidFilePath _
           | System_error.StorageError _
           | System_error.ValidationError _) -> 400
  | System (System_error.LockContention _) -> 503
  | RateLimitExceeded _ -> 429
  | CacheError _ -> 500

(* [dashboard_auth_error_code] is the SSOT mapping from a typed
   [masc_error] to the stable dashboard auth-error-code string that the
   Bonsai dashboard's [DashboardShellAuthSummary.auth_error_code] /
   keeper stream 401 retry gate consume (TS enum in
   dashboard/src/types/dashboard-execution.ts). Introduced in #21040
   for the shell summary; this top-level home lets both
   [server_dashboard_http_core] (shell JSON) and [server_auth]
   (401 error body) emit the same typed code without a second copy of
   the classifier or a backward dependency.

   The match is exhaustive on the outer [t] so a new auth-relevant
   variant trips Warning 8 here instead of silently falling through.
   The [Forbidden { agent = "browser"; action = "cross-origin HTTP
   mutation" }] arm matches the literal action string produced in
   [Server_auth.ensure_same_origin_browser_request]; that string pair
   is a pre-existing coupling carried over verbatim from #21040, not a
   new substring classifier. *)
let dashboard_auth_error_code : t -> string option = function
  | Auth (Auth_error.InvalidToken _) -> Some "invalid_token"
  | Auth (Auth_error.TokenExpired _) -> Some "token_expired"
  | Auth
      (Auth_error.Forbidden
         { agent = "browser"; action = "cross-origin HTTP mutation" }) ->
      Some "same_origin_blocked"
  | Auth (Auth_error.Forbidden _) -> Some "insufficient_role"
  | Auth (Auth_error.Unauthorized { reason; _ }) ->
      Some (Auth_error.unauthorized_reason_to_string reason)
  | Task _ | Agent _ | System _ | RateLimitExceeded _ | CacheError _ ->
      Some "unknown"

(* [is_retryable] mirrors [Error.is_retryable] in OAS so MASC-side
   callers don't have to fall back on an OAS-only predicate when
   reasoning about a [masc_error]. Conservative — when in doubt
   return [false] so callers don't loop on deterministic
   failures. Source for the audit-driven motivation:
   2026-04-29 OAS↔MASC Implementation Quality Audit
   §"Re-tryability". *)
let is_retryable = function
  | Task _ | Agent _ -> false
  | Auth (Auth_error.TokenExpired _) -> true
  | Auth (Auth_error.Unauthorized _ | Auth_error.Forbidden _
         | Auth_error.InvalidToken _) -> false
  | System (System_error.IoError _ | System_error.StorageError _
           | System_error.LockContention _) -> true
  | System (System_error.NotInitialized | System_error.AlreadyInitialized
           | System_error.InvalidJson _ | System_error.InvalidFilePath _
           | System_error.ValidationError _) -> false
  | RateLimitExceeded _ -> true
  | CacheError (CacheReadFailed _ | CacheWriteFailed _ | CacheExpired _) -> true
  | CacheError (CacheCorrupted _) -> false
