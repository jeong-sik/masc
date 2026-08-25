type agent = {
  name : string;
  status : string;
  current_task : string option;
  last_seen : string;
}

type task = {
  id : string;
  title : string;
  status : Masc_domain.task_status;
  priority : int;
}

type keeper = {
  k_name : string;
  k_trace_id : string;
  k_paused : bool;
  k_current_task_id : string option;
  k_total_turns : int;
  k_total_tokens : int;
  k_total_cost_usd : float;
  k_last_turn_ts : string;
  k_compaction_count : int;
  k_last_proactive_outcome : string;
  k_created_at : string;
  k_updated_at : string;
}

val sanitize_terminal_text : string -> string
(** Escape C0, DEL, raw C1 bytes, UTF-8 encoded C1 code points, and malformed
    UTF-8 bytes so external values form one printable terminal row. Call at the
    terminal rendering boundary; decoded records intentionally retain their raw
    typed value for non-terminal consumers. *)

val short_timestamp_for_terminal : string -> string
(** Keep at most the first 19 source bytes, then sanitize the result. Slicing
    before the terminal boundary ensures a split UTF-8 scalar cannot recreate a
    raw C1 byte. Empty timestamps render as [(never)]. *)

val clock_timestamp_for_terminal :
  localtime:(float -> Unix.tm) -> string -> string
(** The [HH:MM:SS] clock of an RFC 3339 timestamp in the zone [localtime]
    converts to - [Unix.localtime] on a screen, [Unix.gmtime] or a fixed
    offset in a test - then sanitized. A timestamp the codec cannot read
    keeps the conventional eight-byte slice, so the result is still one
    clock-shaped row fragment; the final sanitizer makes arbitrary external
    bytes safe even when the slice splits UTF-8. *)


(** Where a goal stands with the completion judge.

    The phase says [executing] both for a goal nobody has reviewed and for one
    the judge refused with a reason. Those are different situations, and the
    reason is the whole product of the verification lane — a judge that states
    what it measured and how it compared is no use if the reason stops at the
    wire. *)
type goal_proof =
  | Proof_idle  (** No verdict on the ledger: nothing has been asked of it. *)
  | Proof_pending  (** A completion request is durable and the judge has not answered. *)
  | Proof_proven of string option
      (** Approved. [Some] is what the judge measured; [None] is a verdict
          recorded without text, which is a different fact from an empty
          measurement and is drawn as such. *)
  | Proof_refuted of string option  (** Refused; [Some] is why. *)
  | Proof_unreadable of string option
      (** The ledger did not decode, or named a state this build does not know.
          Distinct from {!Proof_idle}: an unreadable store is not the same fact
          as an unreviewed goal, and showing it as "not reviewed" would
          disguise corruption as quiet. *)

