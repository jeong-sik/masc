(** A2a_tools — A2A protocol wrapped as MCP tools.

    Cascade-includes {!A2a_types} via [include module type
    of struct include M end] so callers reach the canonical
    [task_type] / [event_type] / [artifact] /
    [delegate_result] / [a2a_task_state] /
    [a2a_task_status] / [parse_a2a_version] /
    [default_a2a_version] / [task_type_of_string] /
    [event_type_of_string] / [a2a_task_state_to_string] /
    [a2a_task_state_of_string] / [masc_status_to_a2a] /
    [a2a_task_status_to_json] surface via the
    {!A2a_tools.X} namespace.

    On top of the cascade, this module owns the live state
    (subscriptions / event buffers / heartbeat snapshots)
    and exposes the runtime mutators
    ([init], [delegate], [notify_event],
    [emit_heartbeat_task] / [submit_heartbeat_result],
    [cleanup_*]) plus the local
    [subscription] / [buffered_event] records.

    Internal helpers stay private at this boundary
    ([SMap], [atomic_update], the [subscriptions] /
    [subscriptions_file] / [event_buffers] /
    [latest_heartbeat_tasks] / [latest_heartbeat_results] /
    [heartbeat_snapshot_seq] / [uuid_rng] /
    [uuid_rng_mutex] global refs, [save_subscriptions] /
    [load_subscriptions] persistence helpers,
    [next_heartbeat_snapshot_seq], [evict_heartbeat_map],
    [remote_agent_card_paths], [fetch_remote_agent_card],
    [discover], [query_skill], [subscribe], [unsubscribe],
    [list_subscriptions], [poll_events], [buffer_event],
    [subscription_max_idle_sec], [max_heartbeat_agents]). *)

include module type of struct
  include A2a_types
end

(** {1 Subscription record} *)

type subscription = {
  id : string;
  agent_filter : string option;
  event_types : event_type list;
  created_at : string;
  mutable last_polled_at : float;
}
(** A single event subscription.  [agent_filter = None]
    matches every agent; [Some "*"] is the explicit
    wildcard.  [last_polled_at] is bumped on every
    {!poll_events} call so {!cleanup_stale_subscriptions}
    can age out subscriptions that haven't been touched
    within the 24-hour idle window. *)

val show_subscription : subscription -> string

val subscription_to_json : subscription -> Yojson.Safe.t

val subscription_of_json : Yojson.Safe.t -> subscription option
(** Parser; returns [None] (with a warning to
    [Log.Misc.warn]) when [id] / [created_at] are missing. *)

(** {1 Buffered event record} *)

type buffered_event = {
  event_type : event_type;
  agent : string;
  data : Yojson.Safe.t;
  timestamp : float;
}
(** Single event held in a per-subscription FIFO buffer.
    Drained by {!poll_events}; capped at
    {!max_buffered_events}. *)

val show_buffered_event : buffered_event -> string

val show_artifact : artifact -> string
val show_delegate_result : delegate_result -> string
val show_event_type : event_type -> string
val show_task_type : task_type -> string

(** {1 Constants + IDs} *)

val max_buffered_events : int
(** Per-subscription FIFO ceiling
    (from [Env_config_governance.Timeouts.event_buffer_size]).
    The notify path drops oldest events when this would be
    exceeded so a slow subscriber cannot OOM the server. *)

val generate_uuid : unit -> string
(** Stable UUIDv4 string.  Uses a dedicated [Random.State]
    guarded by [Stdlib.Mutex] so cross-domain callers stay
    deterministic and lock-safe. *)

val now_iso8601 : unit -> string
(** Wall-clock UTC timestamp in [YYYY-MM-DDTHH:MM:SSZ]
    form. *)

val event_type_to_string : event_type -> string
(** Wire encoder ([TaskUpdate] → ["task_update"], etc).
    Inverse of {!A2a_types.event_type_of_string}. *)

(** {1 Lifecycle} *)

val init : masc_dir:string -> unit
(** Wires the subscription persistence file under
    [masc_dir/subscriptions.json] and reloads any saved
    state. *)

