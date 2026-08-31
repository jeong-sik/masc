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
  goal_ids : string list;
      (** Goals this task is linked to, from the goal-task registry.
          The task record itself carries no goal: the registry is the source
          of truth, so a screen that reads only the backlog cannot say which
          goal a task serves. Empty when nothing links it, and also empty when
          no link facts were supplied to this projection. A caller that must
          distinguish an empty registry from an unreadable one must retain the
          result of {!Workspace_goal_index.read_goal_task_links_r} beside this
          projected field. *)
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
  pg_last_review_at : string option;
  pg_created_at : string option;
  pg_updated_at : string option;
      (** Server timestamps (RFC 3339). Optional: an older server build may
          not emit them, and the TUI renders what is there rather than
          refusing the goal. *)
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
  sl_category : string option;
      (** The producer's typed category, as its wire string ([Null] rows carry
          none). The vocabulary is the server's closed set; this reader keeps
          whatever spelling arrives rather than mirroring that set. *)
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

type effective_tool = {
  et_name : string;
  et_origin : string;
  et_group : string option;
  et_skill_source : string option;
}

type effective_tool_delivery =
  | Effective_tools_delivered
  | Effective_tools_suppressed_runtime_unsupported

type skill_flow_dependency = {
  sfd_node_id : string;
  sfd_kind : string;
}

type skill_flow_node = {
  sfn_id : string;
  sfn_tool_name : string;
  sfn_dependencies : skill_flow_dependency list;
  sfn_batch_index : int;
  sfn_execution_mode : string;
}

type skill_flow_batch = {
  sfb_index : int;
  sfb_execution_mode : string;
  sfb_node_ids : string list;
}

type skill_flow = {
  sf_nodes : skill_flow_node list;
  sf_batches : skill_flow_batch list;
}

type skill_usage_row = {
  su_keeper : string;
  su_invocations : int;
  su_deliveries : int;
  su_actions : int;
  su_last_used_at : string option;
}

type skills_catalog_surface = {
  scs_name : string;
  scs_kind : string;
  scs_usage : skill_usage_row list;
  scs_flow : skill_flow option;
}

type skill_rejection_diagnostic = {
  srd_diagnostic : Agent_core.Skill_document.diagnostic;
  srd_message : string;
}

type skill_rejection_reason =
  | Skill_document_rejected of skill_rejection_diagnostic list
  | Skill_document_unreadable
  | Skill_exact_identity_duplicate
  | Skill_invalid_package_id

type skill_catalog_rejection = {
  scr_source_index : int;
  scr_source_id : string;
  scr_package_id : string option;
  scr_content_revision : string option;
  scr_reason : skill_rejection_reason;
}

type skills_catalog_state =
  | Skills_ready
  | Skills_not_registered
  | Skills_uninitialized
  | Skills_invalid_workspace

type skills_catalog = {
  sc_state : skills_catalog_state;
  sc_surfaces : skills_catalog_surface list;
  sc_rejections : skill_catalog_rejection list;
}

val skills_catalog_state_to_string : skills_catalog_state -> string
val skill_diagnostic_code_to_string :
  Agent_core.Skill_document.diagnostic -> string

type effective_skill_load_reason =
  | Skill_catalog_default
  | Skill_keeper_profile
  | Skill_task of string

type effective_skill_profile = {
  esp_reference : Skill_reference.t;
  esp_name : string;
  esp_kind : string;
  esp_execution : string;
  esp_body_bytes : int;
  esp_discovery_bytes : int;
  esp_load_reasons : effective_skill_load_reason list;
  esp_node_count : int;
  esp_batch_count : int;
  esp_max_parallelism : int;
  esp_flow : skill_flow option;
}

type effective_tool_surface =
  | Effective_surface_available of {
      ets_keeper_name : string;
      ets_runtime_id : string;
      ets_official_client_kind : string;
      ets_tool_delivery : effective_tool_delivery;
      ets_native_posture : string option;
      ets_skill_snapshot_revision : string;
      ets_skill_resource_read_max_bytes : int option;
      ets_instruction_skills : Skill_reference.t list;
      (* Documents the catalog could not read. Beside the skills rather than
         missing from them: a skill left out is absent from what the Keeper
         can call, and absence with no reason reads as a skill nobody
         wrote. *)
      ets_skills_left_out : string list;
      ets_composition_skills : Skill_reference.t list;
      ets_skill_profiles : effective_skill_profile list;
      ets_tool_surface_bytes : int;
      ets_skill_tool_surface_bytes : int;
      ets_skill_discovery_bytes : int;
      ets_skill_eager_body_bytes : int;
      ets_skill_body_bytes : int;
      ets_tools : effective_tool list;
      ets_tool_surface_sha256 : string option;
    }
  | Effective_surface_unavailable of {
      ets_keeper_name : string;
      ets_reason : string;
      ets_detail : string;
    }
  | Effective_surface_warming of { ets_keeper_name : string }

