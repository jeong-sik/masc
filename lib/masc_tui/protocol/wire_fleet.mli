(** Pulse, Fleet, Company grouping, 3-bucket Attention, Keeper Live Turns,
    Daily Achievement Scorecard, Fleet SSE deltas, and Keeper Chat wire codecs. *)

open Masc_tui_core

val dashboard_shell_path : string
val dashboard_keepers_path : string
val keepers_turns_path : string
val fleet_stream_path : string
val keeper_chat_stream_path : string
val keeper_turn_interrupt_path : string

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

type active_turn = {
  lane : turn_lane;
  started_at_unix : float;
  interrupt_token : string;
  phase : string option;
  tool_in_flight : string option;
  elapsed_ms : float option;
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
  context_ratio : float Observed.t;
  total_turns : int Observed.t;
  total_tokens : int Observed.t;
  cost_24h_usd : float Observed.t;
  last_turn_at_unix : float option;
  active_turn : active_turn option;
  activity_sparkline_24h : float list;
}

type attention_bucket =
  | Bucket_asks
  | Bucket_approvals
  | Bucket_confirmations_quarantine

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

type candle_summary_fallback = {
  issued_milli : string;
  burned_milli : string;
  circulating_milli : string;
}

type keeper_roster_extras = {
  sandbox_profiles : (string * keeper_sandbox_profile) list;
  candle_balances_milli : (string * int) list;
  candle_summary : candle_summary_fallback option;
}

type execution_keeper_enrichment = {
  keeper_name : string;
  context_ratio : float option;
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
  prs_reviewed_24h : int Observed.t;
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

val decode_keeper_summary :
  observed_at:Clock.Mono.t -> Yojson.Safe.t -> (keeper_summary, string) result

val decode_keepers_roster :
  observed_at:Clock.Mono.t -> Yojson.Safe.t -> (keeper_summary list, string) result

val decode_keepers_roster_extras :
  Yojson.Safe.t -> (keeper_roster_extras, string) result
(** Decode companion metadata ([meta.sandbox_profile], [candle_balance_milli],
    top-level [candle] summary) from [GET /api/v1/gate/keepers?detailed=true&fresh=true]. *)

val decode_execution_keeper_enrichments :
  Yojson.Safe.t ->
  (execution_keeper_enrichment list * candle_summary_fallback option, string) result
(** Decode per-keeper [context_ratio] / [sandbox_profile] and top-level
    [candle] summary from [GET /api/v1/dashboard/execution?light=true]. *)

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
  operation_id : string option;
  transcript_slot : string option;
  failure_kind : string option;
}

type chat_history_page = {
  messages : chat_message list;
  has_more : bool;
  next_cursor : string option;
}

type accepted_state =
  | Accepted_queued
  | Accepted_running
  | Accepted_succeeded
  | Accepted_failed
  | Accepted_cancelled

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

type chat_stream_chunk =
  | Chunk_accepted of {
      operation_id : string;
      queued_count : int;
      state : accepted_state;
      interactive_outcome : interactive_outcome option;
      control_token : string option;
    }
  | Chunk_run_started of { operation_id : string option }
  | Chunk_text_delta of { operation_id : string option; delta : string }
  | Chunk_thinking_delta of { operation_id : string option; delta : string }
  | Chunk_thinking_snapshot of {
      operation_id : string option;
      snapshot : string;
    }
  | Chunk_tool_start of {
      operation_id : string option;
      tool_use_id : string;
      tool_name : string;
      args_preview : string option;
    }
  | Chunk_tool_args of {
      operation_id : string option;
      tool_use_id : string;
      delta : string option;
      snapshot : string option;
    }
  | Chunk_tool_end of {
      operation_id : string option;
      tool_use_id : string;
      tool_name : string option;
      ok : bool option;
      output_preview : string option;
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
    AG-UI lifecycle/diagnostic frames and [Error] for unknown/malformed frames. *)

val decode_turn_interrupt_response :
  Yojson.Safe.t -> (turn_interrupt_response, string) result
(** Decode [POST /api/v1/keepers/turn/interrupt] JSON response. *)