type planning_goal = {
  pg_id : string;
  pg_title : string;
  pg_phase : Goal_phase.t;
  pg_priority : int;
  pg_due_date : string option;
  pg_metric : string option;
  pg_target_value : string option;
  pg_proof : goal_proof;
  pg_last_review_note : string option;
      (** What a keeper or operator wrote at the last transition. Free text,
          unlike {!pg_proof}, which is the judge's. *)
}

type planning_rollup = {
  pr_active : int;
  pr_verifying : int;
  pr_done : int;
  pr_dropped : int;
}

type planning_backlog = {
  pb_todo : int;
  pb_claimed : int;
  pb_running : int;
  pb_done : int;
  pb_cancelled : int;
}

type planning_snapshot = {
  pl_goals : planning_goal list;
  pl_rollup : planning_rollup;
  pl_backlog : planning_backlog;
  pl_generated_at : string;
}

(** One line of the server's system log, as {!val:decode_system_log_snapshot}
    reads it from [GET /api/v1/dashboard/logs]. *)

type system_log_level =
  | System_debug
  | System_info
  | System_warn
  | System_error
  | System_level_unknown of string
      (** A level the server emits that this vocabulary does not name. Kept as
          written rather than folded into an existing level, so a new level is
          visible instead of silently rendering as one of these. *)

type system_log_entry = {
  sl_seq : int;
  sl_ts : string;
  sl_level : system_log_level;
  sl_module : string;
  sl_keeper : string option;
  sl_message : string;
}

(** One tool call from a keeper's durable call log
    ([GET /api/v1/keepers/:name/tool-calls]). The row's own [keeper] is
    checked against the keeper that was asked for; a row naming another is
    rejected rather than attributed by envelope position. *)
type keeper_call = {
  kc_at : float;  (** [ts], unix seconds *)
  kc_tool : string;
  kc_input : string;  (** the call's argument text as served, may be truncated *)
  kc_output : string option;
      (** what the call answered, as served and already bounded by the server.
          [None] means the row carried no result, which is not the same as a
          call that returned an empty one. *)
  kc_success : bool;
  kc_duration_ms : float option;
  kc_turn : int option;
  kc_task_id : string option;
  kc_model : string option;
}

type keeper_calls_snapshot = {
  kcs_keeper : string;
  kcs_entries : keeper_call list;  (** in the server's order, newest last *)
  kcs_count : int;
  kcs_health : string;  (** the server's own freshness verdict, verbatim *)
  kcs_latest_age_s : float option;
  kcs_stale_reason : string option;
  kcs_mismatched : int;  (** rows naming another keeper, rejected *)
}

val decode_keeper_calls_snapshot :
  requested_keeper:string -> Yojson.Safe.t -> (keeper_calls_snapshot, string) result

type system_log_snapshot = {
  sys_entries : system_log_entry list;  (** newest last, as the server returns *)
  sys_total : int;  (** lines the ring has seen, not lines returned *)
  sys_latest_seq : int;
}

(** A registered tool, as the inventory lists it. *)
type tool_entry = {
  tl_name : string;
  tl_description : string;
  tl_surfaces : string list;
      (** Where the tool is visible: the MCP surface, keeper projections, and
          so on. Empty means registered and projected nowhere. *)
  tl_direct_call : bool;
}

type inventory_freshness =
  | Warming
      (** The server answered with its warming placeholder: it has not built
          the inventory yet, so the empty list beside this is not an answer
          about how many tools exist. *)
  | Settled
      (** The server answered from a built inventory. An empty list here does
          mean no tools. *)

type tool_snapshot = {
  ts_tools : tool_entry list;
  ts_count : int;
  ts_freshness : inventory_freshness;
      (** Whether the count above is an answer. *)
}

(** A connector the gate can deliver through. *)
type connector = {
  cn_id : string;
  cn_display_name : string;
  cn_available : bool;  (** Configured and usable. *)
  cn_connected : bool;
      (** Reachable right now. Kept apart from [cn_available]: a connector can
          be configured and unreachable, and the two call for different
          actions. *)
  cn_status : string;
  cn_channel : string option;
}

type connector_snapshot = {
  cs_connectors : connector list;
  cs_total : int;
  cs_active : int;  (** How many the server counted as available. *)
}

(** Whether the non-blocking runtime-probe route served a cached reading or
    scheduled background work. The wire vocabulary is closed so a producer
    change cannot silently look fresh. *)
type runtime_probe_refresh_state =
  | Runtime_probe_fresh
  | Runtime_probe_recent
  | Runtime_probe_served_stale
  | Runtime_probe_warming_up

(** Fleet-level reachability verdict published by the runtime inventory
    projection. This is provider metadata reachability, not a completion or
    lane failover verdict. *)
type runtime_probe_status =
  | Runtime_probe_reachable
  | Runtime_probe_no_http_runtimes
  | Runtime_probe_degraded
  | Runtime_probe_unreachable
  | Runtime_probe_warming

type runtime_provider_status =
  | Runtime_provider_reachable
  | Runtime_provider_missing_auth
  | Runtime_provider_auth_failed
  | Runtime_provider_network_error
  | Runtime_provider_server_error
  | Runtime_provider_endpoint_not_found
  | Runtime_provider_http_error
  | Runtime_provider_unknown_http_status
  | Runtime_provider_skipped_cli
  | Runtime_provider_invalid_endpoint
  | Runtime_provider_invalid_execution_transport

type runtime_probe_transport =
  | Runtime_probe_http
  | Runtime_probe_cli

type runtime_provider_probe = {
  rpp_runtime_id : string;
  rpp_transport : runtime_probe_transport;
  rpp_status : runtime_provider_status;
  rpp_reachable : bool option;
  rpp_http_status : int option;
  rpp_latency_ms : float option;
  rpp_error : string option;
  rpp_checked_at : string;
}

type runtime_probe_summary = {
  rpsu_runtimes : int;
  rpsu_probed : int;
  rpsu_reachable : int;
  rpsu_failed : int;
  rpsu_skipped : int;
  rpsu_default_runtime_id : string option;
}

type runtime_probe_snapshot = {
  rps_generated_at : string;
  rps_refreshed_at_unix : float option;
  rps_cache_ttl_sec : float;
  rps_cache_age_sec : float option;
  rps_cache_hit : bool;
  rps_refresh_state : runtime_probe_refresh_state;
  rps_status : runtime_probe_status;
  rps_probe_ok : bool;
  rps_checked_at : string;
  rps_summary : runtime_probe_summary;
  rps_providers : runtime_provider_probe list;
  rps_errors : string list;
  rps_observations : string list;
  rps_limitations : string list;
}

(** One runtime row shared by the Keeper picker and Runtime surface.
    [ro_is_default] is derived from the document's top-level
    [default_runtime], not the row's independent binding flag. *)
type runtime_option = {
  ro_id : string;
  ro_provider : string;
  ro_model : string;
  ro_dispatchable : bool;
  ro_blocked_reason : string option;
  ro_is_default : bool;
}

type runtime_resolved_lane = {
  rrl_id : string;
  rrl_runtime_ids : string list;
  rrl_preferred_candidate : string option;
  rrl_preferred_at_ts : float option;
      (** Sticky last-success observation, not a failure timestamp. *)
}

type runtime_resolved_snapshot = {
  rrs_generated_at_iso : string;
  rrs_config_path : string option;
  rrs_default_runtime_id : string option;
  rrs_runtimes : runtime_option list;
  rrs_lanes : runtime_resolved_lane list;
}

(** One lane candidate after an exact [runtime_id] join. Resolved inventory
    owns provider/model identity; the probe owns only its optional observation.
    A missing probe is unobserved, never inferred unhealthy. *)
type runtime_candidate_row = {
  rcr_lane_id : string;
  rcr_position : int;
  rcr_candidate_count : int;
  rcr_runtime : runtime_option;
  rcr_preferred_at_ts : float option;
  rcr_probe : runtime_provider_probe option;
}

type runtime_surface_snapshot = {
  rss_probe : runtime_probe_snapshot option;
      (** Current or last-good optional observation. [None] means no provider
          probe has been read; resolved lane identity remains usable. *)
  rss_probe_error : string option;
      (** Why the latest probe read failed. May coexist with [rss_probe] when
          a last-good observation was preserved. *)
  rss_resolved : runtime_resolved_snapshot;
  rss_candidates : runtime_candidate_row list;
  rss_unassigned_probe_count : int;
}

val runtime_probe_refresh_state_to_string : runtime_probe_refresh_state -> string
val runtime_probe_status_to_string : runtime_probe_status -> string
val runtime_provider_status_to_string : runtime_provider_status -> string

(** A repository the workspace tracks. *)
type repository = {
  rp_name : string;
  rp_local_path : string;
  rp_default_branch : string;
  rp_status : string;
  rp_keepers : string list;  (** Which keepers work in it. *)
  rp_auto_sync : bool;
}

type repository_snapshot = {
  rs_repositories : repository list;
  rs_total : int;
}

(** One verdict the harness recorded: which gate ran on which task, what it
    decided, and which evaluator decided it. *)
type harness_verdict = {
  hv_at : float;
  hv_task_id : string;
  hv_task_title : string;
  hv_agent : string;
  hv_gate : string;
  hv_verdict : string;
  hv_evaluator : string;
  hv_fallback_reason : string option;
      (** Why the named evaluator did not run, when something else did. A
          verdict reached by a fallback is not the verdict that was asked for,
          and the surface says so rather than showing them alike. *)
}

type harness_snapshot = {
  hs_verdicts : harness_verdict list;  (** newest first, as the server sends *)
}

(** One task waiting on a verdict, as the verification surface lists it. *)
type verification_request = {
  vr_request_id : string;
  vr_task_id : string;
  vr_task_title : string;
  vr_kind : string;  (** What is being asked for, e.g. a review or a proof. *)
  vr_summary : string;
  vr_next_action : string option;
      (** What would move it forward, when the server can say. *)
  vr_submitted_by : string;
  vr_created_at : string;
  vr_required_artifacts : string list;
  vr_submitted_evidence : string list;
  vr_evidence_error : string option;
      (** Why the submitted evidence could not be read, when it could not.
          Kept apart from the list so an empty list means "none submitted"
          rather than "none readable". *)
}

type verification_snapshot = {
  vs_requests : verification_request list;
  vs_total : int;  (** Requests the server holds, not the number returned. *)
}

type keeper_phase
(** A validated Keeper lifecycle phase from the live roster. The underlying
    state-machine type stays behind this decoder boundary so TUI executables do
    not need a second dependency on the Keeper runtime library. *)

val keeper_phase_of_string : string -> keeper_phase option
val keeper_phase_to_string : keeper_phase -> string

type keeper_health
(** A validated keeper health reading — whether the keeper is reporting on
    time. Behind the decoder boundary for the same reason as {!keeper_phase}:
    a TUI executable should not need a second dependency on the Keeper runtime
    library to name one. *)

val keeper_health_of_string : string -> keeper_health option
val keeper_health_to_string : keeper_health -> string

type keeper_health_reading =
  | Health_running  (** Keepalive alive, turns recent, nothing quiet about it *)
  | Health_idle  (** Keepalive alive, no recent activity *)
  | Health_offline  (** No agent present, or the agent says it is inactive *)
  | Health_stale  (** The last signal is older than the health window *)
  | Health_degraded  (** The agent's status file did not read or decode *)
  | Health_zombie  (** Registry entry outstanding, its fiber already ended *)

val keeper_health_reading : keeper_health -> keeper_health_reading
(** The health reading as a variant a surface can match.

    {!keeper_health_to_string} is for showing a person a word. A surface that
    branches on health matched that word instead, which put a renamed label
    one edit away from silently reading as the healthy case -- and collapsed
    stale, degraded, and zombie into it, so three broken keepers drew the
    same mark as a working one. *)


type keeper_runtime = {
  kr_name : string;
  kr_health : keeper_health;
  kr_paused : bool;
  kr_next_action : Keeper_status_runtime.keeper_next_action_path option;
  kr_keepalive_running : bool;
  kr_autoboot_enabled : bool;
  kr_proactive_enabled : bool;
  kr_runtime_id : string;
  kr_phase : keeper_phase;
}
(** One row of [GET /api/v1/gate/keepers] — the live runtime reading of a
    keeper, as [masc_keeper_list] renders it.

    One keeper is described by four separate readings and each has its own
    field here: [kr_phase] is the lifecycle cell, [kr_health] is whether the
    keeper is reporting on time, [kr_paused] is whether a person stopped it,
    and [kr_next_action] is what the runtime derived to do about it.

    [kr_next_action] is [None] when the runtime named no action, which is not
    the same as naming one that means "nothing to do". *)

val decode_keeper_runtime_list :
  Yojson.Safe.t -> (keeper_runtime list * bool * int, string) result
(** Decode the [keepers] array of [GET /api/v1/gate/keepers] into
    [(rows, truncated, total)]. A row whose [status] or lifecycle [phase] is
    outside its typed vocabulary fails the whole reading rather than defaulting, so producer
    drift surfaces as an error instead of a wrong status glyph. *)

(** Lifecycle value shown by the Lanes surface. The composite endpoint is an
    operator projection whose vocabulary can grow before this binary does, so
    an unknown value remains visible instead of becoming a familiar phase. *)
type keeper_lane_phase =
  | Lane_phase_offline
  | Lane_phase_running
  | Lane_phase_failing
  | Lane_phase_compacting
  | Lane_phase_handing_off
  | Lane_phase_draining
  | Lane_phase_paused
  | Lane_phase_stopped
  | Lane_phase_crashed
  | Lane_phase_restarting
  | Lane_phase_unknown of string

val keeper_lane_phase_to_string : keeper_lane_phase -> string

(** Turn-cycle value shown beside {!keeper_lane_phase}. *)
type keeper_lane_turn_phase =
  | Lane_turn_idle
  | Lane_turn_prompting
  | Lane_turn_routing
  | Lane_turn_executing
  | Lane_turn_compacting
  | Lane_turn_finalizing
  | Lane_turn_exhausted
  | Lane_turn_unknown of string

val keeper_lane_turn_phase_to_string : keeper_lane_turn_phase -> string

type keeper_lane_last_outcome = {
  klo_runtime_state : string;
  klo_selected_model : string option;
}

type keeper_lane = {
  kl_keeper : string;
  kl_phase : keeper_lane_phase;
  kl_turn_phase : keeper_lane_turn_phase;
  kl_idle_seconds : int;
  kl_last_outcome : keeper_lane_last_outcome option;
  kl_diagnosis : string option;
      (** The producer's determining condition, or [None] when no condition
          currently determines the phase. *)
}

type keeper_lanes_snapshot = {
  kls_generated_at : float;
  kls_count : int;
  kls_lanes : keeper_lane list;
}

val decode_keeper_lanes_snapshot :
  Yojson.Safe.t -> (keeper_lanes_snapshot, string) result
(** Decode the fields the Lanes table reads from
    [GET /api/v1/keepers/composite]. Missing or wrongly typed fields reject
    the reading; additional producer fields are outside this light
    projection and do not. *)

(** Closed lifecycle vocabulary emitted by the Fusion run registry. A failed
    run carries the registry's typed failure fields rather than flattening
    them into a display string. *)
type fusion_run_status =
  | Fusion_running
  | Fusion_completed
  | Fusion_failed of {
      frs_failure_code : string;
      frs_error : string;
    }

val fusion_run_status_to_string : fusion_run_status -> string

type fusion_run = {
  fur_run_id : string;
  fur_keeper : string;
  fur_preset : string;
  fur_topology : Fusion_types.fusion_topology;
  fur_started_at : float;
  fur_status : fusion_run_status;
}

type fusion_snapshot = {
  fus_generated_at : string;
  fus_runs : fusion_run list;
}

type fusion_panel_answer = {
  fpa_model : string;
  fpa_answer : string;
  fpa_input_tokens : int;
  fpa_output_tokens : int;
}

type fusion_panel_failure = {
  fpf_model : string;
  fpf_reason_code : string;
  fpf_reason_detail : string;
}

type fusion_panel_result =
  | Fusion_panel_answered of fusion_panel_answer
  | Fusion_panel_failed of fusion_panel_failure

type fusion_judge =
  | Fusion_judge_synthesized of {
      fj_decision : string;
      fj_resolved_answer : string;
      fj_reason : string;
    }
  | Fusion_judge_failed of {
      fj_failure_code : string;
      fj_error : string;
    }

type fusion_evidence = {
  fe_post_id : string;
  fe_title : string;
  fe_question : string;
  fe_panel : fusion_panel_result list;
  fe_judge : fusion_judge;
}

type fusion_evidence_status =
  | Fusion_evidence_recorded
  | Fusion_evidence_pending
  | Fusion_evidence_absent

type fusion_detail = {
  fud_generated_at : string;
  fud_run : fusion_run;
  fud_evidence_status : fusion_evidence_status;
  fud_evidence : fusion_evidence option;
}

val decode_fusion_snapshot : Yojson.Safe.t -> (fusion_snapshot, string) result
(** Decode the retained registry list from
    [GET /api/v1/dashboard/fusion-runs]. The published count must equal the
    decoded row count; unknown lifecycle labels reject the reading. *)

val decode_fusion_detail : Yojson.Safe.t -> (fusion_detail, string) result
(** Decode one exact run/evidence projection. [recorded] requires a Board post
    whose typed origin is exactly [source=fusion] and whose [fusion_run_id]
    matches the registry row. [pending] and [absent] require [post:null], and
    only a running row may be pending. Panel array order is retained. *)

(** One tool call a keeper is holding for an operator's answer, from
    [GET /api/v1/keepers/tool-approvals]. [kta_asked_at] is the server
    clock's epoch reading when the wait opened. *)
type keeper_tool_approval = {
  kta_keeper : string;
  kta_tool_call_id : string;
  kta_tool : string;
  kta_args : string;
  kta_question : string;
  kta_asked_at : float;
  kta_timeout_sec : float;
}

val decode_tool_approval_mode_overrides :
  Yojson.Safe.t -> ((string * string) list, string) result
(** Decode [GET /api/v1/keepers/tool-approval-mode]'s
    [{overrides: [{keeper, mode}]}] into (keeper, mode) pairs. *)

val decode_keeper_tool_approvals :
  Yojson.Safe.t -> (keeper_tool_approval list, string) result
(** Decode the [{pending: [...]}] listing, oldest first, rejecting rows with
    missing or mistyped fields rather than dropping them. *)

(** Where one keeper points today. [ra_source] is the server's word:
    ["default"] rides the fleet default, ["explicit"] was assigned. *)
type runtime_assignment = {
  ra_keeper : string;
  ra_source : string;
  ra_target_id : string option;
      (** Resolved lane id, or [None] when the assignment is missing. *)
}

val decode_runtime_resolved :
  Yojson.Safe.t ->
  (runtime_option list * runtime_assignment list, string) result
(** Decode the shared resolved-runtime document once, then project its runtime
    catalogue and keeper assignments for the picker, both in server order. *)

type fleet_safety = {
  fs_status : string;
  fs_blocker : string option;
  fs_operator_action_required : bool;
  fs_bootable_count : int;
  fs_running_count : int;
  fs_executable_count : int;
  fs_failing_count : int;
  fs_recovering_count : int;
  fs_paused_count : int;
  fs_target_reaction_capacity : int;
  fs_reaction_capacity_shortfall : int;
  fs_bootable_names : string list;
  fs_running_names : string list;
  fs_executable_names : string list;
  fs_active_task_owner_without_fiber_count : int;
  fs_completion_authority_pending_count : int;
}
(** The operator reading of the keeper fleet, as [/health?full=1] reports it.

    Every count here answers "how many keepers are not doing what the fleet
    intends", which is the question the keeper list cannot answer: that list
    holds one row per running keeper, so a keeper that failed to start is
    absent rather than shown as failed.

    The three name lists are carried raw, and they answer three different
    questions, so a reader that wants one has to name which. Keepers that
    never started are [bootable] minus [running]. Keepers that are running
    but cannot take a turn are [running] minus [executable] — a fiber is
    alive, its durable demand is not admissible. Collapsing the two reads a
    live fleet as a stopped one. *)

type server_identity = {
  sid_version : string;
  sid_binary_commit : string;
  sid_binary_commit_age_s : float option;
  sid_base_path : string;
  sid_masc_root : string;
}
(** Which server the TUI is talking to, as [/health] reports it.

    The footer said [Port: 8935] and nothing else, so two checkouts serving
    on the same port were indistinguishable from the screen -- and a binary
    older than the tree it was built from looked exactly like a current one.
    [sid_binary_commit_age_s] is how long ago that binary's commit landed,
    which is the number that separates the two. *)

val decode_server_identity : Yojson.Safe.t -> (server_identity, string) result

type log_kind =
  | Log_turn
  | Log_heartbeat

type log_channel =
  | Log_channel_turn
  | Log_channel_scheduled_autonomous
  | Log_channel_heartbeat

type log_entry = {
  le_kind : log_kind;
  le_ts : string;
  le_channel : log_channel;
  le_message_count : int option;
  le_input_tokens : int option;
  le_output_tokens : int option;
  le_latency_ms : int option;
  le_cost_usd : float option;
  le_work_kind : string option;
  le_tools_used : string list;
}

type context_unavailable_reason =
  | Context_measurement_missing
  | Context_turn_record_undecodable
  | Context_turn_record_read_failed
  | Context_turn_record_without_usage
  | Context_turn_record_trace_mismatch

type context_observation =
  | Context_observed of {
      ratio : float option;
      tokens : int;
      maximum : int option;
      observed_at : string;
      turn_ref : string;
    }
  | Context_unavailable of context_unavailable_reason

val decode_agent : Yojson.Safe.t -> (agent, string) result
val task_of_domain : Masc_domain.task -> task
val active_tasks_of_domain : Masc_domain.task list -> task list
val decode_task : Yojson.Safe.t -> (task, string) result
val keeper_of_meta : Keeper_meta_contract.keeper_meta -> keeper
val decode_keeper : Yojson.Safe.t -> (keeper, string) result
(** Transport summary the server reports for its own delivery paths. A path
    that is not listening carries no session or port, so those stay [None]
    rather than collapsing to zero. *)
type transport_health = {
  th_primary_path : Transport_metrics.primary_path_kind;
  th_queue_pressure : Transport_metrics.queue_pressure_kind;
  th_sse_sessions : int;
  th_websocket_sessions : int option;
  th_grpc_port : int option;
  th_events_dropped : int;
}

val decode_transport_health :
  Yojson.Safe.t -> (transport_health, string) result

val decode_tool_snapshot : Yojson.Safe.t -> (tool_snapshot, string) result
(** Reads [tool_inventory] out of the /dashboard/tools envelope. *)

val decode_connector_snapshot :
  Yojson.Safe.t -> (connector_snapshot, string) result

val decode_runtime_probe_snapshot :
  Yojson.Safe.t -> (runtime_probe_snapshot, string) result
(** Strict decoder for [GET /api/v1/dashboard/runtime-probe]. It accepts only
    the producer's closed status vocabularies, requires the cache and provider
    fields the Runtime surface draws, and rejects count/reachability/default
    identity contradictions instead of repairing them locally. *)

val decode_runtime_resolved_snapshot :
  Yojson.Safe.t -> (runtime_resolved_snapshot, string) result
(** Strict Runtime-surface slice of [GET /api/v1/runtime/resolved]. Runtime and
    lane identities must be unique, lane candidates must exist, and sticky
    preferred candidate/time fields must be present or absent together.
    Assignment and max-context fields belong to other consumers and are not
    duplicated into this light projection. *)

val decode_runtime_surface_snapshot :
  probe_json:Yojson.Safe.t ->
  resolved_json:Yojson.Safe.t ->
  (runtime_surface_snapshot, string) result
(** Decode and join the two server-owned projections by exact [runtime_id],
    preserving lane and candidate order. Extra probe rows are counted; a lane
    candidate absent from a stale probe remains [None]. *)

val join_runtime_surface :
  probe:runtime_probe_snapshot option ->
  probe_error:string option ->
  resolved:runtime_resolved_snapshot ->
  (runtime_surface_snapshot, string) result
(** Join a decoded resolved document to a current or last-good optional probe.
    A probe error has a smaller failure radius than resolved identity: it is
    carried beside unobserved or preserved probe rows rather than erasing the
    lane table. *)

val decode_repository_snapshot :
  Yojson.Safe.t -> (repository_snapshot, string) result

val decode_harness_snapshot :
  Yojson.Safe.t -> (harness_snapshot, string) result

val decode_verification_snapshot :
  Yojson.Safe.t -> (verification_snapshot, string) result

val decode_system_log_snapshot :
  Yojson.Safe.t -> (system_log_snapshot, string) result

val system_log_level_label : system_log_level -> string
(** Fixed-width label for the level column. *)

val decode_planning_snapshot :
  Yojson.Safe.t -> (planning_snapshot, string) result

val decode_fleet_safety : Yojson.Safe.t -> (fleet_safety, string) result
(** Reads the [keeper_fleet_safety] section out of a [/health?full=1] body.
    A body without the section is an error rather than an empty reading: an
    absent section and a healthy fleet are different facts, and rendering the
    second for the first is how a blocked keeper stays invisible. *)
val parse_log_entry : string -> (log_entry, string) result
val decode_log_entry : Yojson.Safe.t -> (log_entry, string) result
val decode_context_observation :
  expected_trace_id:string ->
  Yojson.Safe.t ->
  (context_observation, string) result
val context_unavailable_reason_to_string : context_unavailable_reason -> string
val is_success_http_status : int -> bool
val decode_json_response_body :
  allow_empty:bool -> status_code:int -> body:string -> (Yojson.Safe.t, string) result

(** The [/api/v1/tools/*] write envelope [{ok, message}] as a one-line
    outcome; a shape the endpoints never send is an error, not a guessed
    success. *)
val tool_envelope_outcome : Yojson.Safe.t -> (string, string) result

(** The [/api/v1/verification/verdict] success envelope
    [{ok; message; noop}] as [(message, noop)]. [noop = true] means the
    verdict already stood and this call changed nothing. Refusals arrive as
    non-2xx statuses and never reach this decoder. *)
val verification_verdict_outcome :
  Yojson.Safe.t -> (string * bool, string) result

(** Decode one SGR mouse report into the [up]/[down] key a wheel turns
    into, or [None] for reports nothing consumes (clicks, releases,
    horizontal wheel). [parameters] is the raw CSI parameter span
    (["<64;10;5"]), [final] the CSI final byte. *)
val sgr_wheel_key : string -> char -> string option

(** Decode the button byte of a legacy X10 mouse report ([CSI M] plus three raw
    bytes) into [wheel-up] / [wheel-down].

    Terminals without SGR ([?1006]) support answer the tracking request in this
    older shape; Apple Terminal, the macOS default, is one. The three bytes
    after [CSI M] must be consumed whatever this returns — left in the stream
    they are read as ordinary text. Buttons other than the two wheel ones
    return [None]. *)
val x10_wheel_key : char -> string option
val required_string_field : Yojson.Safe.t -> string -> (string, string) result
val optional_string_field :
  Yojson.Safe.t -> string -> (string option, string) result
val required_int_field : Yojson.Safe.t -> string -> (int, string) result
val required_display_any_field :
  Yojson.Safe.t -> string list -> (string, string) result
val optional_body_field : Yojson.Safe.t -> (string, string) result
val required_body_field : Yojson.Safe.t -> (string, string) result
val required_list_field :
  Yojson.Safe.t -> string -> (Yojson.Safe.t list, string) result
val optional_list_field :
  Yojson.Safe.t -> string -> (Yojson.Safe.t list, string) result
val required_object_field :
  Yojson.Safe.t -> string -> (Yojson.Safe.t, string) result
val optional_object_field :
  Yojson.Safe.t -> string -> (Yojson.Safe.t option, string) result
val decode_list :
  string -> (Yojson.Safe.t -> ('a, string) result) -> Yojson.Safe.t list -> ('a list, string) result
val bounded_parent_depth :
  ?max_depth:int ->
  id_of:('a -> string) ->
  parent_id_of:('a -> string option) ->
  'a list ->
  'a ->
  int
val parse_keeper_chat_response : string -> (string, string) result

(** {1 Keeper file changes}

    The files a keeper wrote, as [GET /api/v1/keepers/<name>/file-changes]
    answers. See {!Keeper_tool_call_file_change} for what the server projects
    and what it cannot: a change whose arguments outgrew the tool-call log's
    inline budget is counted, not carried. *)

type file_change_location =
  | Fc_in_repo of {
      repo_id : string;
      relative_path : string;
    }
      (** Inside one of the keeper's repository clones. [relative_path] is the
          address the same file has in any other checkout. *)
  | Fc_in_bundle of { bundle_path : string }
      (** Under the keeper's playground and no clone -- a scratch file. *)
  | Fc_at_absolute_path of { path : string }
      (** The write resolver recorded an absolute path: a worktree checked out
          beside the clones, or a write outside any playground. *)

type file_change_kind =
  | Fc_edited of {
      before : string;
      after : string;
      replace_all : bool;
    }
  | Fc_written of { content : string }

type file_change = {
  fc_at : float;
  fc_keeper : string;
  fc_turn : int option;
  fc_task_id : string option;
  fc_location : file_change_location;
  fc_kind : file_change_kind;
  fc_succeeded : bool;
      (** Whether the call reported success. A failed write is still a change
          the keeper attempted. *)
}

type file_change_snapshot = {
  fcs_keeper : string;
  fcs_window_hours : float;
  fcs_calls_in_window : int;
  fcs_changes : file_change list;
  fcs_over_budget : int;
  fcs_malformed : int;
}

val decode_file_change_snapshot :
  Yojson.Safe.t -> (file_change_snapshot, string) result

(** {1 What the tree holds}

    The other half of the diff story. A file change says what a keeper tried
    to write; this says what is actually in the working tree now, and the two
    disagree often enough that merging them would make both untrue.

    The rows arrive already parsed, with the line numbers git computed. That
    is the part the tool-call reading cannot have: an [Edit] records two
    pieces of text and no idea where in the file they sit. *)

(** One node of the workspace tree family
    ([/api/v1/workspace/tree], [/workspace/children]). *)
type workspace_tree_node = {
  wt_path : string;
  wt_label : string;
  wt_has_children : bool;
}

val decode_workspace_tree :
  Yojson.Safe.t -> (workspace_tree_node list, string) result

(** The whole file from [/api/v1/workspace/file]'s [{ok, content}]. *)
val decode_workspace_file : Yojson.Safe.t -> (string, string) result

type git_diff_row_kind =
  | Gd_context
  | Gd_added
  | Gd_removed

type git_diff_row = {
  gdr_kind : git_diff_row_kind;
  gdr_old_line : int option;
      (** Absent on an added line, which exists in no earlier revision. *)
  gdr_new_line : int option;  (** Absent on a removed line. *)
  gdr_text : string;  (** Without git's leading marker column. *)
}

type git_diff = {
  gd_has_changes : bool;
      (** False when the file matches the base ref. Distinct from an empty row
          list caused by a failed read: the caller is told which happened. *)
  gd_rows : git_diff_row list;
}

val decode_git_diff : Yojson.Safe.t -> (git_diff, string) result
(** Reject an unrecognised row kind rather than reading it as context: git's
    vocabulary is closed, so a fourth word means the server changed, and
    drawing it as unchanged would say the opposite of what happened. *)
