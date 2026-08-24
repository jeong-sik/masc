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
  k_autonomous_turn_count : int;
  k_autonomous_text_turn_count : int;
  k_autonomous_tool_turn_count : int;
  k_board_reactive_turn_count : int;
  k_mention_reactive_turn_count : int;
  k_noop_turn_count : int;
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

val clock_timestamp_for_terminal : string -> string
(** Select the conventional eight-byte clock portion of a timestamp when it is
    present, then sanitize the result. The final sanitizer makes arbitrary
    external timestamp bytes safe even when the byte slice splits UTF-8. *)


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

type tool_snapshot = {
  ts_tools : tool_entry list;
  ts_count : int;
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

type feature_proof_status =
  | Fp_pass
  | Fp_warn
  | Fp_fail
  | Fp_unreadable of string
      (** A status word this build was not taught. Kept rather than folded
          into a neighbour: the operator asked whether the feature is proven,
          and "I cannot read the answer" is not "yes". It counts as a gap. *)

type feature_proof = {
  fp_id : string;
  fp_label : string;
  fp_status : feature_proof_status;
  fp_summary : string;  (** The server's one-line reading, e.g. "3/9 keepers". *)
  fp_next_action : string;  (** What would turn the gap into evidence. *)
  fp_keeper_count : int;
  fp_observed : string list;  (** Keepers with behaviour evidence for it. *)
  fp_missing : string list;  (** Keepers with none. *)
  fp_read_errors : string list;
      (** Keepers whose evidence could not be read at all. Kept apart from
          [fp_missing]: a keeper that failed to exercise the feature and a
          keeper whose record would not open are different problems, and
          counting the second as the first blames the keeper for a read
          failure. *)
}

type autonomy_snapshot = {
  au_generated_at : string;
  au_status : feature_proof_status;  (** The worst status among the features. *)
  au_features : feature_proof list;
  au_feature_count : int;
  au_pass_count : int;
  au_gap_count : int;  (** Features the server counted as warn or fail. *)
  au_keeper_count : int;
  au_window_hours : float option;
      (** The window the report was computed over, when it was given one.
          [None] means the report looked at everything it holds. *)
}

type keeper_runtime = {
  kr_name : string;
  kr_status : Keeper_status_runtime.surface_status;
  kr_keepalive_running : bool;
  kr_autoboot_enabled : bool;
  kr_proactive_enabled : bool;
  kr_runtime_id : string;
}
(** One row of [GET /api/v1/gate/keepers] — the live runtime reading of a
    keeper, as [masc_keeper_list] renders it.

    [kr_status] is the six-member surface vocabulary. It carries no "paused"
    member: operator pause is durable metadata and reaches the TUI on
    {!keeper} instead. A reader that wants the published control-plane status
    composes the two the way the operator snapshot does. *)

val decode_keeper_runtime_list :
  Yojson.Safe.t -> (keeper_runtime list * bool * int, string) result
(** Decode the [keepers] array of [GET /api/v1/gate/keepers] into
    [(rows, truncated, total)]. A row whose [status] is outside the surface
    vocabulary fails the whole reading rather than defaulting, so producer
    drift surfaces as an error instead of a wrong status glyph. *)

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
  th_primary_path : string;
  th_queue_pressure : string;
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

val decode_repository_snapshot :
  Yojson.Safe.t -> (repository_snapshot, string) result

val decode_harness_snapshot :
  Yojson.Safe.t -> (harness_snapshot, string) result

val decode_verification_snapshot :
  Yojson.Safe.t -> (verification_snapshot, string) result

val decode_autonomy_snapshot :
  Yojson.Safe.t -> (autonomy_snapshot, string) result
(** Reads [GET /api/v1/dashboard/keeper-feature-proof]: which autonomy
    features have current behaviour evidence and which still need it. *)

val feature_proof_status_label : feature_proof_status -> string
(** Fixed-width label for the status column. *)

val feature_proof_is_gap : feature_proof_status -> bool
(** Whether the status leaves the feature unproven. An unreadable status
    counts as a gap, so a status word this build does not know can never be
    drawn as evidence that the feature works. *)

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
val required_string_field : Yojson.Safe.t -> string -> (string, string) result
val optional_string_field :
  Yojson.Safe.t -> string -> (string option, string) result
val required_int_field : Yojson.Safe.t -> string -> (int, string) result
val int_field_or : Yojson.Safe.t -> string -> default:int -> (int, string) result
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