type skill_activation_projection =
  | Skill_activations_available of {
      sap_keeper_name : string;
      sap_ledger : Keeper_skill_activation_ledger.t;
    }
  | Skill_activations_no_session of { sap_keeper_name : string }
  | Skill_activations_unavailable of {
      sap_keeper_name : string;
      sap_reason : string;
      sap_detail : string;
    }

type tool_snapshot = {
  ts_tools : tool_entry list;
  ts_count : int;
  ts_freshness : inventory_freshness;
      (** Whether the count above is an answer. *)
  ts_effective : effective_tool_surface option;
  ts_skill_activations : skill_activation_projection option;
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
val runtime_probe_status_of_string :
  string -> (runtime_probe_status, string) result
(** The probe's own status, as [Server_dashboard_http_runtime_info] writes it:
    the live summary picks between ["ok"], ["idle"], ["degraded"] and
    ["unavailable"], the failure envelope writes ["unreachable"], and the
    cold-start envelope writes ["warming_up"].

    Exported so the contract can be pinned against that list. It drifted from
    it once -- this read ["reachable"] and ["no_http_runtimes"], which nothing
    writes, so every live response failed to decode and the Runtime surface
    drew every candidate as unobserved. *)

val runtime_probe_status_to_string : runtime_probe_status -> string
(** The word the wire uses, so a badge drawn from this names the reading the
    server named. Many-to-one: ["unavailable"] and ["unreachable"] read as one
    status and write back as ["unreachable"]. *)
val runtime_provider_status_to_string : runtime_provider_status -> string

(** A repository the workspace tracks. *)
type repository = {
  rp_id : string;  (** what the workspace routes' [?repo_id=] resolves *)
  rp_name : string;
  rp_codebase : string option;
      (** the server-minted slug the IDE annotation routes scope by;
          [None] when the remote cannot canonicalize *)
  rp_url : string;  (** the remote as registered, for building links *)
  rp_local_path : string;
      (** the path spelling persisted in repositories.toml; it may be
          relative to the workspace base path *)
  rp_resolved_local_path : string;
      (** the server-resolved absolute checkout path used for file and Git
          operations; clients display this value instead of guessing against
          their own cwd *)
  rp_default_branch : string;
  rp_status : string;
  rp_keepers : string list;  (** Which keepers work in it. *)
  rp_auto_sync : bool;
}

type repository_snapshot = {
  rs_repositories : repository list;
  rs_total : int;
}

type repository_change = {
  rc_path : string;
  rc_staged : bool;
  rc_unstaged : bool;
  rc_untracked : bool;
  rc_conflicted : bool;
}

type repository_change_scope =
  | Repository_change_project
  | Repository_change_repository of string

type repository_change_snapshot = {
  rcs_scope : repository_change_scope;
  rcs_changes : repository_change list;
  rcs_total : int;
}

type memory_alert = {
  ma_code : string;
  ma_severity : string;
  ma_label : string;
  ma_message : string;
}

type memory_keeper_health = {
  mkh_keeper_id : string;
  mkh_revision : int;
  mkh_facts : int;
  mkh_snapshot_bytes : int;
  mkh_added : int;
  mkh_removed : int;
  mkh_snapshot_present : bool;
  mkh_librarian_lane_busy : int;
  mkh_librarian_failures : int;
  mkh_read_error : string option;
  mkh_alerts : memory_alert list;
}

type memory_health_snapshot = {
  mhs_generated_at : float;
  mhs_keepers : memory_keeper_health list;
  mhs_total_facts : int;
  mhs_total_snapshot_bytes : int;
  mhs_total_librarian_failures : int;
  mhs_total_read_errors : int;
  mhs_warn_alerts : int;
  mhs_error_alerts : int;
  mhs_starving_keepers : int;
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
  hv_notes_hash : string;  (** joins an operator label to this verdict *)
      (** Why the named evaluator did not run, when something else did. A
          verdict reached by a fallback is not the verdict that was asked for,
          and the surface says so rather than showing them alike. *)
}

(** What the judge has decided over its whole life, not the page of it the
    pane draws. The screen said "(8 verdicts)" while the server was reporting
    4,197 -- the eight are the recent page, and every rate a reader would
    weigh is computed over the rest. *)
type harness_calibration = {
  hcal_total : int;
  hcal_approve : int;
  hcal_reject : int;
  hcal_labeled : int;
      (** Verdicts a person has labelled. Zero means the agreement rate and
          the false-positive and false-negative counts beside it have no
          ground truth to be computed against -- not that they are zero. The
          pane must say which of those two it is. *)
  hcal_gates : (string * int) list;
      (** Which gate produced each verdict, highest count first. This is what
          the surface exists to answer -- its own opening line promises to
          say where a fallback answered instead of the evaluator -- and it
          was the field the pane did not read. *)
}

type harness_overview = {
  hov_evaluator_status : string;
  hov_last_signal_at : float option;
}

type harness_snapshot = {
  hs_verdicts : harness_verdict list;  (** newest first, as the server sends *)
  hs_calibration : harness_calibration option;
      (** [None] when the server did not send the section, which an older
          build does; the pane draws the page alone rather than zeroes. *)
  hs_overview : harness_overview option;
}

(** One task waiting on a verdict, as the verification surface lists it. *)
type verification_request = {
  vr_request_id : string;
  vr_task_id : string;
  vr_task_title : string;
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

val keeper_phase_is_running : keeper_phase -> bool
(** Whether the phase is the normal running lifecycle. The Keepers table
    silences the word for it and spells out every other phase; exhaustive in
    the implementation so a new phase cannot silently count as not-running. *)

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
  kr_sandbox_profile : string;
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

(** Read-only standalone LLM lane observation. These rows describe existing
    admission and run registries; they never carry a control action. *)
type standalone_lane_status =
  | Standalone_running
  | Standalone_idle
  | Standalone_degraded
  | Standalone_no_retained_observation
  | Standalone_unavailable

type standalone_lane_slot_count = {
  slsc_slot_id : string;
  slsc_count : int;
}

type standalone_lane = {
  sl_lane_id : string;
  sl_label : string;
  sl_required : bool;
  sl_status : standalone_lane_status;
  sl_configuration_state : string;
  sl_admitted_slots : string list;
  sl_cli_slots : string list;
  sl_dropped_slots : string list;
      (** Slot ids the lane declared that publication could not admit — the
          per-lane answer to "configured single, or configured double with
          one silently dropped". *)
  sl_admission_error : string option;
  sl_retained_run_count : int;
  sl_running_count : int;
  sl_succeeded_count : int;
  sl_failed_count : int;
  sl_cancelled_count : int;
  sl_last_started_at : float option;
  sl_last_terminal_at : float option;
  sl_last_outcome : string option;
  sl_p50_elapsed_s : float option;
  sl_selected_slots : standalone_lane_slot_count list;
}

type standalone_lanes_snapshot = {
  sls_observed_at_unix : float;
  sls_exact_run_projection_count : int;
  sls_exact_run_source_total : int;
  sls_exact_run_projection_truncated : bool;
  sls_lanes : standalone_lane list;
}

val standalone_lane_status_to_string : standalone_lane_status -> string
val decode_standalone_lanes_snapshot :
  Yojson.Safe.t -> (standalone_lanes_snapshot, string) result

(** What the secret projection reports for one Keeper. The producer computes
    this from the directory: [Secret_absent] when no root is configured,
    [Secret_empty] when a configured root holds nothing, [Secret_ready] when
    it holds entries, and [Secret_error] when the root could not be read.

    [Secret_status_unknown] keeps a word this reader does not know rather
    than folding it into one of the four. A projection whose status the
    screen cannot name is a different fact from one that is absent, and the
    operator is the one who needs to see which. *)
type keeper_secret_status =
  | Secret_ready
  | Secret_empty
  | Secret_absent
  | Secret_error
  | Secret_status_unknown of string

val keeper_secret_status_to_string : keeper_secret_status -> string

(** One Keeper's credential surface, as the composite endpoint reports it.

    Values never appear here: the producer sends names, counts and a
    validation flag, and this reads exactly that. A screen built on this
    cannot show a secret by accident because it never holds one. *)
type keeper_secret_projection = {
  ksp_keeper : string;
  ksp_status : keeper_secret_status;
  ksp_root : string;
  ksp_env_names : string list;
  ksp_file_paths : string list;  (** container-side mount paths *)
  ksp_values_validated : bool;
  ksp_error : string option;
}

val decode_keeper_secret_projections :
  Yojson.Safe.t -> (keeper_secret_projection list, string) result
(** Read every Keeper's secret projection out of the same
    [GET /api/v1/keepers/composite] body the Lanes table reads. A snapshot
    without a [secret_projection] object is skipped rather than rejected:
    the endpoint serves several screens and a Keeper the producer has not
    projected yet is absence, not a malformed reading. *)

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
    clock's epoch reading when the wait opened. [kta_because], when
    present, is the policy's one-line reason for asking — for a composition
    it is the only place the node that caused the ask is named. Older servers
    may omit it, in which case the value is [None]. *)
type keeper_tool_approval = {
  kta_keeper : string;
  kta_tool_call_id : string;
  kta_tool : string;
  kta_args : string;
  kta_question : string;
  kta_because : string option;
  kta_asked_at : float;
  kta_timeout_sec : float;
}

val decode_keeper_gate_settings :
  Yojson.Safe.t -> ((string * string) list * (string * string) list, string) result
(** [(keeper, mode) list, (keeper, slot_id) list] from
    [/api/v1/dashboard/gate/keeper-settings].

    Distinct from {!decode_tool_approval_mode_overrides}: that one is the
    in-memory YOLO stance a restart clears, this is what the Gate decides an
    external effect under. Two per-Keeper settings with similar names, and an
    operator reading one for the other is the reason both are named in
    full. *)

type runtime_param_row =
  { rpr_key : string
  ; rpr_current_json : string
  ; rpr_default_json : string
  ; rpr_has_override : bool
  ; rpr_description : string
  ; rpr_value_type : string
  ; rpr_min_json : string option
  ; rpr_max_json : string option
  }

val decode_runtime_params :
  Yojson.Safe.t -> (runtime_param_row list, string) result
(** Typed display/edit rows from [/api/v1/runtime/params].

    Current and default use their exact JSON spelling.  The TUI displays a
    friendly form but keeps this spelling for the inline edit/write boundary,
    so a JSON string cannot be confused with a number or boolean.  Registry
    metadata stays attached so the selected row can explain its type, bounds,
    and purpose before an operator changes it. *)

val decode_tool_approval_mode_overrides :
  Yojson.Safe.t -> ((string * string) list, string) result
(** Decode [GET /api/v1/keepers/tool-approval-mode]'s
    [{overrides: [{keeper, mode}]}] into (keeper, mode) pairs. *)

type gate_pending_phase =
  | Gate_queued
  | Gate_judging
  | Gate_human_required
  | Gate_blocked
(** Operator-facing phase projected from the durable Auto Judge summary and
    exact-attempt state. This distinguishes model work from terminal human
    handoff and failed automation; all four remain nonblocking to the Keeper. *)

type gate_pending = {
  gp_id : string;
  gp_keeper : string;
  gp_operation : string;
      (** The closed operation identity the Gate stored, e.g.
          [identity_call]. *)
  gp_display_tool : string;
      (** What a human decides on: for an identity call, the provider and
          the remote tool name read out of the stored input; otherwise the
          operation itself. *)
  gp_input_preview : string option;
      (** What the row shows about the request. A [tool_execute] row shows the
          command it would run, read out of the arguments the producer stored;
          every other operation, and any shape this does not recognise, shows
          the server's flattened preview. *)
  gp_execution_cwd : string option;
      (** The working directory a [tool_execute] request would run in.
          [None] for operations that carry no execution context. *)
  gp_execution_sandbox : string option;
      (** Where a [tool_execute] request would run -- [host], or the container
          it was granted against. The command alone does not say this, and it
          changes what the command means. *)
  gp_waiting_s : float option;
  gp_phase : gate_pending_phase;
}

type gate_lane_modes = {
  glm_workspace : string;
  glm_external : string;
      (** The external-services lane. A separate switch from the workspace
          lane: opening one does not open the other. *)
}

(** An always-allow rule standing behind the queue. It answers a request
    before it ever becomes a pending ask, so a screen that shows only the
    queue shows nothing once a rule covers a call. The fingerprint is the
    whole match: one Keeper, one tool, one exact input shape. *)
type gate_rule = {
  gr_id : string;
  gr_keeper : string;
  gr_tool : string;
  gr_fingerprint : string;
  gr_created_at : float;
  gr_created_by : string option;
  gr_expires_at : float option;
}

type gate_snapshot = {
  gs_pending : gate_pending list;
  gs_modes : gate_lane_modes option;
  gs_queue_unavailable : string option;
  gs_rules : gate_rule list;
      (** Standing always-allow rules, newest first, as the server sorted
          them. Empty when none are stored. *)
  gs_rules_unavailable : string option;
      (** [Some detail] when the server reported the rule store unreadable —
          the screen must not read that as "no standing rules". *)
      (** [Some detail] when the server reported the approval-queue store
          unreadable ([approval_queue_state.state] other than ready) — the
          screen must not read that as "no pending approvals". *)
}

val decode_gate_snapshot : Yojson.Safe.t -> (gate_snapshot, string) result
(** Decode [GET /api/v1/dashboard/gate] down to what the Approvals surface
    draws: the durable pending queue and the two Gate lanes. A [null] queue
    (store unavailable) is an empty list beside whatever the lanes say, the
    same face the dashboard shows. *)

val decode_keeper_tool_approvals :
  Yojson.Safe.t -> (keeper_tool_approval list, string) result
(** Decode the [{pending: [...]}] listing, oldest first, rejecting rows with
    missing or mistyped fields rather than dropping them. *)

type keeper_turn_lane =
  | Turn_lane_autonomous
  | Turn_lane_chat_operation
  | Turn_lane_maintenance

type keeper_turn_preview = {
  ktp_text_tail : string;
      (** Tail of the newest response text this turn has produced. *)
  ktp_current_tool : string option;
      (** The most recent tool call the turn ran, when any. *)
}

type keeper_turn_state =
  | Keeper_turn_idle
  | Keeper_turn_running of {
      lane : keeper_turn_lane;
      started_at_unix : float;
      preview : keeper_turn_preview option;
    }
      (** [started_at_unix] is the server owner clock's epoch reading; derive
          display age against the local clock, never trust a precomputed one.
          [preview] is the live glance an older server does not send. *)
  | Keeper_turn_unavailable of string
      (** The owner registry could not answer for this keeper — distinct from
          idle so the badge never reads "not running" out of a lookup error. *)

type keeper_turn_row = {
  ktr_keeper_name : string;
  ktr_state : keeper_turn_state;
}

val decode_keeper_turns :
  Yojson.Safe.t -> (keeper_turn_row list, string) result
(** Decode [GET /api/v1/keepers/turns] ([masc.keeper_turns.v1]): one row per
    registered keeper. Unknown schema, status, or lane is an error, not a
    silently defaulted row. *)

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
  sid_executable_in_worktree : bool option;
      (** Whether the server's executable resolved inside [.worktrees/]
          (health [build.executable_in_worktree]). [None] on an older server
          that does not carry the field — unknown, so no warning and no
          all-clear. *)
}
(** Which server the TUI is talking to, as [/health] reports it.

    The footer said [Port: 8935] and nothing else, so two checkouts serving
    on the same port were indistinguishable from the screen -- and a binary
    older than the tree it was built from looked exactly like a current one.
    [sid_binary_commit_age_s] is how long ago that binary's commit landed,
    which is the number that separates the two. *)

val decode_server_identity : Yojson.Safe.t -> (server_identity, string) result

type prompt_row = {
  pr_key : string;
  pr_category : string;
  pr_description : string;
  pr_effective : string;
      (** What a turn actually gets: the override when there is one, the file
          otherwise. This is the text an editor should open. *)
  pr_has_override : bool;
      (** Whether the effective text came from an override rather than the
          file. The two are different facts: an operator editing an
          overridden prompt is editing the override, and clearing it returns
          the file's words rather than emptying the prompt. *)
  pr_file_exists : bool;
  pr_file_path : string;
  pr_source : string;
  pr_template_variables : string list;
}

type prompts_snapshot = { ps_rows : prompt_row list }
(** GET /api/v1/prompts. *)

val decode_prompts : Yojson.Safe.t -> (prompts_snapshot, string) result

val decode_latest_librarian_run_id : Yojson.Safe.t -> (string, string) result
(** Read the first Librarian row from the newest-first exact-lane summary. The
    summary has no payload; callers use this id for one lazy detail read. *)

type librarian_run_page =
  { lrp_run_id : string option
  ; lrp_next : (float * string) option
  }

val decode_librarian_run_page : Yojson.Safe.t -> (librarian_run_page, string) result
(** One cursor page of exact-lane summaries. [lrp_next] is present only when
    the server says older rows exist, so a client can search through the full
    retained registry without assuming the newest page contains a Librarian. *)

val decode_librarian_actual_input :
  run_id:string -> Yojson.Safe.t -> (string list, string) result
(** Read [run.input.payload.actual_input] from one exact-lane detail response,
    prefixed with the run/actor/status identity the TUI displays above it. *)

(* One exact-lane run as the paged listing serves it: identity and outcome,
   never the payloads. Completion fields are absent while the run is still
   running. *)

(* The producer's [Exact_lane_run_registry.status_label] vocabulary as a
   variant; an unrecognized label keeps its text under [Lane_run_other]. *)
type lane_run_status =
  | Lane_run_running
  | Lane_run_succeeded
  | Lane_run_cancelled
  | Lane_run_failed
  | Lane_run_completion_persistence_failed
  | Lane_run_completion_durability_unknown
  | Lane_run_other of string

val lane_run_status_label : lane_run_status -> string

type lane_run_summary =
  { lrs_run_id : string
  ; lrs_lane : string
  ; lrs_actor : string
  ; lrs_started_at : float
  ; lrs_status : lane_run_status
  ; lrs_elapsed_s : float option
  ; lrs_selected_slot : string option
  }

type lane_run_page =
  { lrpg_runs : lane_run_summary list
  ; lrpg_next : (float * string) option
  }

type lane_run_detail =
  { lrd_run_id : string
  ; lrd_lane : string
  ; lrd_actor : string
  ; lrd_started_at : float
  ; lrd_status : lane_run_status
  ; lrd_elapsed_s : float option
  ; lrd_selected_slot : string option
  ; lrd_input_payload : Yojson.Safe.t
  ; lrd_output : Yojson.Safe.t option
  }

val decode_lane_run_page :
  lane:string -> Yojson.Safe.t -> (lane_run_page, string) result
(** One cursor page of exact-lane summaries, filtered to [lane]. [lrpg_next]
    is the page cursor of the unfiltered page, so paging does not stall on a
    page where the lane has no runs. *)

val decode_lane_run_detail : Yojson.Safe.t -> (lane_run_detail, string) result
(** The whole record of one exact-lane run, [input.payload] and [output]
    included; [lrd_output] is [None] while the run is still running. *)

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
  | Context_conversation_cumulative_usage of
      { raw_input_tokens : int option
      ; context_window : int option
      }
  | Context_usage_scope_unavailable of
      { raw_input_tokens : int option
      ; context_window : int option
      }
  | Context_tokens_exceed_window of
      { raw_input_tokens : int
      ; context_window : int
      }

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
val task_of_domain : ?goal_ids:string list -> Masc_domain.task -> task

val active_tasks_of_domain
  :  ?goals_for_task:(string -> string list)
  -> Masc_domain.task list
  -> task list
(** [goals_for_task] answers which goals a task id is linked to. Omitted, every
    task comes back with no goals -- which is what a caller that has not read
    the goal-task registry can honestly say.

    Rows come back grouped by their first linked goal, clusters ordered by the
    best priority inside each cluster, goalless rows after goal-linked ones on
    ties, then priority and id inside a cluster. The list stays flat: grouping
    is adjacency, not header rows, so a cursor over it needs no new
    arithmetic. *)
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

val decode_skills_catalog : Yojson.Safe.t -> (skills_catalog, string) result
(** Reads the /api/v1/skills snapshot: per-skill usage rows and flows. *)

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

val decode_repository_change_snapshot :
  Yojson.Safe.t -> (repository_change_snapshot, string) result

val decode_memory_health_snapshot :
  Yojson.Safe.t -> (memory_health_snapshot, string) result
(** Decode the fleet memory-health snapshot served at
    [/api/v1/dashboard/keeper-memory-health]. Every consumed field is
    required: a keeper the server left out is invisible here, not defaulted. *)

val decode_harness_snapshot :
  Yojson.Safe.t -> (harness_snapshot, string) result

val decode_verification_snapshot :
  Yojson.Safe.t -> (verification_snapshot, string) result

val decode_system_log_snapshot :
  Yojson.Safe.t -> (system_log_snapshot, string) result

val system_log_level_label : system_log_level -> string
(** Fixed-width label for the level column. *)

val system_log_categories : system_log_entry list -> string list
(** The distinct categories the given rows carry, sorted. The filter's
    vocabulary is what the page actually shows, never a copy of the server's
    category set. *)

val next_system_log_category :
  current:string option -> system_log_entry list -> string option
(** One step of the category cycle: [None] -> first -> ... -> last -> [None].
    A [current] the rows no longer carry steps to [None]. *)

val next_system_log_min_level :
  system_log_level option -> system_log_level option
(** One step of the verbose ladder: [None] (server default, everything) ->
    info -> warn -> error -> [None]. *)

val system_log_level_query : system_log_level -> string
(** The lowercase spelling the [/api/v1/dashboard/logs] route validates. *)

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

(** Decode one SGR mouse report into the [(row, column)] of an unmodified
    left-button press (button [0], final [M]), 1-based as the terminal
    reports it. Releases, modifier chords, drags and wheel reports return
    [None] — acting on those would double-fire or claim a gesture nobody
    meant. *)
val sgr_left_press : string -> char -> (int * int) option

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
  fc_execution_id : string option;
      (** Canonical physical-execution identity. A chat activity may join a
          change only through this field, never through provider call ids. *)
  fc_line_evidence : Keeper_file_change_evidence.t option;
      (** Producer-owned actual line ranges from this execution. [None] is an
          older row, not permission to rediscover coordinates from text. *)
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

val file_change_target_line : file_change -> int
(** Exact producer-recorded line to open. A deletion opens at its old start,
    which is the post-edit position of the following line. Historical,
    empty, and range-omitted rows return line 1 rather than searching current
    file text for a plausible duplicate. *)

val decode_file_change_snapshot :
  Yojson.Safe.t -> (file_change_snapshot, string) result
(** Decode one Keeper-stamped snapshot. Every inner change must carry the same
    Keeper identity; a mixed response is rejected rather than indexed under
    the top-level name. *)

(** {1 What the tree holds}

    The other half of the diff story. A file change says what a keeper tried
    to write; this says what is actually in the working tree now, and the two
    disagree often enough that merging them would make both untrue.

    The rows arrive already parsed, with per-row line numbers git computed for
    the current tree. A successful tool-call reading may carry the producer's
    recorded old/new ranges, but it is not a later git-tree observation. *)

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

(** One [/api/v1/git/log] commit: hash, author-time epoch milliseconds,
    author, subject. *)
type git_log_row = {
  gl_hash : string;
  gl_at_ms : float;
  gl_author : string;
  gl_subject : string;
}

val decode_git_log : Yojson.Safe.t -> (git_log_row list, string) result
(** The route's [{ok; commits}] envelope, most recent first. *)

(** One [/api/v1/ide/annotations] note: where it anchors, who left it, the
    server's kind word, and what it says. *)
type ide_annotation = {
  ia_line_start : int;
  ia_line_end : int;
  ia_keeper : string;
  ia_kind : string;
  ia_content : string;
  ia_task : string option;
}

val decode_ide_annotations :
  Yojson.Safe.t -> (ide_annotation list, string) result
(** The route's [{ok; data}] envelope. *)

(** The [/api/v1/lsp/question] answer: where a name is defined (1-based,
    workspace-relative when inside), or what the server says it is. *)
type lsp_location = {
  ll_path : string;
  ll_inside : bool;
  ll_line : int;
}

type lsp_answer =
  | Lsp_locations of lsp_location list
  | Lsp_hover of string option

val decode_lsp_answer : Yojson.Safe.t -> (lsp_answer, string) result

(** {1 Questions a Keeper put to the operator}

    Decoded from [GET /api/v1/keepers/asks]. The rows carry choice ids
    alongside labels and the answer POST takes ids back, so a surface built on
    these types never matches on label text: rewording a choice cannot orphan
    an answer already recorded. *)

type ask_choice = {
  ac_id : string;  (** what an answer names; never the label *)
  ac_label : string;
  ac_description : string option;
}

type ask_mode =
  | Ask_single
  | Ask_multi

type ask_free_text =
  | Ask_free_text_allowed of { aft_hint : string option }
  | Ask_choices_only

type ask_question = {
  aq_id : string;
  aq_header : string;  (** two or three words; what a narrow row shows *)
  aq_prompt : string;
  aq_mode : ask_mode;
  aq_free_text : ask_free_text;
  aq_choices : ask_choice list;
}

type ask_resolution =
  | Ask_open
  | Ask_answered of {
      aa_answered_at : float;
      aa_question_ids : string list;
    }
  | Ask_withdrawn of {
      aw_reason : string;
      aw_withdrawn_at : float;
    }

type ask_row = {
  ar_keeper : string;
  ar_id : string;
  ar_asked_at : float;
  ar_context : string option;
      (** why the Keeper is asking, in its own words. A row that hides this
          reads as a decision with no stakes. *)
  ar_questions : ask_question list;
  ar_resolution : ask_resolution;
}

type asks_snapshot = {
  asn_keeper : string option;
  asn_open_count : int;  (** the server's count, not [List.length asn_rows] *)
  asn_rows : ask_row list;
}

val decode_asks_snapshot : Yojson.Safe.t -> (asks_snapshot, string) result
(** A row whose mode or free-text shape is unknown fails the decode rather
    than defaulting: a surface that guessed would offer the operator a control
    the server will refuse. *)

type goal_timeline_event = {
  gt_ts : string;
  gt_kind : string;
  gt_lane : string;
      (** The row's subject as a typed reference: ["task:task-1013"],
          ["approval:appr-…"], ["keeper:<name>"], ["goal"]. *)
  gt_title : string;
  gt_summary : string;
  gt_severity : string;  (** producer emits ok | warn | bad; open for renderers *)
}

(** Goal detail timeline. [`Null] from the server means the approval-queue
    store could not be read (the same discriminated failure the gate snapshot
    carries), so it decodes to the explicit unavailable constructor, never an
    empty list. *)
type goal_timeline =
  | Goal_timeline_ready of goal_timeline_event list
  | Goal_timeline_unavailable of string

val decode_goal_detail_timeline : Yojson.Safe.t -> (goal_timeline, string) result

type task_history_event = {
  th_ts : string;
  th_label : string;  (** [action] when present, else [type], else "event" *)
  th_from_status : string option;
  th_to_status : string option;
  th_actor : string option;
  th_note : string option;  (** handoff_context.summary when present *)
}

val decode_task_history : Yojson.Safe.t -> (task_history_event list, string) result
(** Rows are raw event-stream lines rather than a uniform projection, so every
    field except [ts] is tolerant; an unknown event type renders as its type
    string instead of being dropped. *)

(** Operator evidence bundle for one awaiting-verification task. The item
    vocabulary is the producer's closed set, so an unknown kind fails the
    decode rather than rendering as an empty row; [Evidence_access_unavailable]
    is the store-level failure the server states explicitly. *)
type verification_evidence_item =
  | Ev_note of string
  | Ev_artifact of {
      ev_reference : string;
      ev_content : string;
      ev_bytes : int;
      ev_truncated : bool;
    }
  | Ev_artifact_unreadable of {
      ev_u_reference : string option;
      ev_u_reason : string;
    }

type verification_evidence =
  | Evidence_items of verification_evidence_item list
  | Evidence_access_unavailable of string

val decode_verification_evidence :
  Yojson.Safe.t -> (verification_evidence, string) result

(** Strict hard-cut decoder for [/api/v1/skills/evidence]. The endpoint's
    current projection is explicitly incomplete; missing or weakened coverage
    fields are rejected instead of becoming zeroes in the terminal. *)
type skill_evidence_status =
  | Skill_evidence_observed
  | Skill_evidence_not_observed_in_retained_coverage

type skill_evidence_composition_scope =
  | Skill_evidence_exact_reference_latest_completed
  | Skill_evidence_composition_unavailable

type skill_evidence_coverage =
  { sec_composition_scope : skill_evidence_composition_scope
  ; sec_composition_records_read : int
  ; sec_composition_unavailable : string list
  ; sec_activation_scope : string
  ; sec_activation_sessions_inspected : int
  ; sec_activation_ledgers_loaded : int
  ; sec_activation_gap_count : int
  ; sec_activation_owner_gap_count : int
  }

type skill_evidence_owner_claim =
  { seo_keeper : string
  ; seo_source : string
  }

type skill_evidence_activation_item =
  { sea_trace_id : string
  ; sea_owner_status : string
  ; sea_owner_claims : skill_evidence_owner_claim list
  ; sea_owner_gap_count : int
  ; sea_activation : Yojson.Safe.t
  }

type skill_evidence_activation =
  | Skill_evidence_most_recent_observed of skill_evidence_activation_item
  | Skill_evidence_most_recent_observed_timestamp_tie of
      skill_evidence_activation_item list

type skill_evidence =
  { se_status : skill_evidence_status
  ; se_activation : skill_evidence_activation option
  ; se_composition : Yojson.Safe.t option
  ; se_coverage : skill_evidence_coverage
  }

val decode_skill_evidence : Yojson.Safe.t -> (skill_evidence, string) result
