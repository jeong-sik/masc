(** Telemetry_eio — event tracking + analytics over a date-split
    JSONL store.

    Public surface covers: typed events ({!event} / {!event_record} /
    {!metrics}) with their auto-derived JSON / show converters, the
    [track_*] convenience emitters, the read-side aggregations
    ([read_all_events], [read_events_since], [summarize_tool_usage],
    [summarize_agent_activity], [get_metrics]), the pure metric
    calculators, plus the [rotate] maintenance entry point.

    Internal helpers ([empty_tool_usage_stats], [update_tool_usage],
    [telemetry_file], the [telemetry_store_cache] Hashtbl + mutex,
    [get_telemetry_store], [telemetry_eio_surface] /
    [observe_telemetry_drop] / [report_telemetry_drop],
    [read_all_events_from_path], [event_to_json], [track], and the
    [nonempty_opt] string utility) are hidden — callers consume the
    typed event ADT and the convenience emitters / readers only.

    The date-split telemetry store applies bounded retention by default:
    [MASC_TELEMETRY_RETENTION_DAYS] defaults to 30 and
    [MASC_TELEMETRY_MAX_BYTES] defaults to 52428800. Positive values override;
    non-positive values disable the matching bound. The byte cap prunes oldest
    completed day-files while preserving the current day-file. *)

type config = Workspace_utils.config

(** {1 Events} *)

(** Typed wrapper for tool-call error classification labels. JSONL rows
    continue to encode [error_kind] as the stable string label. *)
type error_kind = private Error_kind of string

val error_kind_of_string : string -> error_kind
val error_kind_to_string : error_kind -> string

type event =
  | Agent_session_bound of { agent_id : string; capabilities : string list }
  | Agent_unbound of { agent_id : string; reason : string }
  | Task_started of { task_id : string; agent_id : string }
  | Task_completed of {
      task_id : string;
      duration_ms : int;
      success : bool;
    }
  | Handoff_triggered of {
      from_agent : string;
      to_agent : string;
      reason : string;
    }
  | Error_occurred of {
      code : string;
      message : string;
      context : string;
    }
  | Tool_called of {
      tool_name : string;
      success : bool;
      duration_ms : int;
      agent_id : string option; [@default None]
      source : string option; [@default None]
      session_id : string option; [@default None]
      operation_id : string option; [@default None]
      worker_run_id : string option; [@default None]
      error_kind : error_kind option; [@default None]
      error_message : string option; [@default None]
      exit_code : int option; [@default None]
      stderr_excerpt : string option; [@default None]
      failure_class : Tool_result.tool_failure_class option; [@default None]
    }
  | Tool_assigned of {
      agent_id : string;
      profile : string;
      tool_count : int;
      assignment_id : string;
    }
[@@deriving yojson, show]

type event_record = {
  timestamp : float;
  event : event;
} [@@deriving yojson, show]

(** {1 Aggregated metrics} *)

type metrics = {
  active_agents : int;
  tasks_in_progress : int;
  tasks_completed_24h : int;
  avg_task_duration_ms : float;
  handoff_rate : float;
  error_rate : float;
} [@@deriving yojson, show]

type tool_usage_stats = {
  count : int;
  success_count : int;
  failure_count : int;
  last_used_at : float option;
}

type tool_usage_summary = {
  telemetry_path : string;
  telemetry_available : bool;
  total_calls : int;
  stats_by_tool : (string, tool_usage_stats) Hashtbl.t;
}

type agent_activity = {
  agent_id : string;
  tool_calls : int;
  success_count : int;
  failure_count : int;
  first_seen : float;
  last_seen : float;
}

(** {1 Read side} *)

val read_all_events : ?fs:'a -> config -> event_record list

val read_recent_events :
  ?fs:'a -> config -> limit:int -> event_record list

val read_events_since :
  ?fs:'a -> config -> since:float -> event_record list

val parse_event_records : Yojson.Safe.t list -> event_record list

val event_to_json : event -> Yojson.Safe.t
(** Project [event] to its JSONL row shape (with the current
    timestamp stamped in, then [event_record_to_yojson] applied).
    Exposed for the telemetry coverage test that asserts JSON
    payload shape directly. *)

val summarize_tool_usage : ?fs:'a -> config -> tool_usage_summary

val summarize_agent_activity :
  ?fs:'a -> config -> since:float -> agent_activity list

val tool_usage_fields :
  tool_usage_summary -> string -> (string * Yojson.Safe.t) list

val get_metrics : ?fs:'a -> config -> metrics

(** {1 Pure metric calculators} *)

val count_active_agents : event_record list -> int
val count_tasks_in_progress : event_record list -> int
val count_completed_tasks : event_record list -> int
val avg_duration : event_record list -> float
val calculate_handoff_rate : event_record list -> float
val calculate_error_rate : event_record list -> float

(** {1 Convenience emitters} *)

val track_result : ?fs:'a -> config -> event -> (unit, string) result
(** Result-returning base emitter for callers that need explicit persistence
    failure handling. *)

val track_agent_session_bound :
  ?fs:'a ->
  config ->
  agent_id:string ->
  ?capabilities:string list ->
  unit ->
  unit

val track_agent_unbound :
  ?fs:'a -> config -> agent_id:string -> reason:string -> unit

val track_task_started :
  ?fs:'a -> config -> task_id:string -> agent_id:string -> unit

val track_task_completed :
  ?fs:'a ->
  config ->
  task_id:string ->
  duration_ms:int ->
  success:bool ->
  unit

(* track_handoff intentionally not exposed: 0 production callers as
   of #10358 (c2) audit. The Handoff_triggered variant remains in
   [event] above for wire-schema compatibility but no public emitter
   exists. Add a new emitter only when masc introduces a real
   runtime-routing handoff concept. *)

val track_error :
  ?fs:'a ->
  config ->
  code:string ->
  message:string ->
  context:string ->
  unit

val track_tool_called :
  ?fs:'a ->
  config ->
  tool_name:string ->
  success:bool ->
  duration_ms:int ->
  ?agent_id:string ->
  ?source:string ->
  ?session_id:string ->
  ?operation_id:string ->
  ?worker_run_id:string ->
  ?failure_class:Tool_result.tool_failure_class ->
  ?error_kind:error_kind ->
  ?error_message:string ->
  ?exit_code:int ->
  ?stderr_excerpt:string ->
  unit ->
  unit
(** When [success = false] and [error_kind] is provided, additionally
    emits a paired [Error_occurred] row with a context envelope built
    from the non-empty optional fields (#10358). *)

val track_tool_assigned :
  ?fs:'a ->
  config ->
  agent_id:string ->
  profile:string ->
  tool_count:int ->
  assignment_id:string ->
  unit ->
  unit

(** {1 Maintenance} *)

val rotate : fs:'a -> config -> max_age_days:int -> unit
(** Drop telemetry day-files older than [max_age_days] days. The
    [fs] argument is currently ignored but kept in the signature for
    forward compatibility with a future stub-fs override. *)
