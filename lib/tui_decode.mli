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

type keeper_origin =
  | Persisted_keeper
  | Declared_keeper of Keeper_declared_roster.requirement list
  | Remote_keeper

type keeper_identity = {
  k_trace_id : string;
  k_created_at : string;
  k_updated_at : string;
}

type keeper_activity = {
  k_current_task_id : string option;
  k_total_turns : int;
  k_total_tokens : int;
  k_total_cost_usd : float;
  k_last_turn_ts : string;
  k_last_proactive_outcome : Keeper_meta_contract.proactive_cycle_outcome option;
      (** What the last proactive cycle came to, as the contract types it.
          Kept typed so
          the screen names it in words: as a string it was the wire token
          ("never_started"), the one spelling no surface uses. *)
}

type keeper = {
  k_origin : keeper_origin;
  k_name : string;
  k_paused : bool;
  k_identity : (keeper_identity, string) result;
      (** A metadata failure withdraws trace attribution and timestamps, not
          the independently observed Keeper name or lifecycle controls. *)
  k_activity : keeper_activity option;
      (** The public roster does not publish lifetime usage or current task.
          Absence is an unavailable observation, never a zero measurement. *)
}

val keeper_trace_id : keeper -> (string, string) result
(** Trace identity or the original metadata failure. *)

type keeper_trace_projection = {
  bindings : (string * string) list;
  unavailable : (string * string) list;
}
(** Independently readable identities and named failures, in roster order.
    Failed identities never supply a correlation binding. *)
val keeper_trace_projection : keeper list -> keeper_trace_projection

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
  | Proof_stale of string option
  | Proof_unreadable of string option
      (** The ledger did not decode, or named a state this build does not know.
          Distinct from {!Proof_idle}: an unreadable store is not the same fact
          as an unreviewed goal, and showing it as "not reviewed" would
          disguise corruption as quiet. *)

type verifier_unreconciled = {
  vu_step : Goal_reconcile_step.t;
  vu_detail : string;
}
(** The latest verifier scan could not settle this Verifying goal. It stays
    Verifying until [request_complete] retries it or a later scan settles it,
    or the operator takes it back or drops it. *)

type planning_goal = {
  pg_id : string;
  pg_criterion_revision : string option;
  pg_title : string;
  pg_phase : Goal_phase.t;
  pg_priority : int;
  pg_due_date : string option;
  pg_metric : string option;
  pg_target_value : string option;
  pg_proof : goal_proof;
  pg_verifier_unreconciled : verifier_unreconciled option;
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
  pr_awaiting_confirmation : int;
  pr_done : int;
  pr_dropped : int;
}

type planning_backlog = {
  pb_todo : int;
  pb_claimed : int;
  pb_running : int;
  pb_awaiting_verification : int;
  pb_done : int;
  pb_cancelled : int;
}

(** One goal the event log remembers that [goals.json] no longer lists, as
    [GET /api/v1/dashboard/planning] reports it under [goal_history.unlisted].
    Every field past the id is nullable on the wire and stays optional here: a
    goal opened before the server recorded openings has no [pgh_opened_at], and
    one that left the list without a terminal phase has no [pgh_closed_at].
    Reading either as a zero would date something that never happened. *)
type planning_goal_history = {
  pgh_goal_id : string;
  pgh_title : string option;
  pgh_opened_at : string option;
  pgh_closed_at : string option;
  pgh_final_phase : string option;
  pgh_lifetime_hours : float option;
}

type planning_snapshot = {
  pl_goals : planning_goal list;
  pl_rollup : planning_rollup;
  pl_backlog : planning_backlog;
  pl_goal_history : planning_goal_history list;
  pl_generated_at : string;
}

(** The RFC-0444 Goal store envelope
    [{ok:false, error_code:"goal_store_unavailable", reason, field, file,
    mirror:{status, goal_count}, reset_step}] as the TUI reads it. [reason]
    and [mirror] are views: the wire carries the constructor name, the refused
    member and the mirror's row count, not the Unix error, parse detail or
    mirror stamp the store keeps beside them. The reset step travels whole. *)
type goal_store_unavailable_reason_view =
  | Missing_after_init_view
  | Unreadable_view
  | Not_json_view
  | Schema_rejected_view of string  (** The refused member (wire [field]). *)

type goal_store_mirror_view =
  | Mirror_absent_view
  | Mirror_unreadable_view
  | Mirror_decodes_view of int  (** The mirror's goal count. *)
  | Mirror_rejected_view

type goal_store_unavailable_view = {
  gsu_file : string;
  gsu_reason : goal_store_unavailable_reason_view;
  gsu_mirror : goal_store_mirror_view;
  gsu_reset_step : Goal_store_unavailable.reset_step;
}

(** A goal projection body that is a failure envelope instead of the
    projection. The Goal–Task link registry is a different source from the
    Goal store and keeps its one-line envelope. *)
type goal_source_failure =
  | Goal_store_unavailable of goal_store_unavailable_view
  | Goal_task_links_unavailable of string

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

type system_log_source =
  | System_structured
  | System_legacy_stderr
  | System_legacy_traceln
  | System_client_tool_host
  | System_source_unknown of string

val system_log_source_label : system_log_source -> string

type system_log_entry = {
  sl_seq : int;
  sl_ts : string;
  sl_level : system_log_level;
  sl_source : system_log_source;
  sl_module : string;
  sl_keeper : string option;
  sl_turn : int option;
  sl_message : string;
  sl_details : Yojson.Safe.t;
  sl_category : string option;
      (** The producer's typed category, as its wire string ([Null] rows carry
          none). The vocabulary is the server's closed set; this reader keeps
          whatever spelling arrives rather than mirroring that set. *)
}

(** One tool call from a keeper's durable call log
    ([GET /api/v1/keepers/:name/tool-calls]). The row's own [keeper] is
    checked against the keeper that was asked for; a row naming another is
    rejected rather than attributed by envelope position. *)
type keeper_call_execution_mode =
  | Keeper_call_serial
  | Keeper_call_concurrent

type keeper_call_schedule = {
  kcs_planned_index : int;
  kcs_batch_index : int;
  kcs_batch_size : int;
  kcs_execution_mode : keeper_call_execution_mode;
}

type keeper_call_disposition =
  | Keeper_call_completed
  | Keeper_call_deferred
  | Keeper_call_failed

type keeper_call_log_health =
  | Call_log_ok
  | Call_log_empty
  | Call_log_missing
  | Call_log_stale
  | Call_log_coverage_gap
  | Call_log_unknown of string
(** The server's freshness verdict on a call log snapshot. [Call_log_unknown]
    carries an unrecognized wire word verbatim: a new word must not break the
    snapshot decode, and readers treat it as an incomplete log, never as a
    proof that a row is absent. *)

val keeper_call_log_health_of_string : string -> keeper_call_log_health
(** The wire [health] word as the variant. Total: unknown spellings become
    {!Call_log_unknown}, so the vocabulary lives here alone and no reader
    branches on a spelling. *)

val keeper_call_log_health_to_string : keeper_call_log_health -> string
(** The variant back to its wire word ([Call_log_unknown s] is [s]), for the
    header that prints the server's verdict verbatim. *)

val keeper_call_disposition_of_string :
  string -> (keeper_call_disposition, string) result
(** The wire word of a call's disposition ([completed], [deferred],
    [failed]) as the variant; any other word is the error, never a default.
    Read by the call log decoder here and by the TUI's live observer, so the
    two planes agree on the vocabulary. *)

val keeper_call_disposition_to_string : keeper_call_disposition -> string
(** The inverse of {!keeper_call_disposition_of_string}. *)

