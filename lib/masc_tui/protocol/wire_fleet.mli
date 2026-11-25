(** Pulse, Fleet, Company grouping, 3-bucket Attention, Keeper Live Turns,
    Daily Achievement Scorecard, Fleet SSE deltas, and Keeper Chat wire codecs. *)

open Masc_tui_core

val dashboard_shell_path : string
val dashboard_keepers_path : string
val keepers_turns_path : string
val fleet_stream_path : string
val keeper_chat_stream_path : string
val keeper_turn_interrupt_path : string
val keeper_purge_path : string

type keeper_lifecycle_op =
  | Keeper_boot
  | Keeper_pause
  | Keeper_resume of { operator_operation_id : string }
  | Keeper_shutdown
  | Keeper_reset

val keeper_lifecycle_path : keeper:string -> keeper_lifecycle_op -> string
val keeper_lifecycle_op_label : keeper_lifecycle_op -> string

val encode_keeper_lifecycle_body :
  ?expected_workspace:string * string -> keeper_lifecycle_op -> Yojson.Safe.t

val encode_keeper_purge :
  agent_name:string -> expected_workspace:string * string -> Yojson.Safe.t

val keeper_chat_history_path :
  keeper:string -> ?limit:int -> ?before_seq:int -> unit -> string

val keeper_chat_history_page_path :
  keeper:string -> ?limit:int -> ?cursor:string -> unit -> string

(** {1 Keeper Roster & Company Grouping} *)

type activation_mode =
  | Activation_manual
  | Activation_on_demand
  | Activation_autonomous

type keeper_health =
  | Keeper_healthy
  | Keeper_working
  | Keeper_idle
  | Keeper_degraded
  | Keeper_recovering
  | Keeper_failing
  | Keeper_paused
  | Keeper_offline
  | Keeper_booting

type turn_lane =
  | Lane_chat
  | Lane_proactive
  | Lane_schedule
  | Lane_board
  | Lane_task
  | Lane_verification
  | Lane_maintenance
  | Lane_internal

type turn_preview_activity =
  | Preview_preparing
  | Preview_waiting
  | Preview_streaming
  | Preview_tool_observed
  | Preview_failed

type turn_preparation_phase =
  | Prep_task
  | Prep_world
  | Prep_context
  | Prep_prompt
  | Prep_tools
  | Prep_skills
  | Prep_lane_inputs
  | Prep_workspace_memory
  | Prep_wiki

type turn_preparation_state =
  | Prep_active
  | Prep_prepared
  | Prep_rejected
  | Prep_raised
  | Prep_cancelled

type turn_preparation = {
  phase : turn_preparation_phase;
  state : turn_preparation_state;
  started_at_unix : float;
}

type turn_preview = {
  status_text : string;
  activity : turn_preview_activity;
  text_tail : string;
  last_tool : string option;
  updated_at_unix : float;
  revision : int option;
  preparation : turn_preparation option;
}

type turn_preview_update = {
  owner_key : string;
  preview : turn_preview;
}

type active_turn = {
  lane : turn_lane;
  turn_ref : string option;
  started_at_unix : float;
  interrupt_token : string;
  phase : string option;
  tool_in_flight : string option;
  elapsed_ms : float option;
  preview_observed_through : int option;
  (** The last revision observed for this Owner, including an absent preview. *)
  preview : turn_preview option;
}

type keeper_turn_state =
  | Turn_idle
  | Turn_active of active_turn
  | Turn_unavailable of string

type keeper_turn_row = {
  keeper_name : string;
  chat_control_token : string option;
  state : keeper_turn_state;
}

(** Why the server has no measured context ratio for a keeper's newest turn
    (the closed reason set of [context_metrics_unavailable_reason]). *)
type context_unavailable_reason =
  | Context_measurement_missing
  | Context_record_undecodable
  | Context_record_read_failed
  | Context_record_without_usage
  | Context_trace_mismatch
  | Context_cumulative_usage
  | Context_turn_total_usage
  | Context_usage_scope_unavailable
  | Context_tokens_exceed_window
  | Context_input_estimate
  | Context_input_provenance_unavailable

