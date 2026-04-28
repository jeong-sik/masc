(** Audit Log Writer for MASC.

    Writes immutable audit events to a date-split JSONL store under
    [<config.masc_dir>/audit/YYYY-MM/DD.jsonl] for security
    monitoring and post-incident analysis.

    Public surface covers: typed events ({!action} / {!outcome} /
    {!audit_entry}), wire-format converters, the per-event
    [log_*] convenience wrappers (each one composes the right
    [action] + [details] payload before delegating to {!log_action}),
    plus reader / pruner / stats helpers.

    Internal helpers ([preview], [string_to_action], [outcome_to_json]
    decoders, the [audit_store_cache] and its mutex,
    [get_audit_store], [parse_entries], [max_logged_errors],
    [remove_assoc_keys]) are hidden — callers use the typed log
    helpers and the read / prune / stats accessors only.

    Security basis:
      - Open Challenges in MAS Security (arxiv:2505.02077v1)
      - Immutable audit trails for post-incident analysis

    @since 0.6.0 — MASC Social v4 Tier 1 *)

type config = Coord_utils.config

(** {1 Event types} *)

type outcome =
  | Success
  | Failure of string

type action =
  | Join
  | Leave
  | ClaimTask
  | StartTask
  | DoneTask
  | CancelTask
  | ReleaseTask
  | Broadcast
  | Suspend
  | ToolCall of string
  | AuthSuccess
  | AuthFailure
  | CircuitOpen
  | CircuitClose
  | SearchRefinement
  | GovernanceDecision of string
  | Custom of string

type audit_entry = {
  timestamp : float;
  agent_id : string;
  action : action;
  room_id : string option;
  details : Yojson.Safe.t;
  outcome : outcome;
  cost_estimate : float option;
  token_count : int option;
  trace_id : string option;
}

(** {1 Wire-format} *)

val action_to_string : action -> string
(** Stable serialisation; round-tripped by the legacy reader. The
    parametric variants ([ToolCall] / [GovernanceDecision] /
    [Custom]) are encoded as ["<tag>:<arg>"]. *)

val entry_to_json : audit_entry -> Yojson.Safe.t

val entry_of_json_r : Yojson.Safe.t -> (audit_entry, string) result
(** Strict decoder. *)

val entry_of_json : Yojson.Safe.t -> audit_entry option
(** Lenient wrapper around {!entry_of_json_r} that logs and drops
    bad entries. *)

(** {1 Storage} *)

val legacy_audit_path : config -> string
(** Pre-date-split [audit.jsonl] location, kept for migration
    callers that need to detect the old single-file layout. *)

val read_entries : ?n:int -> config -> audit_entry list
(** Most-recent [n] (default 10000) parsed entries from the
    date-split store. Malformed lines are logged (capped) and
    dropped. *)

val append_entry : config -> audit_entry -> unit
(** Atomic append to today's day-file; creates the directory and
    file on first call. *)

(** {1 Logging — generic} *)

val log_action :
  config ->
  agent_id:string ->
  action:action ->
  ?room_id:string ->
  ?details:Yojson.Safe.t ->
  ?cost_estimate:float ->
  ?token_count:int ->
  ?trace_id:string ->
  outcome:outcome ->
  unit ->
  unit
(** Build an {!audit_entry} stamped with the current time and
    persist it via {!append_entry}. The [log_*] helpers below all
    delegate to this. *)

(** {1 Logging — per-action helpers} *)

val log_join :
  config ->
  agent_id:string ->
  ?cost_estimate:float ->
  ?token_count:int ->
  unit -> unit

val log_leave :
  config ->
  agent_id:string ->
  ?cost_estimate:float ->
  ?token_count:int ->
  unit -> unit

val log_claim_task :
  config ->
  agent_id:string ->
  task_id:string ->
  ?cost_estimate:float ->
  ?token_count:int ->
  unit -> unit

val log_done_task :
  config ->
  agent_id:string ->
  task_id:string ->
  ?cost_estimate:float ->
  ?token_count:int ->
  unit -> unit

val log_cancel_task :
  config ->
  agent_id:string ->
  task_id:string ->
  reason:string ->
  ?cost_estimate:float ->
  ?token_count:int ->
  unit -> unit

val log_broadcast :
  config ->
  agent_id:string ->
  message_preview:string ->
  ?cost_estimate:float ->
  ?token_count:int ->
  unit -> unit
(** Truncates [message_preview] to 100 chars before logging. *)

val log_suspend :
  config ->
  agent_id:string ->
  target_agent:string ->
  reason:string ->
  rooms_affected:int ->
  ?cost_estimate:float ->
  ?token_count:int ->
  unit -> unit

val log_tool_call :
  config ->
  agent_id:string ->
  tool_name:string ->
  success:bool ->
  error_msg:string option ->
  ?cost_estimate:float ->
  ?token_count:int ->
  ?trace_id:string ->
  unit -> unit

val log_system_internal_tool_call :
  config ->
  agent_id:string ->
  tool_name:string ->
  success:bool ->
  error_msg:string option ->
  ?details:Yojson.Safe.t ->
  ?cost_estimate:float ->
  ?token_count:int ->
  ?trace_id:string ->
  unit -> unit
(** Records under action [Custom "system_internal_tool_call"] with a
    [surface=system_internal] details envelope so dashboards can
    distinguish internal MCP traffic from agent-initiated calls. *)

val log_client_tool_host_failure :
  config ->
  agent_id:string ->
  client_name:string ->
  tool_name:string ->
  transport:string ->
  message:string ->
  ?phase:string ->
  ?request_id:string ->
  ?session_id:string ->
  ?trace_id:string ->
  ?timeout_ms:int ->
  unit -> unit

val log_auth_attempt :
  config ->
  agent_id:string ->
  success:bool ->
  method_name:string ->
  ?cost_estimate:float ->
  ?token_count:int ->
  unit -> unit

val log_circuit_breaker :
  config ->
  agent_id:string ->
  opened:bool ->
  reason:string ->
  ?cost_estimate:float ->
  ?token_count:int ->
  unit -> unit

val log_governance_decision :
  config ->
  agent_id:string ->
  trace_id:string ->
  decision:string ->
  action_type:string ->
  confirmation_state:string ->
  unit -> unit

(** {1 Maintenance} *)

val prune_old : config -> days:int -> unit
(** Drop day-files older than [days] days. *)

(** {1 Statistics} *)

type stats = {
  total_entries : int;
  file_size_bytes : int;
  oldest_timestamp : float option;
  newest_timestamp : float option;
}

val get_stats : config -> stats
(** [file_size_bytes] is always [0] under the date-split layout. *)

val stats_to_json : stats -> Yojson.Safe.t