type keeper_call = {
  kc_at : float;  (** [ts], unix seconds *)
  kc_tool : string;
  kc_input : string;  (** the call's argument text as served, may be truncated *)
  kc_output : string option;
      (** what the call answered, as served and already bounded by the server.
          [None] means the row carried no result, which is not the same as a
          call that returned an empty one. *)
  kc_artifact_refs : Tool_output.artifact_ref list;
      (** Validated durable references, independent of the output preview. *)
  kc_outcome : Tool_result.recorded_call_outcome;
      (** How the call ended, read by {!Tool_result.recorded_call_outcome}.
          Never [Recorded_malformed]: the decoder refuses that row. *)
  kc_duration_ms : float option;
  kc_turn : int option;
  kc_execution_id : string option;
      (** Canonical physical execution identity. Chat tool activity joins to
          this field only; timestamps, names, and list positions never join. *)
  kc_tool_use_id : string option;
  kc_schedule : keeper_call_schedule option;
      (** Actual Agent Core schedule, absent only when the producer carried no
          schedule fields. Partial or unknown schedules reject the row. *)
  kc_result_bytes : int option;
  kc_truncated_to : int option;
  kc_disposition : keeper_call_disposition option;
      (** Typed execution disposition. [Deferred] means the invocation handed
          continuation to the async path rather than returning synchronously. *)
}

type keeper_calls_snapshot = {
  kcs_keeper : string;
  kcs_entries : keeper_call list;  (** in the server's order, newest last *)
  kcs_health : keeper_call_log_health;
      (** the server's own freshness verdict, typed at the decode boundary *)
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

(** One runtime row shared by the Keeper picker and Runtime surface.
    [ro_is_default] is derived from the document's top-level
    [default_runtime], not the row's independent binding flag. *)
type runtime_context_source =
  | Runtime_context_override
  | Runtime_context_capability
  | Runtime_context_clamped
  | Runtime_context_provider_override
  | Runtime_context_binding_override
  | Runtime_context_provider_clamped
  | Runtime_context_binding_clamped

type exact_slot_group = Exact_http_slots | Exact_cli_slots | Exact_output_unsupported

type runtime_option = {
  ro_id : string;
  ro_provider : string;
  ro_provider_id : string;
      (** The [providers.<id>] table key; [ro_provider] is its display name. *)
  ro_model : string;
  ro_exact_slot_group : exact_slot_group;
      (** The declared list an exact-lane append writes. *)
  ro_effective_max_context : int;
  ro_max_context_source : runtime_context_source;
  ro_max_output_tokens : int option;
  ro_declared_reasoning_effort : Llm_provider.Reasoning_effort.t option;
      (** The effort a request on this runtime carries; [None] is unset. *)
  ro_is_local : bool;
  ro_is_default : bool;
  ro_quota_exhausted : bool;
  ro_quota_resets_at : float option;
  ro_quota_scope : string option;
  ro_quota_scope_id : string option;
      (** Opaque credential/quota scope ID joined from Usage in this response.
          It identifies a credential location or client home, not the provider's
          account identity; changing credentials in place need not change it.
          [None] means no unambiguous scope ID was reported. *)
  ro_rate_limited : bool;
      (** This process observed a 429 that has neither reached its provider's
          Retry-After deadline nor been cleared by a successful answer.
          Distinct from [ro_quota_exhausted], the provider's quota window. *)
  ro_rate_limit_resets_at : float option;
      (** The end of the provider's active wait; [None] when no limit remains
          or the active limit stated no wait. *)
}

type runtime_resolved_lane = {
  rrl_id : string;
  rrl_runtime_ids : string list;  (** The lane as declared, head first. *)
  rrl_declared : bool;
      (** [true] when a [runtime.lanes.<id>] table declares this lane, so a
          keeper assigned to it walks every candidate and the lane editor can
          reorder or remove it. [false] is the one-candidate lane an assignment
          naming a runtime resolves to: nothing declares it. A declared lane
          of one candidate walks no failover either; what separates this one
          is that there is no table to remove. *)
}

type runtime_resolved_snapshot = {
  rrs_usage : (Tui_decode_usage.provider_usage_windows, string) result;
  rrs_generated_at_iso : string;
  rrs_config_path : string option;
  rrs_default_runtime_id : string option;
  rrs_media_failover : string list;
      (** [\[runtime\].media_failover] as boot admitted it, in order: the
          fleet the vision tool and the image describer call. It is a route,
          not a lane -- no keeper turn dispatches to it. *)
  rrs_media_failover_declared : string list;
      (** The same route in file order before admission. Entries absent from
          {!rrs_media_failover} remain editable in their declared position. *)
  rrs_runtimes : runtime_option list;
  rrs_lanes : runtime_resolved_lane list;
}

(** One lane candidate after an exact [runtime_id] join. Resolved inventory
    owns provider/model identity; the probe owns only its optional observation.
    A missing probe is unobserved, never inferred unhealthy. *)
type runtime_candidate_row = {
  rcr_lane_id : string;
  rcr_lane_declared : bool;
      (** [runtime_resolved_lane.rrl_declared] of the lane this row belongs to,
          carried here because the rows, not the lanes, are what the Runtime
          surface draws and what the lane editor acts on. *)
  rcr_position : int;
  rcr_candidate_count : int;
  rcr_runtime : runtime_option;
  rcr_probe : Tui_decode_runtime_probe.runtime_provider_probe option;
}

type runtime_surface_snapshot = {
  rss_probe : Tui_decode_runtime_probe.runtime_probe_snapshot option;
      (** Current or last-good optional observation. [None] means no provider
          probe has been read; resolved lane identity remains usable. *)
  rss_probe_error : string option;
      (** Why the latest probe read failed. May coexist with [rss_probe] when
          a last-good observation was preserved. *)
  rss_resolved : runtime_resolved_snapshot;
  rss_candidates : runtime_candidate_row list;
  rss_unassigned_probe_count : int;
}

(** A repository the workspace tracks. *)
type repository_status =
  | Repository_status of Repo_manager_types.repository_status
  | Unrecognised_repository_status of string
(** What the server said a repository's status is. [Repo_manager_types] owns
    the four words and the reason [Error] carries; an unrecognised word is the
    reading of a server newer than this build. *)

val repository_status_word : repository_status -> string
(** The word to draw for this status. *)

val repository_status_reason : repository_status -> string option
(** The cause behind the word, which only [Error] has. *)

type repository = {
  rp_id : string;  (** what the workspace routes' [?repo_id=] resolves *)
  rp_name : string;
  rp_codebase : string option;
      (** the server-minted slug the IDE events route scopes by;
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
  rp_status : repository_status;
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

(** Which list the server answered with: the queue of what a task is waiting
    on, or the whole submission history. The store has no removal path, so the
    two differ by an order of magnitude on a live workspace. *)
type verification_view =
  | Awaiting_queue
  | Full_history

val verification_view_to_wire : verification_view -> string
(** The query-parameter spelling the server reads. *)

type verification_snapshot = {
  vs_requests : verification_request list;
  vs_total : int;  (** Rows in the whole view, not the number returned. *)
  vs_view : verification_view;
  vs_offset : int;
  vs_truncated : bool;  (** A further page exists. *)
  vs_awaiting_unresolved : string list;
      (** Request ids the backlog waits on that name no record. A task holding
          one of these is waiting on something that is not there. One page of
          them: the server cuts the list at the request's limit. *)
  vs_awaiting_unresolved_total : int;
      (** How many such ids there are in all, which the page may not hold. *)
  vs_backlog_error : string option;
      (** Why the queue could not be resolved. An empty list carrying this is
          not an empty queue. *)
  vs_backlog_recovery : string option;
      (** Set when the queue came from a recovery snapshot rather than the
          live backlog: the rows are real and as old as that snapshot, so
          anything submitted after it is absent. *)
}
(** The four backlog fields are required in {!Awaiting_queue}, where the
    server joins the backlog and always sends them. {!Full_history} does not
    join the backlog and sends none of them, so they read as empty there. *)

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
(** A validated keeper health reading — whether the keeper's keepalive is
    running, whether it has turned yet, and whether its turns are failing.
    Behind the decoder boundary for
    the same reason as {!keeper_phase}:
    a TUI executable should not need a second dependency on the Keeper runtime
    library to name one. *)

val keeper_health_of_string : string -> keeper_health option
val keeper_health_to_string : keeper_health -> string

type keeper_health_reading =
  | Health_running  (** Phase Running and at least one turn recorded *)
  | Health_idle  (** Phase Running, no turn recorded yet *)
  | Health_failing  (** Phase Failing: the keepalive still runs turns, and they fail *)
  | Health_offline  (** Keepalive not running: the phase admits no turn *)

val keeper_health_reading : keeper_health -> keeper_health_reading
(** The health reading as a variant a surface can match.

    {!keeper_health_to_string} is for showing a person a word. A surface that
    branches on health matched that word instead, which put a renamed label
    one edit away from silently reading as the healthy case. *)


type keeper_activation_mode = Activation_manual | Activation_on_demand | Activation_autonomous

type keeper_portrait = Keeper_portrait_equipment.reading =
  | Ready of Keeper_portrait_look.equipment
  | Unavailable of string

type keeper_runtime = {
  kr_name : string;
  kr_identity : (keeper_identity, string) result;
      (** The server's brief metadata, decoded separately so a missing trace
          or timestamp does not hide independently valid lifecycle controls.
          The metadata name must agree with [kr_name]. *)
  kr_portrait : keeper_portrait;
  kr_candle_balance_milli : string option;
  kr_candle_account_revision : (string option, string) result;
  (** [Ok None] is observed Candle-off; [Error] cannot authorize an Item account. *)
  kr_health : keeper_health;
  kr_paused : bool;
  kr_next_action : Keeper_status_runtime.keeper_next_action_path option;
  kr_keepalive_running : bool;
  kr_activation_mode : keeper_activation_mode;
  kr_runtime_id : string;
  kr_phase : keeper_phase;
  kr_sandbox_profile : string;
  kr_runtime_blocker_summary : string option;
  (** Current registry failure; [None] means the roster observed no blocker. *)
}
(** One row of [GET /api/v1/gate/keepers] — the live runtime reading of a
    keeper, as [masc_keeper_list] renders it.

    One keeper is described by four separate readings and each has its own
    field here: [kr_phase] is the lifecycle cell, [kr_health] is whether the
    keeper is reporting on time, [kr_paused] is whether a person stopped it,
    and [kr_next_action] is what the runtime derived to do about it.

    [kr_next_action] is [None] when the runtime named no action, which is not
    the same as naming one that means "nothing to do". *)

val keeper_of_runtime : keeper_runtime -> keeper
(** Project the public row into a remote Keeper. No local metadata, task or
    usage measurements are inferred from the runtime state. *)

val decode_keeper_runtime_list :
  Yojson.Safe.t -> (keeper_runtime list * (string * string) list * bool * int * (Candle_observation.t, string) result, string) result
(** Decode the [keepers] array of [GET /api/v1/gate/keepers] into
    [(rows, configuration_errors, truncated, total, candle)]. Explicit metadata errors
    are retained per keeper without discarding readable rows. Malformed Candle
    fields produce an [Error] observation and withdraw every balance while
    keeping the readable Keeper lifecycle rows. A row whose [status] or lifecycle [phase] is
    outside its typed vocabulary fails the whole reading rather than defaulting, so producer
    drift surfaces as an error instead of a wrong status glyph.

    A [status:"error"] row without structured metadata error is retained in
    the error list with its message or an explicit unavailable explanation.
    No lifecycle, activation, runtime or paused state is inferred from missing
    metadata. Healthy rows keep their required-field contract. *)

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

(** The phase conditions that can each put a keeper in the same phase:
    either health reading makes it failing, and a pending launch is one of
    the ways it is offline. The other conditions each have a phase of their
    own, which [kl_phase] already names. *)
type keeper_lane_conditions = {
  klc_launch_pending : bool;
  klc_heartbeat_healthy : bool;
  klc_turn_healthy : bool;  (** [false] once a turn fails, until one succeeds. *)
}

type keeper_lane = {
  kl_keeper : string;
  kl_phase : keeper_lane_phase;
  kl_turn_phase : keeper_lane_turn_phase;
  kl_idle_seconds : int;
  kl_last_outcome : keeper_lane_last_outcome option;
  kl_conditions : keeper_lane_conditions;
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
  | Standalone_off
  | Standalone_running
  | Standalone_idle
  | Standalone_degraded
  | Standalone_no_retained_observation
  | Standalone_unavailable

(** Why a lane can or cannot run, as the server derived it from the registry.
    [sl_status] collapses the last two into one word ("unavailable"); this
    keeps them apart, because a lane nobody configured and a lane whose
    registry could not be read are different problems with different fixes.
    [Lane_slotless] is the server's "degraded": configured, but with no
    catalog slot and no CLI slot admitted. *)
type standalone_lane_configuration =
  | Lane_off
  | Lane_ready
  | Lane_slotless
  | Lane_unconfigured
  | Lane_registry_unavailable

type standalone_lane_slot_count = {
  slsc_slot_id : string;
  slsc_count : int;
}

type standalone_lane_runs_without_slot = {
  slws_vendor_system_one : int;
  slws_server_restarted : int;
  slws_no_slot : int;
}
(** The lane's finished runs that name no slot, by why: Vendor System One
    answered a Board Attention run before any slot was bound, a restart
    closed the run on replay, or it finished before a slot was bound. With
    the slot counts they add up to the finished runs. *)

type standalone_lane_jev_destination = {
  sljd_destination_uri : string;
  sljd_model : string;
}
(** One armed Jev destination: the URL it is observed by and the model id it
    is asked for. Two destinations may share a model id. *)

type standalone_lane_jev =
  | Jev_off
  | Jev_configured of { destinations : standalone_lane_jev_destination list }
  | Jev_cli_only
  | Jev_lane_unavailable

type standalone_lane = {
  sl_lane : Standalone_lane.t;
  sl_label : string;
  sl_purpose : string option;
      (** Human-readable consumer purpose. Optional so a newer TUI can still
          read a retained v1 snapshot written before the field was added. *)
  sl_required : bool;
  sl_status : standalone_lane_status;
  sl_configuration_state : standalone_lane_configuration;
  sl_jev : standalone_lane_jev option;
  sl_admitted_slots : string list;
  sl_cli_slots : string list;
  sl_dropped_slots : string list;
      (** Slot ids the lane declared that publication could not admit — the
          per-lane answer to "configured single, or configured double with
          one silently dropped". *)
  sl_declared_slots : string list;
      (** [slots] in the order [runtime.exact_output_lanes.<id>] writes them,
          admitted or not. The two lists above are an admission reading and
          lose file order once a sibling was rejected; the slot editor moves
          and drops by position, so it reads this one. *)
  sl_declared_cli_slots : string list;
      (** [cli_slots] in source order, including any client rejected at admission. *)
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
  sl_runs_without_slot : standalone_lane_runs_without_slot;
}

type standalone_lanes_snapshot = {
  sls_observed_at_unix : float;
  sls_exact_run_projection_count : int;
  sls_exact_run_source_total : int;
  sls_exact_run_projection_truncated : bool;
  sls_lanes : standalone_lane list;
}

val standalone_lane_status_to_string : standalone_lane_status -> string

(** The configuration clause of the lane detail line, subject included where
    the state needs one. The caller writes no noun of its own. *)
val standalone_lane_configuration_phrase :
  standalone_lane_configuration -> string

(** The lane detail's last two lines: what a retained run's Output holds, and
    what the run record keeps. *)
type standalone_lane_answer = {
  sla_output_meaning : string;
  sla_evidence : string;
}

val standalone_lane_answer : standalone_lane -> standalone_lane_answer
(** Every lane has its own pair. *)
val decode_standalone_lanes_snapshot :
  Yojson.Safe.t -> (standalone_lanes_snapshot, string) result

(** [GET /api/v1/dashboard/clients] body — everyone attached to this
    workspace in one reading: directory agents, state-backed sessions, and
    runtime fibers. The status is the closed [agent_status] enum; the row
    keeps the fields the Runtime family draws and ignores the profile
    decorations (emoji, korean name) the same producer carries for the
    dashboard, so the two surfaces can grow separately. A keeper-bound row
    names its keeper; a non-keeper MCP client carries [None], which is the
    row this surface exists to show. *)
type client_status =
  | Client_active
  | Client_busy
  | Client_listening
  | Client_inactive

type client_row = {
  cr_name : string;
  cr_agent_type : string;
  cr_status : client_status;
  cr_current_task : string option;
  cr_keeper_name : string option;
  cr_session_bound_at : string;
  cr_last_seen : string;
  cr_capabilities : string list;
}

type clients_snapshot = {
  cls_observed_at : string;
  cls_clients : client_row list;
}

val client_status_to_string : client_status -> string
val decode_clients_snapshot :
  Yojson.Safe.t -> (clients_snapshot, string) result

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

(** The slot one Keeper reaches first in one exact-output lane. *)
type keeper_exact_lane_first = {
  kel_keeper : string;
  kel_lane_id : string;
  kel_slot_id : string;
  kel_offered : bool;
      (** [false]: the published lane no longer offers [kel_slot_id], so the
          lane walks its declared order and this row has no effect. *)
}

val decode_keeper_gate_settings :
  Yojson.Safe.t ->
  ((string * string) list * keeper_exact_lane_first list, string) result
(** [(keeper, mode) list, exact-lane firsts] from
    [/api/v1/dashboard/gate/keeper-settings] ([modes] and [exact_lanes]). A
    list whose [*_state] says [unavailable] is an [Error], never an empty
    list.

    Distinct from {!decode_tool_approval_mode_overrides}: that one is the
    in-memory YOLO stance a restart clears, this is what the Gate decides an
    external effect under. Two per-Keeper settings with similar names, and an
    operator reading one for the other is the reason both are named in
    full. *)

type runtime_param_surface =
  { rps_order : int  (** Catalog position, so groups render in registry order. *)
  ; rps_id : string
  ; rps_description : string
  }
(** Which surface claims a param, from the [surfaces] array
    [/api/v1/runtime/params] returns beside [parameters]. *)

type runtime_param_row =
  { rpr_key : string
  ; rpr_current_json : string
  ; rpr_default_json : string
  ; rpr_has_override : bool
  ; rpr_description : string
  ; rpr_value_type : string
  ; rpr_min_json : string option
  ; rpr_max_json : string option
  ; rpr_choices : string list
    (** The closed set of values this param accepts, when it has one. Empty
        for a param whose value the reader types. A partly closed domain
        lists its named values here and still accepts the rest. *)
  ; rpr_surface : runtime_param_surface option
    (** [None] rather than a placeholder surface: a param no surface claims is
        a real state the screen has to show, and inventing a group for it would
        hide that the registry never filed it. *)
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
  Yojson.Safe.t -> ((string * Keeper_tool_approval_mode.mode) list, string) result
(** Decode [GET /api/v1/keepers/tool-approval-mode]'s
    [{overrides: [{keeper, mode}]}] into (keeper, mode) pairs. The mode is
    read through {!Keeper_tool_approval_mode.mode_of_string}; a word it does
    not know fails the read. *)

(* The detail pane is where an operator reads the request whole. A row whose
   input is an object draws it key by key; one whose input is not draws the
   server's flattened preview under a label that says it is the flattened
   preview, because sitting a possibly-truncated wall under "input" promised
   a whole it never was. *)
type gate_input_rows =
  | Rows of (string * string) list
      (** One field per key of the stored input object: the key is the label,
          the value is what the producer stored -- strings whole, every other
          value as compact JSON. The order is the producer's, because a
          producer that leads with the field the operator reads is making a
          statement the serializer must not rearrange. *)
  | Flattened of string option
      (** The server's flattened preview, with the fact that this input never
          was an object. [None] means the server recorded no preview either;
          the pane says so rather than drawing nothing. *)

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
      (** The one-line summary the queue row and the approvals payload line
          show. A [tool_execute] row leads with the command it would run;
          every other operation keeps the server's flattened preview. *)
  gp_input_rows : gate_input_rows;
      (** The detail pane's copy of the input, uncut. [Rows] is one field per
          key of the stored input object -- strings whole, other values as
          compact JSON. [Flattened] says this input never was an object, so
          the pane draws the server preview under a label that names it. *)
  gp_execution_cwd : string option;
      (** The working directory a [tool_execute] request would run in.
          [None] for operations that carry no execution context. *)
  gp_execution_sandbox : string option;
      (** Where a [tool_execute] request would run -- [host], or the container
          it was granted against. The command alone does not say this, and it
          changes what the command means. *)
  gp_waiting_s : float option;
  gp_phase : gate_pending_phase;
  gp_auto_judge_detail : string option;
      (** Durable Auto Judge failure or handoff reason, when the server
          recorded one. *)
  gp_retry_request : Yojson.Safe.t option;
      (** Exact observed payload for a server-validated rearm. [None] means
          the row must be decided by a human rather than replayed. *)
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
  ktp_status_text : string;
  ktp_updated_at_unix : float;
  ktp_text_tail : string;
      (** Tail of the newest response text this turn has produced. *)
  ktp_last_tool : string option;
      (** Most recently observed tool request or return; not execution status. *)
}

type keeper_turn_state =
  | Keeper_turn_idle
  | Keeper_turn_running of {
      lane : keeper_turn_lane;
      started_at_unix : float;
      interrupt_token : string;
      preview : keeper_turn_preview option;
    }
      (** [started_at_unix] is the server owner clock's epoch reading; derive
          display age against the local clock, never trust a precomputed one.
          [interrupt_token] is the stop handle the Owner minted with the turn
          slot. A running turn on the wire always carries one; a row without
          it is a decode error, not an idle turn.
          [preview] is the live glance an older server does not send. *)
  | Keeper_turn_unavailable of string
      (** The owner registry could not answer for this keeper — distinct from
          idle so the badge never reads "not running" out of a lookup error. *)

type keeper_turn_row = {
  ktr_keeper_name : string;
  ktr_chat_control_token : string option;
  ktr_state : keeper_turn_state;
}

val decode_keeper_turns :
  Yojson.Safe.t -> (keeper_turn_row list, string) result
(** Decode [GET /api/v1/keepers/turns] ([masc.keeper_turns.v1]): one row per
    registered keeper. Unknown schema, status, or lane is an error, not a
    silently defaulted row. *)

type runtime_assignment_source =
  | Default_runtime
  | Explicit_runtime
(** Whether the keeper rides the fleet default or has an explicit assignment. *)

type runtime_unavailable_reason =
  | Missing_catalog_model of
      { provider_label : string
      ; model_id : string
      }
(** The server's closed [reason.kind] sum for an unavailable assignment. *)

type runtime_assignment_resolution =
  | Runtime_assignment_lane of string
  | Runtime_assignment_missing
  | Runtime_assignment_unavailable of
      { runtime_id : string
      ; reason : runtime_unavailable_reason
      }
(** The server's closed [resolved.kind] sum. Consumers match this value directly;
    membership in a separately projected lane catalogue does not reclassify it. *)

type runtime_assignment =
  { ra_keeper : string
  ; ra_source : runtime_assignment_source
  ; ra_resolution : runtime_assignment_resolution
  }

val decode_runtime_resolved_full :
  Yojson.Safe.t ->
  (runtime_option list * runtime_resolved_lane list * runtime_assignment list, string) result
(** Decode the shared resolved-runtime document once, then project its runtime
    catalogue, configured lanes with candidate failover chains, and keeper
    assignments for the picker, all in server order. *)

val decode_runtime_resolved :
  Yojson.Safe.t ->
  (runtime_option list * runtime_assignment list, string) result
(** Decode the shared resolved-runtime document once, then project its runtime
    catalogue and keeper assignments for the picker, both in server order. *)

(** The fleet scan's [blocker], read as the reason it names. A name this
    build does not know is kept by name: a newer server's reason is still a
    reason, and is drawn as the server wrote it rather than dropped. *)
type fleet_blocker =
  | Blocker of Keeper_fleet_blocker.t
  | Unrecognised_blocker of string

(** How the fleet scan graded the fleet ({!Keeper_fleet_grade}).
    [Unrecognised_fleet_status] keeps a word this build does not know as the
    server wrote it. *)
type fleet_status =
  | Fleet_grade of Keeper_fleet_grade.t
  | Unrecognised_fleet_status of string

type fleet_safety = {
  fs_status : fleet_status;
  fs_blocker : fleet_blocker option;
  fs_operator_action_required : bool;
  fs_bootable_count : int;
  fs_running_count : int;
  fs_executable_count : int;
  fs_failing_count : int;
  fs_recovering_count : int;
  fs_turn_configuration_error_count : int;
  fs_official_client_recovery_required_count : int;
  fs_paused_count : int;
  fs_target_reaction_capacity : int;
  fs_reaction_capacity_shortfall : int;
  fs_bootable_names : string list;
  fs_running_names : string list;
  fs_executable_names : string list;
  fs_turn_configuration_error_names : string list;
  fs_official_client_recovery_required_names : string list;
  fs_active_task_owner_without_fiber_count : int;
  fs_completion_authority_pending_count : int;
  fs_active_task_owner_scan_error_count : int;
      (** Sources the task-owner scan could not read, so the count above is
          short by whatever they held. *)
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

type fleet_reading_freshness =
  | Fleet_current
      (** The health snapshot is [ready]: the latest refresh measured it, and
          within the snapshot's time to live. *)
  | Fleet_last_good of { measured_at_unix : float; stale_reason : string }
      (** The snapshot is [stale]: the refreshes since have timed out or
          raised, or none has run within the time to live, so the server
          serves the last reading it measured. [measured_at_unix] is when
          (unix seconds on the server's clock); [stale_reason] is the
          server's word for why ([last_good_refresh_timeout],
          [last_good_refresh_error], [ttl_expired]). *)
  | Unrecognised_snapshot_status of string
      (** A snapshot status this build has no reading for, beside a fleet
          reading, kept as the server spelled it. The server's other words
          ([warming], [timeout], [error]) do not arrive here: it writes them
          only when it holds no last good snapshot, and then the fleet
          section is the placeholder, not a reading
          ([Server_routes_http_runtime.full_health_snapshot_metadata]). *)
(** How current a fleet reading is. The fleet section does not say: the
    [full_health_snapshot] beside it in the same body does. *)

type fleet_safety_reading =
  | Fleet_measured of
      { fleet : fleet_safety
      ; freshness : fleet_reading_freshness
      }
  | Fleet_not_measured of { status : string }
      (** The health snapshot has no fleet reading and nothing failed: it is
          being rebuilt, at boot and again after a change invalidates it.
          [status] is the placeholder's word (["warming"]). Kept apart from a
          reading: zero counts would draw an idle fleet the server never
          measured. *)

type server_gc_health = {
  sgc_heap_words : int;
  sgc_live_words : int;
  sgc_minor_heap_size : int;
  sgc_minor_collections : int;
  sgc_major_collections : int;
  sgc_compactions : int;
  sgc_forced_major_collections : int;
  sgc_minor_words : float;
  sgc_promoted_words : float;
  sgc_major_words : float;
}

type server_scheduler_health = {
  ssch_probe : string;
  ssch_samples : int;
  ssch_p50_ms : float;
  ssch_p95_ms : float;
  ssch_p99_ms : float;
  ssch_max_ms : float;
  ssch_mean_ms : float;
  ssch_stalls : int;
  ssch_pool_domains : int option;
}

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
  sid_state_ready : bool option;
      (** [/health] [startup.state_ready]. [None] when the probe carries no
          startup section: neither booting nor vouched ready. *)
  sid_uptime : string option;
      (** [/health] [uptime] human-readable elapsed duration (e.g. "1h 42m"). *)
  sid_sse_clients : int option;
      (** [/health] [sse_clients] active connected SSE stream subscribers. *)
  sid_gc : server_gc_health option;
      (** [/health] [gc] quick GC counters and heap sizes. *)
  sid_scheduler : server_scheduler_health option;
      (** [/health] [scheduler] scheduler latency probe distribution and stalls. *)
}
(** Which server the TUI is talking to, as [/health] reports it.

    The footer said [Port: 8935] and nothing else, so two checkouts serving
    on the same port were indistinguishable from the screen -- and a binary
    older than the tree it was built from looked exactly like a current one.
    [sid_binary_commit_age_s] is how long ago that binary's commit landed,
    which is the number that separates the two. *)

val decode_server_identity : Yojson.Safe.t -> (server_identity, string) result

type prompt_operator_surface =
  | Prompt_primary
  | Prompt_fragment

(** Where the effective text came from. The server resolves this once, in
    [Prompt_registry_types.resolve_source], and it is the whole answer: an
    operator editing an overridden prompt is editing the override, and
    clearing it returns the file's words rather than emptying the prompt.

    The wire also carries [has_override] and [file_exists], the two booleans
    resolution consumed. Decoding them here would give the TUI a second way to
    spell the same decision, and it had one: the list mark and the detail line
    each classified separately, in the same file, fifty lines apart.

    [decode_prompts] rejects the whole snapshot when any row fails, as it
    already does for a row with no key or a partial variable list, so an
    unknown word here empties the pane rather than mislabelling one row. That
    is the older contract, not a new one, and it is the honest reading: an
    unrecognised word means the server and this build disagree. *)
type prompt_source =
  | Prompt_override
  | Prompt_file
  | Prompt_missing

type prompt_row = {
  pr_key : string;
  pr_category : string;
  pr_operator_surface : prompt_operator_surface;
  pr_description : string;
  pr_effective : string;
      (** What a turn actually gets: the override when there is one, the file
          otherwise. This is the text an editor should open. *)
  pr_file_path : string;
  pr_source : prompt_source;
  pr_template_variables : string list;
  pr_override_default_moved : bool;
      (** The override in force was written against a default that has since
          changed -- its body, or the variables it declares. The override
          still applies; the text it replaced is not the text it replaced
          then. False for a row without an override. *)
}

type runtime_prompt_asset = {
  pra_path : string;
  pra_file_path : string;
  pra_value : string;
  pra_file_exists : bool;
}

type held_back_override = {
  hbo_key : string;
  hbo_bytes : int;
  hbo_reason : string;
      (** Why the registry is not applying it: the override names a template
          variable the prompt does not declare, so it cannot render. *)
}
(** An override the operator saved and the registry declined to restore.

    A default body that changed since the override was written is not a
    reason: the override applies and the row reads as
    [pr_override_default_moved]. What holds one back is a contract it cannot
    render under. The override is kept rather than deleted -- writing the key
    again, without the stale variable, puts it back in force. *)

type prompts_snapshot = {
  ps_rows : prompt_row list;
  ps_runtime_assets : runtime_prompt_asset list;
  ps_held_back : held_back_override list;
      (** Empty in the ordinary case. Non-empty means the reader has
          customization that is not reaching any turn. *)
}
(** GET /api/v1/prompts. *)

val prompt_rows_for_operator : show_fragments:bool -> prompts_snapshot -> prompt_row list
(** Primary prompts by default; [show_fragments] exposes the still-editable
    assembly fragments without flattening them into the main catalog. *)

val decode_prompts : Yojson.Safe.t -> (prompts_snapshot, string) result

(** {2 Prompt presets} — [/api/v1/presets] (#32777). *)

type preset_manifest = {
  pm_name : string;
  pm_description : string;
  pm_created_at : string;
  pm_override_count : int;
  pm_override_keys : string list;  (** Which prompts the preset overrides. *)
  pm_keepers : string list;
  pm_assignment_count : int;
  pm_lane_count : int;
}

type presets_snapshot = {
  pss_presets : preset_manifest list;
  pss_unreadable : (string * string) list;
      (** directory name, why its manifest did not read *)
}

type preset_settings_match =
  | Preset_settings_match
  | Preset_settings_differ
  | Preset_settings_unavailable of string

type preset_detail = {
  pd_name : string;
  pd_directory : string;
  pd_settings_match : preset_settings_match;
  pd_prompt_files : (string * string option * prompt_source) list;
  pd_overrides : (string * int) list;  (** prompt key, bytes *)
  pd_instructions : (string * int) list;  (** keeper TOML file name, bytes *)
  pd_assignments : (string * string) list;  (** keeper, runtime id *)
  pd_lanes : string list;
}
(** What a preset holds, from [/api/v1/presets/show]. Sizes rather than
    bodies: the pane is for deciding whether to apply one, and a 4 KB prompt
    does not fit in it. *)

val decode_preset_detail : Yojson.Safe.t -> (preset_detail, string) result

type preset_part = {
  pp_effect : string;  (** when the surface takes effect, as the server names it *)
  pp_applied : string list;
  pp_skipped : (string * string) list;  (** key, reason *)
}

type preset_runtime_status =
  | Preset_runtime_unchanged
  | Preset_runtime_committed
  | Preset_runtime_failed of string

type preset_restore_report = {
  prr_restored : string;
  prr_autosave : string;
  prr_prompt_overrides : preset_part;
  prr_instructions : preset_part;
  prr_runtime : preset_runtime_status;
}

val decode_presets : Yojson.Safe.t -> (presets_snapshot, string) result
(** GET /api/v1/presets. Any [error] field is the error, whatever [ok] says:
    the server answers its warm-up and auth refusals with [error] alone on a
    200. *)

val decode_preset_saved : Yojson.Safe.t -> (preset_manifest, string) result
(** POST /api/v1/presets — the manifest of the preset just written. *)

val decode_preset_restore : Yojson.Safe.t -> (preset_restore_report, string) result
(** POST /api/v1/presets/restore — the per-surface report. *)

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
    retained registry without assuming the newest page contains a Librarian.
    Every row is read before the first Librarian is picked, so an unknown lane
    or a missing [run_id] in any row refuses the whole page. *)

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
  | Lane_run_approved
  | Lane_run_reviewed
  | Lane_run_committed
  | Lane_run_superseded
  | Lane_run_rejected
  | Lane_run_deferred
  | Lane_run_review_cancelled
  | Lane_run_infrastructure_unavailable
  | Lane_run_not_reviewed
  | Lane_run_commit_failed
  | Lane_run_raised
  | Lane_run_other of string

val lane_run_status_label : lane_run_status -> string

type lane_run_kind =
  | Lane_run_exact_output
  | Lane_run_task_verification
  | Lane_run_goal_verification
  | Lane_run_kind_other of string

val lane_run_kind_label : lane_run_kind -> string

type lane_run_decision =
  | Lane_run_decision_approved
  | Lane_run_decision_rejected
  | Lane_run_decision_reviewed
  | Lane_run_decision_committed
  | Lane_run_decision_superseded
  | Lane_run_decision_pending
  | Lane_run_decision_not_reached
  | Lane_run_not_a_decision
  | Lane_run_decision_unknown

val lane_run_decision :
  run_kind:lane_run_kind -> status:lane_run_status -> lane_run_decision
(** Separates a completed execution from a review decision. In particular,
    an exact-output run that succeeded is still [Lane_run_not_a_decision]. *)

type lane_run_tool_disposition =
  | Lane_run_tool_completed
  | Lane_run_tool_deferred
  | Lane_run_tool_failed
  | Lane_run_tool_disposition_other of string

val lane_run_tool_disposition_label : lane_run_tool_disposition -> string

type lane_run_tool =
  { lrt_name : string
  ; lrt_disposition : lane_run_tool_disposition
  ; lrt_duration_ms : float
  }

type lane_run_tool_evidence =
  | Lane_run_no_tools_by_contract
  | Lane_run_tools_pending
  | Lane_run_tools_observed of lane_run_tool list
  | Lane_run_tools_contract_unknown

type lane_run_skill_evidence =
  | Lane_run_no_skills_by_contract
  | Lane_run_skills_contract_unknown

type lane_run_gate_judgment =
  | Lane_run_not_gate_judgment
  | Lane_run_gate_judgment_pending
  | Lane_run_gate_judgment_not_reached
  | Lane_run_gate_judgment_unavailable
  | Lane_run_gate_advisory of
      Keeper_approval_queue_rules_types.advisory_judgment

type lane_run_failure =
  { lrf_code : string
  ; lrf_detail : string
  }

type lane_run_summary =
  { lrs_run_id : string
  ; lrs_run_kind : lane_run_kind
  ; lrs_lane : Standalone_lane.t
  ; lrs_subject_id : string option
  ; lrs_actor : string
  ; lrs_started_at : float
  ; lrs_status : lane_run_status
  ; lrs_elapsed_s : float option
  ; lrs_selected_slot : string option
  ; lrs_failure : lane_run_failure option
  }

type lane_run_page =
  { lrpg_runs : lane_run_summary list
  ; lrpg_next : (float * string) option
  ; lrpg_total : int option
  }

type lane_run_answer_source =
  | Lane_run_answer_exact_attempt of string
  | Lane_run_answer_cli_slot of string
  | Lane_run_answer_vendor_system_one of
      { model : string
      ; endpoint : string
      }
(** The typed source of a successful Board-attention answer. This is separate
    from [lrd_selected_slot]: Vendor System One answers before a slot runs and
    therefore has no exact-flow receipt or selected slot. *)

type librarian_preflight_status =
  | Preflight_awaiting
  | Preflight_not_called of string
  | Preflight_failed of string
  | Preflight_invalid of string
  | Preflight_judged of
      Typesafeai_librarian_preflight.decision Typesafeai_types.decoded_choice
type librarian_generation_path = Generation_not_entered | Generation_full_lane | Generation_jev_no_change
type librarian_preflight_reading =
  { lp_status : librarian_preflight_status
  ; lp_generation_path : librarian_generation_path
  ; lp_full_llm_skipped : bool
  ; lp_elapsed_s : float option
  ; lp_model : string option
  ; lp_domain_rejection : string option
  }

type lane_run_detail =
  { lrd_run_id : string
  ; lrd_run_kind : lane_run_kind
  ; lrd_lane : Standalone_lane.t
  ; lrd_subject_id : string option
  ; lrd_actor : string
  ; lrd_started_at : float
  ; lrd_status : lane_run_status
  ; lrd_elapsed_s : float option
  ; lrd_selected_slot : string option
  ; lrd_answer_source : lane_run_answer_source option
  ; lrd_failure : lane_run_failure option
  ; lrd_input_payload : Yojson.Safe.t
  ; lrd_input_availability : Exact_lane_run_registry.payload_availability
  ; lrd_output_availability : Exact_lane_run_registry.payload_availability option
  ; lrd_output : Yojson.Safe.t option
  ; lrd_librarian_preflight : librarian_preflight_reading option
  ; lrd_tool_evidence : lane_run_tool_evidence
  ; lrd_skill_evidence : lane_run_skill_evidence
  ; lrd_gate_judgment : lane_run_gate_judgment
  ; lrd_decision : lane_run_decision
  }

val decode_lane_run_page :
  lane:Standalone_lane.t -> Yojson.Safe.t -> (lane_run_page, string) result
(** One cursor page of standalone-lane summaries. The server filters before
    pagination; the decoder still checks [lane] so a mismatched response
    cannot move the cursor onto another lane. *)

val decode_lane_run_detail : Yojson.Safe.t -> (lane_run_detail, string) result
(** The whole record of one standalone run. Exact-output runs carry their
    prompt payload and explicitly report no MASC tool loop. Task/Goal
    Verifier runs carry typed tool observations alongside their durable raw
    verdict evidence. The server's closed retained-run projection explicitly
    reports that every current standalone path does not load Keeper Skills;
    the decoder does not infer that fact from [run_kind]. HITL model judgment
    stays separate from the Gate resolution that may later grant or reject authorization.
    [lrd_output] is [None] while the run is still running. *)

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
  | Context_turn_total_usage of
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

val decode_runtime_resolved_snapshot :
  Yojson.Safe.t -> (runtime_resolved_snapshot, string) result
(** Strict Runtime-surface slice of [GET /api/v1/runtime/resolved]. Runtime and
    lane identities must be unique and lane candidates must exist.
    Assignment and max-context fields belong to other consumers and are not
    duplicated into this light projection. *)

(** What each provider account said about its own usage windows, as
    [GET /api/v1/runtime/resolved] carries it. The server keeps these values
    as reported and derives no availability from them. *)
val decode_runtime_surface_snapshot :
  probe_json:Yojson.Safe.t ->
  resolved_json:Yojson.Safe.t ->
  (runtime_surface_snapshot, string) result
(** Decode and join the two server-owned projections by exact [runtime_id],
    preserving lane and candidate order. Extra probe rows are counted; a lane
    candidate absent from a stale probe remains [None]. *)

val join_runtime_surface :
  probe:Tui_decode_runtime_probe.runtime_probe_snapshot option ->
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
(** One step of the level-floor ladder: [None] (server default, everything) ->
    info -> warn -> error -> [None]. *)

val toggle_system_log_verbose :
  system_log_level option -> system_log_level option
(** [None] (the route's DEBUG default) becomes INFO; any explicit floor opens
    back to DEBUG. This is the direct verbose on/off control beside the full
    level ladder. *)

val system_log_level_query : system_log_level -> string
(** The lowercase spelling the [/api/v1/dashboard/logs] route validates. *)

val decode_goal_source_failure :
  Yojson.Safe.t -> (goal_source_failure option, string) result
(** [Ok None] when the body is the projection itself. Every token is parsed
    exactly against the constructor names [Goal_store_unavailable.reason_name]
    and siblings emit; an unknown token, a missing member, a [field] beside a
    reason other than [schema_rejected] or a [goal_count] beside a mirror
    other than [mirror_decodes] is an [Error], never a default. *)

val goal_store_unavailable_view_to_string : goal_store_unavailable_view -> string
(** [goal_store: unavailable reason=… file=… mirror=… reset=…], the shape of
    [Goal_store_unavailable.to_string] minus the payloads the wire omits. The
    line the Planning header and the detail pane show until RFC-0444 PR-4
    draws the view in the pane body. *)

val decode_planning_snapshot :
  Yojson.Safe.t -> (planning_snapshot, string) result
(** An unreadable Goal store is the rendered
    {!goal_store_unavailable_view_to_string} line as the [Error]; RFC-0444 PR-4
    lifts it into a [Planning_unavailable] constructor. *)

type overview_goal_measurement =
  | Goal_measurement_unread
  | Goal_measurement_not_recorded
  | Goal_measurement_reported of {
      value : string;
      evidence : string;
      actor : string;
      recorded_at : string;
    }
  | Goal_measurement_unavailable of string

(** One goal of [GET /api/v1/dashboard/goals]. Linked Task completion and
    explicitly reported metric values remain separate observations. *)
type overview_goal = {
  og_id : string;
  og_title : string;
  og_completion : string option;
      (** The Goal's current completion state from the verification ledger
          ([proof_refuted], [proof_proven], [proof_pending], [idle],
          [stale_criterion], [ledger_error]); [None] when the payload carries
          no verification member. *)
  og_phase : Goal_phase.t;
  og_priority : int;
  og_criterion_revision : string option;
  og_metric : string option;
  og_target_value : string option;
  og_measurement : overview_goal_measurement;
  og_due_date : string option;
  og_task_count : int;
  og_task_done_count : int;
  og_stagnation_seconds : int option;
  og_task_ids : string list;  (** Ids of [tasks[]], in server order. *)
}

type overview_goals_error =
  | Overview_goal_phase_unknown of { goal_id : string; phase : string }
      (** A goal named a phase {!Goal_phase.parse} does not know. The whole
          reading is refused rather than the goal dropped or given a phase. *)
  | Overview_goals_source_unavailable of string
      (** The server answered, and said it could not read its goals. *)
  | Overview_goals_malformed of string

val overview_goals_error_to_string : overview_goals_error -> string

val decode_overview_goals :
  Yojson.Safe.t -> (overview_goal list, overview_goals_error) result
(** Every goal in the body's [tree], each node before its [children], in
    server order. Goals of every phase are returned; which ones a surface
    draws is the surface's decision. *)

val decode_fleet_safety :
  Yojson.Safe.t -> (fleet_safety_reading, string) result
(** Reads the [keeper_fleet_safety] section out of a [/health?full=1] body.
    A body without the section is an error rather than an empty reading: an
    absent section and a healthy fleet are different facts, and rendering the
    second for the first is how a blocked keeper stays invisible.

    A section carrying [schema = Keeper_fleet_blocker.reading_schema] is a
    reading, and every field of {!fleet_safety} is required: a missing count
    is an error, not zero. A reading also takes its {!fleet_reading_freshness}
    from the body's [full_health_snapshot], which is required: a stale
    snapshot serves a past reading as it was, and without the snapshot's
    word the TUI would draw it as the present. A section without [schema] is
    the health snapshot's placeholder: {!Fleet_not_measured} when it carries
    no [error], and an error with the server's reason when it does (the
    refresh timed out or the scan raised). *)
val parse_log_entry : string -> (log_entry, string) result
val decode_log_entry : Yojson.Safe.t -> (log_entry, string) result
val decode_context_observation :
  expected_trace_id:string ->
  Yojson.Safe.t ->
  (context_observation, string) result
val context_unavailable_reason_to_string : context_unavailable_reason -> string
val is_success_http_status : int -> bool
val http_status_error : status_code:int -> body:string -> string
(** A non-2xx answer as one terminal-safe line: [HTTP <status>: ] and then the
    body's ["error"] sentence when it has one, otherwise the body's head. *)
(** Keep the failure reason visible before the target URL on narrow rows. *)
val http_transport_error : verb:string -> url:string -> detail:string -> string
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

(** Which way a wheel notch turned. *)
type wheel_direction =
  | Wheel_up
  | Wheel_down

(** The key a notch becomes for a surface's scroll binding: [wheel-up] /
    [wheel-down], its own rather than the arrow's. *)
val wheel_key : wheel_direction -> string

(** Decode one SGR mouse report into a wheel notch and its [(row, column)],
    1-based as the terminal reports it, or [None] for reports nothing consumes
    (clicks, releases, horizontal wheel). The position is what lets the loop
    give the notch to the Activity pane under it and every other notch to the
    surface. [parameters] is the raw CSI parameter span (["<64;10;5"]),
    [final] the CSI final byte. *)
val sgr_wheel_report : string -> char -> (wheel_direction * int * int) option

(** Decode one SGR mouse report into the [(row, column)] of an unmodified
    left-button press (button [0], final [M]), 1-based as the terminal
    reports it. Releases, modifier chords, drags and wheel reports return
    [None] — acting on those would double-fire or claim a gesture nobody
    meant. *)
val sgr_left_press : string -> char -> (int * int) option

(** A legacy X10 mouse report, read into the events an SGR report gives.
    Positions are 1-based and row/column ordered. [X10_other_press] is a
    middle, right or modified press, which no surface reads. [X10_release] is
    X10's one release code, which does not say which button went up. *)
type x10_mouse =
  | X10_wheel of wheel_direction * int * int
  | X10_left_press of int * int
  | X10_other_press
  | X10_release of int * int

(** Decode the three raw bytes after [CSI M]: button, column, row, each offset
    by 32. Terminals without SGR ([?1006]) support answer the tracking request
    in this shape; Apple Terminal, the macOS default, is one. Motion reports,
    the horizontal wheel and a position below 1 are [None]; the caller consumes
    the bytes either way. *)
val x10_mouse_report :
  button:char -> column:char -> row:char -> x10_mouse option
val required_display_any_field :
  Yojson.Safe.t -> string list -> (string, string) result
val optional_body_field : Yojson.Safe.t -> (string, string) result
val required_body_field : Yojson.Safe.t -> (string, string) result
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
  | Fc_inserted of {
      line : int;
      text : string;
    }
  | Fc_materialized of {
      sha256 : string;
      bytes : int;
    }
      (** A blob's bytes written into a file by [keeper_artifact_transfer]'s
          [materialize] action. The call's input names the blob by its
          [sha256] and byte count, so the reader has the blob's identity and
          size and no body text. The same handler's [export] action reads a
          file into the blob store and is not a file change. *)

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

type file_activity_snapshot = {
  fas_codebase : string;
  fas_repo_id : string;
  fas_file_path : string;
  fas_window_hours : float;
  fas_calls_in_window : int;
  fas_changes : file_change list;
      (** Durable changes from every Keeper over this exact repository file,
          in tool-log order. *)
  fas_incomplete_over_budget : int;
      (** Exact-address writes whose body outgrew the inline log budget. *)
  fas_incomplete_malformed : int;
      (** Exact-address file-writing rows that violated the projection
          contract. *)
  fas_unattributed_over_budget : int;
      (** Fleet-wide file writes whose input outgrew the log budget. Their
          target is unknowable, so they are not claimed for this file. *)
  fas_unattributed_malformed : int;
}

val file_change_address : file_change -> string
(** The address the change is listed and searched under: [repo_id:path] for a
    file in a clone, and the path itself for a scratch file or an absolute
    one. One spelling, so a row cannot be drawn under one address and found
    under another. *)

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

val decode_file_activity_snapshot :
  Yojson.Safe.t -> (file_activity_snapshot, string) result
(** Decode [masc.ide.file_activity.v1]. Every carried change must match the
    declared repository id and relative path; a mixed response is rejected. *)

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

(** One run of adjacent lines the same author last touched, as
    [/api/v1/git/blame] groups them. The wire spells the author [keeper_id],
    the shape it shares with the activity routes; here it is
    whatever git reported, which is a person and not a Keeper. *)
type blame_block = {
  bb_line_start : int;
  bb_line_end : int;
  bb_author : string;
  bb_at_ms : float;
}

val decode_git_blame : Yojson.Safe.t -> (blame_block list, string) result
(** The route's bare array -- it does not carry the [{ok; data}] envelope its
    neighbours do. *)

val blame_block_at : blame_block list -> int -> (blame_block * bool) option
(** [blame_block_at blocks line] is the block covering [line] and whether
    [line] is where that block starts. Blocks do not overlap, so the first
    cover is the only one; the flag is what lets a gutter name an author once
    per run instead of once per line. *)

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

(** Goal detail timeline. A Goal source failure retains its source type;
    [`Null] with an unavailable approval queue retains the queue's detail.
    Neither failure decodes to an empty event list. *)
type goal_timeline =
  | Goal_timeline_ready of goal_timeline_event list
  | Goal_timeline_unavailable of goal_timeline_unavailability

and goal_timeline_unavailability =
  | Goal_source_failure of goal_source_failure
  | Approval_queue_failure of string

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
    is the store-level failure the server states explicitly. An unreadable
    artifact's [reason] is the producer's cause in one of its two wire shapes
    only — a bare non-empty code string or an object carrying [code]. A
    [read_error] object also carries a non-empty [detail], which is included
    in the rendered cause. Malformed reasons fail the decode. *)
type verification_evidence_item =
  | Ev_collaboration of { ev_reference : string; ev_content : string; ev_sha256 : string }
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

val runtime_context_source_label : runtime_context_source -> string
val runtime_reasoning_effort_label : Llm_provider.Reasoning_effort.t -> string

(** Decoded durable async inventory. Malformed counters are errors, never zero.
    The active inventory contains queued, running and cancelling requests only. *)
type async_request_phase = Async_queued | Async_running | Async_cancelling

type async_request_ownership = Async_runtime_owned | Async_ownership_unknown

type async_request_row =
  { ar_request_id : string
  ; ar_keeper_name : string
  ; ar_phase : async_request_phase
  ; ar_elapsed_sec : float option
  ; ar_ownership : async_request_ownership
  }

type async_request_summary =
  { ars_active : int
  ; ars_runtime_owned : int
  ; ars_ownership_unknown : int
  ; ars_record_errors : int
  }

type async_recovery_report =
  { arr_lost : int
  ; arr_finalized : int
  ; arr_cleaned : int
  ; arr_unreadable : int
  ; arr_failed : int
  ; arr_staging_inspected : int
  ; arr_staging_deleted : int
  ; arr_staging_preserved : int
  }

type async_request_observation =
  | Async_ready of
      { summary : async_request_summary
      ; requests : async_request_row list
      ; recovery : async_recovery_report option
      }
  | Async_unavailable of { kind : string; reason : string option }

val decode_async_request_observation :
  Yojson.Safe.t -> (async_request_observation, string) result

val sgr_left_release : string -> char -> (int * int) option
(** Plain SGR left release position for screenshot click/drag gestures. *)

val keeper_of_declaration : Keeper_declared_roster.t -> keeper

type schedule_hold_reason =
  | Hold_previous_wake_untaken
      (** The target Keeper has not taken the previous occurrence yet. *)
  | Hold_target_shutdown_fenced of
      { target : string
      ; fence_owner : string
      }
      (** The target Keeper refuses intake while the shutdown operation
          [fence_owner] holds its fence (#34642). *)

type schedule_runner_hold =
  { srh_occurrence_id : string
      (** The occurrence the schedule runner held back on its newest
          successful tick. *)
  ; srh_due_at_iso : string
      (** When that occurrence came due. *)
  ; srh_reason : schedule_hold_reason
      (** Why the runner holds it. *)
  ; srh_observed_at : float
      (** When that tick decided to hold it: the newest time the hold is known
          to have stood. *)
  }
(** A schedule the runner is holding back. The server reads it from the same runner
    status [/health] reports as [schedule_runner.held]. *)

val latest_drawable_unix_seconds : float
(** 9999-12-31T23:59:59Z, the latest [observed_at] {!decode_schedule_runner_hold}
    accepts. Far below where [Unix.localtime] fails, so a hold the decoder
    accepts can always be drawn. *)

val decode_schedule_runner_hold :
  Yojson.Safe.t -> (schedule_runner_hold option, string) result
(** Reads a schedule row's [runner_hold]. The key is required: [null] is a
    schedule the runner is not holding, and a row without the key is refused
    rather than read as one. An object must carry all four fields, with
    [observed_at] a time from 1970 to {!latest_drawable_unix_seconds}. *)

type schedule_runner_status =
  | Runner_status of Schedule_contract_values.runner_status
  | Runner_unrecognised of string
      (** A word outside {!Schedule_contract_values.runner_status}, kept as
          itself. *)
(** The schedule list's [schedule_runner.status]. *)

val decode_schedule_runner_status :
  Yojson.Safe.t -> (schedule_runner_status, string) result
(** Reads [schedule_runner.status] from the schedule list. The object and its
    [status] are required; a word this build does not know is
    [Runner_unrecognised] rather than a failure of the whole list. *)

type schedule_list_freshness =
  | List_latest
      (** The newest request for the schedule list succeeded, and this is its
          answer. *)
  | List_kept
      (** The newest request failed; the list on screen is an earlier answer,
          kept so the screen is not emptied. *)

type schedule_hold_reading =
  | Hold_current
      (** The latest list, from a runner whose status is [ok]: the hold is
          the runner's reading now. *)
  | Hold_as_of of float
      (** The hold stood at this time and may not now. *)

val schedule_hold_reading :
  freshness:schedule_list_freshness ->
  runner:schedule_runner_status ->
  schedule_runner_hold ->
  schedule_hold_reading
(** How a hold may be drawn. Only [List_latest] with [Runner_status Runner_ok]
    draws it as the present. The runner re-reads its holds only on a tick that
    succeeds, and a list kept after a failed reload is an earlier answer, so
    every other combination draws the hold at the time it was read
    (#38411). *)

val decode_oauth_client_saved : Yojson.Safe.t -> (int, string) result
(** Reads the reply of [POST /api/v1/keepers/oauth/client]: the number of
    scopes the saved app will ask for, [0] being an app saved with none, so
    the service's own list is asked for. The server always echoes [scopes];
    a reply without it, or with a non-string scope, is refused rather than
    read as a valid scope count. The server's refusals arrive as a non-2xx
    status, which the HTTP client has already turned into an error before this
    runs. *)

type play_invite_row = {
  pi_name : string;
  pi_expires_at : string option;
  pi_expired : bool;
  pi_holds_controller : bool;
}

type play_invite_issued = {
  pii_name : string;
  pii_expires_at : string;
  pii_link : string;
}

type play_invite_revoked = {
  pir_name : string;
  pir_revoked : bool;
  pir_released_controller : bool;
  pir_release_error : string option;
}

val decode_play_invites : Yojson.Safe.t -> (play_invite_row list, string) result
val decode_play_invite_issued : Yojson.Safe.t -> (play_invite_issued, string) result
val decode_play_invite_revoked : Yojson.Safe.t -> (play_invite_revoked, string) result
val play_invite_absent_body : string -> bool
(** True only for the revoke route's [no_such_invite] refusal [code].
    A malformed body or another refusal cannot prove the invite absent. *)

val play_revoke_http_error : status_code:int -> body:string -> string
(** Preserve the release failure detail from the revoke endpoint's 500 reply. *)

val play_invite_refusal : status_code:int -> body:string -> string option
(** The sentence for a client refusal the play routes answered with
    [{error, message}]: ["HTTP 409: <message>"], then in parentheses what the
    body says is missing and who holds the name. Every part is made
    terminal-safe. [None] for a 401 or 403, which are about the credential the
    client sent and are worded where that is known, for a status that is not a
    4xx, and for a body with no [message] to read. *)