(** The server's context projection for a keeper's newest turn record.
    [Context_measured] is a dispatched request's provider-reported input;
    [ratio] is [None] when no window was reported. [Context_not_measured]
    carries the reason and, for an estimated input, the server's estimate. *)
type context_reading =
  | Context_measured of {
      ratio : float option;
      tokens : int;
      window : int option;
      absolute_turn : int option;
      measured_at_unix : float option;
    }
  | Context_not_measured of {
      reason : context_unavailable_reason;
      estimated_ratio : float option;
    }

type keeper_summary = {
  name : string;
  group : string option;
  company : string;
  health : keeper_health;
  paused : bool;
  keepalive_running : bool;
  activation_mode : activation_mode;
  runtime_id : string;
  model_id : string option;
  current_task_id : string option;
  context : context_reading Observed.t;
      (** [Unreported] when the row has no [context_provenance]. *)
  total_turns : int Observed.t;
  last_turn_at_unix : float option;
  active_turn : active_turn option;
}

(** A roster row whose effective meta did not read: the server sends only the
    name and [effective_meta_error.message]. *)
type unreadable_keeper = {
  name : string;
  reason : string;
}

type keepers_roster = {
  keepers : keeper_summary list;
  unreadable : unreadable_keeper list;
}

type attention_bucket =
  | Bucket_asks
  | Bucket_approvals
  | Bucket_confirmations

type attention_item = {
  id : string;
  bucket : attention_bucket;
  kind : Health.attention_kind;
  title : string;
  summary : string;
  created_at_unix : float option;
  keeper : string option;
}

type keeper_sandbox_profile =
  | Profile_microvm
  | Profile_remote_ssh
  | Profile_docker
  | Profile_other of string

type candle_supply = {
  issued_milli : string;
  burned_milli : string;
  circulating_milli : string;
}

(** The top-level [candle] object (Candle_observation): only a ready ledger
    carries a supply. *)
type candle_observation =
  | Candle_off
  | Candle_disabled of { reason : string }
  | Candle_ready of candle_supply

(** One half-hour slot of a keeper's turn pulse. Each turn is counted twice:
    by outcome ([ok] [rested] [failed]) and by what started it. *)
type turn_slot = {
  starts_at : int;  (** Unix seconds, a multiple of {!turn_slot_seconds}. *)
  ok : int;
  rested : int;
  failed : int;
  scheduled : int;
  reacted : int;
  chat : int;
  own : int;
  unknown : int;
}

type turn_pulse = {
  known_since : float;
      (** The server knows every turn that ended at or after this Unix time. *)
  slots : turn_slot list;  (** Oldest first; a slot with no turn is absent. *)
}

val turn_slot_seconds : int
(** 1800, the server's slot width. *)

val pulse_window_slots_24h : int
(** 48 half-hour slots covering the last 24 hours. *)

val sparkline_24h_of_pulse : now_unix:float -> turn_pulse -> float list
(** 48 half-hour slots ending at the slot holding [now_unix], oldest first.
    Each slot counts executed turns ([ok + failed]); quiet slots are [0.0],
    and slots older than 24h before [now_unix] are excluded. *)

val turns_24h_of_pulse : now_unix:float -> turn_pulse -> int
(** Sum of executed turns ([ok + failed]) in the 48 half-hour slots ending at
    the slot holding [now_unix], matching server
    [Keeper_turn_pulse.turns_in_window]. *)

type keeper_roster_extras = {
  sandbox_profiles : (string * keeper_sandbox_profile) list;
  candle_balances_milli : (string * int) list;
  candle_summary : candle_observation option;
  turn_pulses : (string * turn_pulse) list;
}

type execution_keeper_enrichment = {
  keeper_name : string;
  sandbox_profile : keeper_sandbox_profile option;
  total_turns : int option;
}

type company_group = {
  company : string;
  keepers : keeper_summary list;
  running_count : int;
  working_count : int;
  failing_count : int;
  paused_count : int;
  attention_count : int;
  microvm_count : int;
  ssh_count : int;
  docker_count : int;
  turns_24h : int;
  cost_24h_usd : float;
  sparkline_24h : float list;
}

type daily_scorecard = {
  tasks_done_24h : int Observed.t;
  tasks_done_total : int Observed.t;
  tasks_in_progress : int Observed.t;
  tasks_claimed : int Observed.t;
  tasks_awaiting_verification : int Observed.t;
  tasks_todo : int Observed.t;
  tasks_cancelled : int Observed.t;
  goals_completed_24h : int Observed.t;
  verifications_passed_24h : int Observed.t;
  verifications_rejected_24h : int Observed.t;
  board_posts_24h : int Observed.t;
  turns_24h : int Observed.t;
  cost_24h_usd : float Observed.t;
}

type shell_counts = {
  agents : int;
  tasks : int;
  tasks_done_24h : int;
  keepers : int;
  persisted_keepers : int Observed.t;
  configured_keepers : int Observed.t;
  total_runtimes : int;
}

type shell_group = {
  group : string;
  keeper_count : int;
  keepers : string list;
}

type dashboard_shell = {
  generated_at_unix : float option;
  project : string option;
  version : string option;
  counts : shell_counts;
  scorecard_24h : daily_scorecard;
  groups : shell_group list;
}

val classify_company_single : group:string option -> string -> string option
(** Deployment-neutral group resolver: honors trimmed explicit [group]
    metadata from [keeper.group] TOML, returning [None] when absent or blank so
    {!group_by_company} can fall back to shared dash-prefix families or
    ["Other"]. *)

val group_by_company :
  ?attention:attention_item list ->
  ?sandbox_profiles:(string * keeper_sandbox_profile) list ->
  ?keeper_costs_24h:(string * float) list ->
  ?now_unix:float ->
  ?turn_pulses:(string * turn_pulse) list ->
  keeper_summary list ->
  company_group list
(** Group Keepers by explicit [keeper.group] metadata (falling back to shared
    dash-prefix families when 2+ keepers share a prefix, otherwise ["Other"]),
    enriched with infra mix, 24h turn counts, 24h USD cost rollup, and
    aggregated 24h sparkline. Named groups sort alphabetically with ["Other"]
    last. *)

val keeper_health_of_string : string -> keeper_health option
val activation_mode_of_string : string -> activation_mode option
val turn_lane_of_string : string -> turn_lane option
val turn_preview_activity_of_string : string -> turn_preview_activity option
val turn_preparation_phase_of_string : string -> turn_preparation_phase option
val turn_preparation_state_of_string : string -> turn_preparation_state option

val equal_turn_lane : turn_lane -> turn_lane -> bool
val equal_turn_preview_activity : turn_preview_activity -> turn_preview_activity -> bool
val equal_turn_preparation_phase : turn_preparation_phase -> turn_preparation_phase -> bool
val equal_turn_preparation_state : turn_preparation_state -> turn_preparation_state -> bool
val equal_turn_preparation : turn_preparation -> turn_preparation -> bool
val equal_turn_preview : turn_preview -> turn_preview -> bool

val decode_turn_preview_update :
  Yojson.Safe.t -> (turn_preview_update, string) result
val preview_update_belongs_to_turn : turn_preview_update -> active_turn -> bool
val equal_active_turn : active_turn -> active_turn -> bool

val decode_keepers_roster :
  observed_at:Clock.Mono.t -> Yojson.Safe.t -> (keepers_roster, string) result
(** A row with an [effective_meta_error] object decodes into [unreadable];
    every other row must be a full keeper summary. *)

val decode_keepers_roster_extras :
  Yojson.Safe.t -> (keeper_roster_extras, string) result
(** Decode companion metadata ([meta.sandbox_profile], [candle_balance_milli],
    top-level [candle] summary) from [GET /api/v1/gate/keepers?detailed=true&fresh=true]. *)

val decode_execution_keeper_enrichments :
  Yojson.Safe.t ->
  (execution_keeper_enrichment list * candle_observation option, string) result
(** Decode per-keeper [sandbox_profile] / turn count and the top-level
    [candle] observation from [GET /api/v1/dashboard/execution?light=true]. *)

(** {1 Keeper Turn Records ([GET /api/v1/keepers/:name/turn-records])} *)

type turn_usage_scope =
  | Usage_per_request
  | Usage_turn_total
  | Usage_conversation_cumulative
  | Usage_scope_unavailable

type turn_input_provenance =
  | Input_measured_request
  | Input_context_estimate

type turn_record_row = {
  absolute_turn : int;
  input_tokens : int option;
  usage_scope : turn_usage_scope;
  input_provenance : turn_input_provenance option;
  context_window : int option;
  provider_context_window : int option;
}

type keeper_turn_records = {
  keeper : string;
  skipped_rows : int;
  rows : turn_record_row list;  (** Oldest first, as the server sends them. *)
}

val keeper_turn_records_path : keeper:string -> limit:int -> string
(** [limit] is clamped to the server's [1..500]. *)

val decode_keeper_turn_records :
  Yojson.Safe.t -> (keeper_turn_records, string) result

val turn_record_context_fill : turn_record_row -> float option
(** The record's measured context fill (input / window), under the rule the
    server applies to a keeper's newest record: per-request usage, input
    provenance [measured_request], the provider window else the configured
    one, and input not above that window. [None] for every other record. *)

val decode_keeper_turns : Yojson.Safe.t -> (keeper_turn_row list, string) result

val decode_attention_item : Yojson.Safe.t -> (attention_item, string) result

val decode_daily_scorecard :
  observed_at:Clock.Mono.t -> Yojson.Safe.t -> (daily_scorecard, string) result

val decode_dashboard_shell :
  observed_at:Clock.Mono.t -> Yojson.Safe.t -> (dashboard_shell, string) result
(** Decode [GET /api/v1/dashboard/shell] ([counts], [scorecard_24h], [groups],
    [status]). *)

(** {1 Fleet SSE Stream Events ([/api/v1/stream/fleet])} *)

type fleet_stream_reading = {
  status : string;
  operator_action_required : bool;
  bootable_count : int;
  running_count : int;
  executable_count : int;
  failing_count : int;
  recovering_count : int;
  paused_count : int;
  proactive_interval_sec : int option;
}

type fleet_degradation = {
  since_unix : float;
  reason : string;
}

type fleet_stream_event =
  | Fleet_snapshot of {
      schema : int;
      revision : int;
      measured_at_unix : float;
      reading : fleet_stream_reading;
      degraded : fleet_degradation option;
    }
  | Fleet_changed of {
      revision : int;
      measured_at_unix : float;
      reading : fleet_stream_reading;
    }
  | Fleet_unavailable_snapshot of {
      schema : int;
      revision : int;
      degradation : fleet_degradation;
    }
  | Fleet_degraded of {
      revision : int;
      degradation : fleet_degradation;
    }

val decode_fleet_stream_event :
  Yojson.Safe.t -> (fleet_stream_event, string) result

(** {1 Keeper Chat Messages, Stream Chunks & Submit Requests} *)

(** The route a [user] row arrived by: the server's [surface.kind]. *)
type chat_surface =
  | Surface_dashboard
  | Surface_agent  (** [masc_keeper_msg] and workspace @mention delivery *)
  | Surface_broadcast  (** a fleet broadcast copied into every Keeper *)
  | Surface_discord
  | Surface_slack
  | Surface_webhook
  | Surface_gate of string  (** the gate's channel label *)

(** Who wrote a [user] row the operator did not write. The server sets
    [speaker_authority] from the arrival route, never from the text. *)
type chat_peer =
  | Peer_keeper of string  (** ["keeper"]: [speaker_name], else [speaker_id] *)
  | Peer_external of string
      (** ["external"]: a connector author; [speaker_name], else [speaker_id] *)
  | Peer_unresolved of string option
      (** No [speaker_authority], or neither name nor id: the [speaker_id]
          when the server sent one. *)

type chat_role =
  | Role_user
      (** The operator wrote it: role ["operator"], or ["user"] with
          [speaker_authority] ["owner"]. *)
  | Role_peer of {
      peer : chat_peer;
      surface : chat_surface option;
    }
      (** Any other ["user"] row: a Keeper's message or broadcast, a connector
          author, or an author the server did not record. The Keeper reads it
          as user input, but the operator did not write it. *)
  | Role_assistant
  | Role_system
  | Role_tool
  | Role_request_failure

type chat_origin =
  | Origin_bare
  | Origin_connector of string

type submit_mode =
  | Follow_up
  | Steer of {
      control_token : string;
      operation_id : string;
    }
(** [Follow_up] sends no [admission_intent]: the server queues the message
    behind whatever turn holds the Keeper. [Steer] cuts exactly
    [operation_id], an operation this client submitted. The server resolves
    that id against its operation store and cuts it only while it is the one
    running, so a steer never reaches a turn this client did not start. *)

type chat_attachment = {
  attachment_id : string;
  name : string;
  mime_type : string;
  size : int;
  data_base64 : string;
}

type chat_submit_request = {
  request_id : string;
  keeper_name : string;
  message : string;
  origin : chat_origin;
  mode : submit_mode;
  turn_instructions : string option;
  since_seq : int option;
  attachments : chat_attachment list;
}

type chat_message = {
  id : string;
  role : chat_role;
  content : string;
  ts_unix : float;
  turn_ref : string option;
  model_used : string option;
  tool_call_id : string option;
  tool_call_name : string option;
  execution_id : string option;
  provenance : Keeper_chat_delivery_identity.delivery_provenance option;
  failure_kind : string option;
}

type chat_history_page = {
  messages : chat_message list;
  has_more : bool;
  next_cursor : string option;
}

type chat_operation = {
  id : Keeper_chat_operation.Operation_id.t;
  sequence : int64;
  state : Keeper_chat_operation.State_name.t;
  message : string option;
  failure_detail : string option;
}

val chat_queue_path : keeper:string -> after:int64 option -> string
val chat_operation_path : keeper:string -> operation_id:string -> string
val is_absent_operation_error : keeper:string -> operation_id:string -> status:int -> body:string -> bool
(** Only a scoped 404 from a successful exact owner lookup carries this evidence. *)

val decode_chat_operation : Yojson.Safe.t -> (chat_operation, string) result
val decode_chat_queue :
  after:int64 option -> Yojson.Safe.t -> (chat_operation list, string) result

val accepted_input_operation : chat_message -> string option
val terminal_operation : chat_message -> string option
(** Operation identity from the persisted delivery key, slot and row role. *)

type interactive_outcome =
  | Interactive_applied
  | Interactive_stale_control
  | Interactive_paused
  | Interactive_replayed

type turn_interrupt_response = {
  signalled : bool;
  paused : bool;
  chat_control_token : string option;
  reason : string option;
}

type model_content_channel = Content_text | Content_thinking

type model_content_state = Content_observed | Content_ended

type model_content_activity = {
  owner : Wire_chat_journal.response_owner;
  block_index : int;
  channel : model_content_channel;
  content_state : model_content_state;
}

type chat_stream_chunk =
  | Chunk_accepted of {
      operation_id : string;
      queued_count : int;
      state : Keeper_chat_operation.State_name.t;
      interactive_outcome : interactive_outcome option;
      control_token : string option;
    }
  | Chunk_run_started of { operation_id : string option }
  | Chunk_runtime_attempt_started of {
      operation_id : string option;
      runtime_id : string option;
      attempt_index : int option;
    }
  | Chunk_provider_retry of {
      operation_id : string option;
      runtime_id : string option;
      attempt : int;
      max_retries : int;
      retry_delay_ms : int;
      error_status : int option;
    }
  | Chunk_continuation_checkpoint of {
      operation_id : string option;
      message : string;
      request_id : string option;
    }
  | Chunk_native_tool_progress of {
      operation_id : string option;
      tool_use_id : string;
      tool_name : string option;
      progress_label : string;
    }
  | Chunk_stream_protocol_error of {
      operation_id : string option;
      kind : string;
      reason : string option;
    }
  | Chunk_text_delta of {
      operation_id : string option;
      delta : string;
      owner : Wire_chat_journal.text_owner;
    }
  | Chunk_thinking_delta of {
      operation_id : string option;
      delta : string;
      owner : Wire_chat_journal.response_owner option;
    }
  | Chunk_thinking_snapshot of {
      operation_id : string option;
      snapshot : string;
      owner : Wire_chat_journal.response_owner option;
    }
  | Chunk_model_content of {
      operation_id : string option;
      activity : model_content_activity;
    }
  | Chunk_model_response_start of {
      operation_id : string option;
      content_generation : int option;  (** Absent from older journal entries. *)
      stream_scope : int;
    }
  | Chunk_model_response_stop of {
      operation_id : string option;
      owner : Wire_chat_journal.response_owner option;
    }
  | Chunk_tool_start of {
      operation_id : string option;
      tool_use_id : string;
      stream_scope : int option;
      tool_name : string;
      args_preview : string option;
    }
  | Chunk_tool_args of {
      operation_id : string option;
      tool_use_id : string;
      delta : string option;
      snapshot : string option;
    }
  | Chunk_tool_block_end of { operation_id : string option; tool_use_id : string }
  | Chunk_tool_end of {
      operation_id : string option;
      tool_use_id : string;
      tool_name : string option;
      ok : bool option;
      output_preview : string option;
    }
  | Chunk_tool_quarantined of {
      operation_id : string option;
      tool_use_id : string;
      kind : string;
      reason : string option;
    }
  | Chunk_reply_details of {
      operation_id : string option;
      reply : string;
      turn_outcome : string option;
      turn_ref : string option;
    }
  | Chunk_turn_done of {
      operation_id : string option;
      turn_ref : string option;
      reply : string option;
    }
  | Chunk_error of {
      operation_id : string option;
      code : string option;
      message : string;
    }
  | Chunk_ignored

val encode_chat_submit_request : chat_submit_request -> Yojson.Safe.t
(** Encode a strict allowlist request body for [POST /api/v1/keepers/chat/stream].
    Emits only server-declared keys ([request_id], [name], [message], optional
    [channel], [turn_instructions], [since_seq], [attachments], and structured
    [admission_intent] object for [Steer]). *)

val decode_chat_history : Yojson.Safe.t -> (chat_message list, string) result
(** Decode the bare JSON array returned by [GET /api/v1/keepers/:name/chat/history]. *)

val decode_chat_history_page : Yojson.Safe.t -> (chat_history_page, string) result
(** Decode the paginated envelope returned by
    [GET /api/v1/keepers/:name/chat/history/page]. *)

val decode_chat_stream_chunk : Yojson.Safe.t -> (chat_stream_chunk, string) result
(** Decode real server AG-UI SSE frames ([CUSTOM], [RUN_STARTED],
    [TEXT_MESSAGE_CONTENT], [TOOL_CALL_*], [RUN_FINISHED], [RUN_ERROR]) as well
    as legacy test aliases. Returns [Ok Chunk_ignored] for known non-visual
    AG-UI lifecycle/diagnostic frames and [Error] for unknown/malformed frames.
    A tool block can end before its tool result is observed. *)

val decode_turn_interrupt_response :
  Yojson.Safe.t -> (turn_interrupt_response, string) result
(** Decode [POST /api/v1/keepers/turn/interrupt] JSON response. *)