val clear_transient_state : unit -> unit
(** Drops every in-memory subscription / buffer /
    heartbeat snapshot.  Used by the test harness for
    isolation between cases. *)

(** {1 Heartbeat snapshots} *)

type heartbeat_task_snapshot = {
  seq : int;
  goal : string;
  context : string;
  worker_mode : string;
  allowed_tools : string list;
  decision_reason : string option;
  created_at : string;
}

type heartbeat_result_snapshot = {
  seq : int;
  status : string;
  summary : string;
  worker_name : string;
  tool_call_count : int;
  tool_names : string list;
  decision_reason : string;
  decision_confidence : float;
  failure_reason : string option;
  updated_at : string;
}

val latest_heartbeat_task :
  string -> heartbeat_task_snapshot option
(** Most recent task snapshot for the given agent, [None]
    when nothing has been published since startup or the
    entry has aged out. *)

val latest_heartbeat_result :
  string -> heartbeat_result_snapshot option
(** Most recent worker-completion snapshot for the given
    agent. *)

val emit_heartbeat_task :
  agent:string ->
  goal:string ->
  context:string ->
  allowed_tools:string list ->
  ?board_id:string ->
  ?worker_mode:string ->
  ?mcp_base_url:string ->
  ?session_id:string ->
  ?decision_reason:string ->
  ?decision_confidence:float ->
  unit ->
  unit
(** Records a heartbeat task snapshot for [agent] and
    notifies every matching subscription with a
    [HeartbeatTask] event.  [worker_mode] defaults to
    ["mcp_tool_loop"]; the optional fields collapse to
    JSON [null] when absent. *)

val submit_heartbeat_result :
  worker_name:string ->
  agent:string ->
  status:string ->
  summary:string ->
  tool_call_count:int ->
  tool_names:string list ->
  decision_reason:string ->
  decision_confidence:float ->
  ?failure_reason:string ->
  unit ->
  (Yojson.Safe.t, string) result
(** Records a worker-completion snapshot from a worker
    finishing a heartbeat task.  [status] is normalised
    (lower-cased + trimmed) before storage so callers can
    pass either ["acted"] or ["ACTED"].  Returns the
    persisted JSON envelope on success, an error string on
    validation failure. *)

(** {1 Notification} *)

val notify_event :
  event_type:event_type ->
  agent:string ->
  data:Yojson.Safe.t ->
  unit
(** Routes [data] to every subscription whose
    [agent_filter] and [event_types] match.  Always
    delivers to [HeartbeatTask] subscriptions regardless
    of [agent_filter] (the heartbeat path is always
    broadcast).  Drops oldest buffered events when a
    subscription would exceed {!max_buffered_events}. *)

(** {1 Delegate} *)

val delegate :
  Coord.config ->
  agent_name:string ->
  target:string ->
  message:string ->
  ?task_type_str:string ->
  ?artifacts:artifact list ->
  ?timeout:int ->
  unit ->
  (Yojson.Safe.t, string) result
(** Delegates work to a peer agent over the A2A protocol.
    [task_type_str] defaults to ["async"]; rejects
    self-delegation (where [target] resolves to the same
    coord identity as [agent_name]) and portal-path
    aliases.  Returns the JSON envelope of the remote
    response, or an error string on validation /
    transport failure. *)

(** {1 Cleanup} *)

val cleanup_stale_heartbeats : active_agents:string list -> unit -> int
(** Removes heartbeat snapshots whose agent is no longer
    in [active_agents].  Returns the number of entries
    purged.  Idempotent — repeated calls return 0 once
    drift is settled. *)

val cleanup_orphan_buffers : unit -> int
(** Drops event-buffer entries whose subscription id no
    longer exists in {!subscriptions}.  Returns the
    number of orphans purged. *)

val cleanup_stale_subscriptions : unit -> int
(** Expires subscriptions whose
    [last_polled_at] is older than the 24-hour idle
    window.  Also drops their event buffers.  Returns the
    number of subscriptions purged. *)
