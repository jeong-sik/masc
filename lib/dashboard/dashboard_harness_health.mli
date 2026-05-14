(** Dashboard_harness_health — operator harness-health
    telemetry: wake-time payload sampling, pre-compact
    events, and recent eval-calibration verdicts.

    External surface:
    - {b records} ({!harness_verdict_item},
      {!wake_payload_event}) reached as types or via
      record-pattern access by callers.
    - {b record-wake / record-pre-compact} writers
      ({!record_wake_payload}, {!record_pre_compact}) used
      by [keeper_agent_run] / [keeper_wake_telemetry] /
      [keeper_compact_policy] / [env_config_keeper].
    - {b verdict readers} ({!read_recent_verdicts},
      {!read_recent_verdicts_for_agents}) consumed by the
      keeper monitoring HTTP route.
    - {b dashboard JSON entry} ({!json}) consumed by
      [server_routes_http_routes_dashboard].

    Internal helpers stay private at this boundary
    ([rail_status] type, [handoff_event] type,
    [wake_payload_event_json] /
    [wake_payload_event_of_json], [date_bounds] /
    [start_date] / [end_date], [max_recent_verdicts],
    [read_store_records], [verdict_item_of_json],
    [record_pre_compact_at] / [record_wake_payload_at]
    timestamp-injection variants, [get_pre_compact_store],
    every other private accumulator). *)

(** {1 Verdict record} *)

(** One row of the recent harness verdicts ledger.
    Reached as a type by [dashboard_http_keeper] and as
    record-pattern access by the eval-calibration HTTP
    surface. *)
type harness_verdict_item =
  { timestamp : float
  ; task_id : string
  ; task_title : string
  ; agent_name : string
  ; gate : string
  ; verdict : string
  ; evaluator_cascade : string
  ; fallback_reason : string option
  }

(** {1 Pre-compact event} *)

(** Pre-compact telemetry record returned by
    {!record_pre_compact}.  Reached by record-pattern
    access in [keeper_compact_policy] when assembling the
    snapshot JSON.  [trigger] is the closed-sum classification
    of the gate that fired — pair with [Compaction_trigger.to_label]
    for Prometheus emission and [to_detail_json] for SSE/JSON. *)
type pre_compact_event =
  { timestamp : float
  ; keeper_name : string
  ; context_ratio : float
  ; message_count : int
  ; token_count : int
  ; strategies : string list
  ; context_window : int
  ; is_local_model : bool
  ; trigger : Compaction_trigger.t
  }

(** {1 Wake-payload event} *)

(** Wake-time payload observation captured once per
    keeper turn (just before [Keeper_turn_driver.run_named]
    fires).  [approx_body_bytes] is a MASC-side estimate;
    expect the real HTTP body to be ~1.3–1.5× this.
    Reached as a type by [keeper_agent_run]. *)
type wake_payload_event =
  { timestamp : float
  ; keeper_name : string
  ; trace_id : string
  ; turn_index : int
  ; model_id : string
  ; context_window : int
  ; approx_body_bytes : int
  ; system_prompt_bytes : int
  ; tool_defs_bytes : int
  ; messages_bytes : int
  ; message_count : int
  ; role_counts : (string * int) list
  ; tool_count : int
  ; has_compact_happened : bool
  }

(** {1 Recorders} *)

(** Records one pre-compact event into the in-memory
    rolling store and returns the constructed event.
    Threaded by [keeper_compact_policy] when a compaction
    fires; the caller reaches the event's fields via
    record-pattern access. *)
val record_pre_compact
  :  keeper_name:string
  -> context_ratio:float
  -> message_count:int
  -> token_count:int
  -> strategies:string list
  -> context_window:int
  -> is_local_model:bool
  -> trigger:Compaction_trigger.t
  -> pre_compact_event

(** Timestamp-injection variant of {!record_pre_compact}.
    Test-only seam — production callers thread the wall
    clock via {!record_pre_compact}. *)
val record_pre_compact_at
  :  timestamp:float
  -> keeper_name:string
  -> context_ratio:float
  -> message_count:int
  -> token_count:int
  -> strategies:string list
  -> context_window:int
  -> is_local_model:bool
  -> trigger:Compaction_trigger.t
  -> pre_compact_event

(** Records one wake-time payload sample and returns the
    constructed event.  Threaded by [keeper_agent_run] /
    [keeper_wake_telemetry] (and indirectly by
    [env_config_keeper]); callers may reach the
    [wake_payload_event] fields directly. *)
val record_wake_payload
  :  keeper_name:string
  -> trace_id:string
  -> turn_index:int
  -> model_id:string
  -> context_window:int
  -> approx_body_bytes:int
  -> system_prompt_bytes:int
  -> tool_defs_bytes:int
  -> messages_bytes:int
  -> message_count:int
  -> role_counts:(string * int) list
  -> tool_count:int
  -> has_compact_happened:bool
  -> wake_payload_event

(** {1 Verdict readers} *)

(** Returns the most recent calibration verdicts.
    [?since] / [?until] are ISO-date strings; [?limit]
    defaults to the internal [max_recent_verdicts] cap. *)
val read_recent_verdicts
  :  ?since:string
  -> ?until:string
  -> ?limit:int
  -> unit
  -> harness_verdict_item list

(** Filtered variant of {!read_recent_verdicts} — keeps
    only verdicts whose [agent_name] matches a (trimmed,
    non-empty) entry of [agent_names].  Returns [\[\]]
    when the filter list is empty after trimming. *)
val read_recent_verdicts_for_agents
  :  ?since:string
  -> ?until:string
  -> ?limit:int
  -> agent_names:string list
  -> unit
  -> harness_verdict_item list

(** {1 Wake-payload reader} *)

(** Returns the wake-payload samples within the
    [?since] / [?until] ISO-date window, sorted by
    descending timestamp. *)
val read_wake_payload_events
  :  ?since:string
  -> ?until:string
  -> unit
  -> wake_payload_event list

(** {1 Test-only store accessors} *)

(** Lazily materializes (and caches) the wake-payload
    rolling store.  Pinned because
    [test/test_dashboard_harness_health.ml] reaches it
    directly to assert on disk state. *)
val get_wake_payload_store : unit -> Dated_jsonl.t

(** Drops the cached pre-compact / wake-payload store
    handles so the next access re-resolves the base
    directory.  Test-only seam used between cases. *)
val reset_runtime_stores_for_testing : unit -> unit

(** Forces the pre-compact store to point at [base_dir]
    instead of the resolved configuration default.
    Test-only seam — production paths leave this alone. *)
val set_pre_compact_store_for_testing : base_dir:string -> unit

(** Forces the wake-payload store to point at [base_dir]
    instead of the resolved configuration default.
    Test-only seam — production paths leave this alone. *)
val set_wake_payload_store_for_testing : base_dir:string -> unit

(** {1 Dashboard JSON entry} *)

(** Renders the harness-health dashboard envelope:
    eval-calibration stats, recent verdicts, pre-compact
    events, and wake-payload telemetry — clipped to the
    [?since] / [?until] window when provided. *)
val json : config:Coord.config -> ?since:string -> ?until:string -> unit -> Yojson.Safe.t
