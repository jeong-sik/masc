(** Dashboard_harness_health — operator harness-health
    telemetry: wake-time payload sampling and recent
    eval-calibration verdicts.

    External surface:
    - {b records} ({!harness_verdict_item},
      {!wake_payload_event}) reached as types or via
      record-pattern access by callers.
    - {b record-wake} writer ({!record_wake_payload}) used
      by [keeper_agent_run] / [keeper_wake_telemetry] /
      [env_config_keeper].
    - {b verdict readers} ({!read_recent_verdicts},
      {!read_recent_verdicts_for_agents}) consumed by the
      keeper monitoring HTTP route.
    - {b dashboard JSON entry} ({!json}) consumed by
      [server_routes_http_routes_dashboard].

    Internal helpers stay private at this boundary
    ([rail_status] type,
    [wake_payload_event_json] /
    [wake_payload_event_of_json], [date_bounds] /
    [start_date] / [end_date], [max_recent_verdicts],
    [read_store_records], [verdict_item_of_json],
    [record_wake_payload_at] timestamp-injection variant,
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
  ; evaluator_runtime : string
  ; fallback_reason : string option
  ; notes_hash : string
    (** The calibration correlation key: a human label recorded against this
        hash joins this verdict in {!Eval_calibration.find_divergences}. *)
  }

(** {1 Wake-payload event} *)

(** Wake-time payload observation captured once per
    keeper turn (just before [Keeper_turn_driver.run_named]
    fires). Component byte fields measure the exact canonical values
    MASC owns, not a provider-specific HTTP request body.
    Reached as a type by [keeper_agent_run]. *)
type wake_payload_event =
  { timestamp : float
  ; keeper_name : string
  ; trace_id : string
  ; turn_index : int
  ; context_window : int
  ; system_prompt_bytes : int
  ; tool_schema_json_bytes : int
  ; message_content_bytes : int
  ; message_count : int
  ; role_counts : (string * int) list
  ; tool_count : int
  }

(** {1 Recorders} *)

(** Records one wake-time payload sample and returns the
    constructed event.  Threaded by [keeper_agent_run] /
    [keeper_wake_telemetry]; callers may reach the
    [wake_payload_event] fields directly. *)
val record_wake_payload
  :  keeper_name:string
  -> trace_id:string
  -> turn_index:int
  -> context_window:int
  -> system_prompt_bytes:int
  -> tool_schema_json_bytes:int
  -> message_content_bytes:int
  -> message_count:int
  -> role_counts:(string * int) list
  -> tool_count:int
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
    descending timestamp. Records missing required exact fields, carrying a
    wrong JSON type, or containing malformed role counts are warned and rejected. *)
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

(** Drops the cached wake-payload store handle so the next access re-resolves the base
    directory.  Test-only seam used between cases. *)
val reset_runtime_stores_for_testing : unit -> unit

(** Forces the wake-payload store to point at [base_dir]
    instead of the resolved configuration default.
    Test-only seam — production paths leave this alone. *)
val set_wake_payload_store_for_testing : base_dir:string -> unit

(** {1 Dashboard JSON entry} *)

(** Renders the harness-health dashboard envelope:
    eval-calibration stats, recent verdicts, and
    wake-payload telemetry — clipped to the
    [?since] / [?until] window when provided. *)
val json : ?since:string -> ?until:string -> unit -> Yojson.Safe.t

(** {1 Operator labels} *)

type label_request =
  { label_notes_hash : string
  ; label_verdict : Eval_calibration.label_verdict
  ; label_reason : string
  }

val parse_label_body : string -> (label_request, string) result
(** Parse the harness-label POST body:
    [{"notes_hash": <64 hex>, "verdict": "approve" | "reject",
      "reason": <string>}].
    The verdict is the one the human holds, not agreement with the machine:
    divergence mining compares it against the evaluator's verdict under the
    same notes hash. *)

val record_operator_label : labeler:string -> label_request -> unit
(** Append the label to the calibration ledger, joined to its verdict by
    [label_notes_hash]. *)
