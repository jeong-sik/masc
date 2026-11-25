(** Fleet & Pulse domain sub-store: Dashboard Shell & Daily Scorecard,
    Companies & Keepers roster (3 grouping modes: [Companies | Attention |
    24h Wall]), live turns, Fleet SSE stream readings, Keeper Chat transcripts
    and streaming buffers, and 5-tab Keeper Dive state.

    Channel 2 live health invariant: live [keeper_summary.health] is updated
    strictly from authoritative server snapshots and heartbeats, never from
    Channel 3 historical incidents or transient HTTP errors. *)

open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

module String_map : Map.S with type key = string
module String_set : Set.S with type elt = string

module Operation_map : Map.S with type key = string * string
(** Keyed by [(keeper, operation_id)]. *)

type chat_display_origin =
  | Display_origin_bare
  | Display_origin_inline
  | Display_origin_row

type thinking_display =
  | Thinking_folded
  | Thinking_full
  | Thinking_hidden

type tool_call_state =
  | Tool_pending
  | Tool_result_pending of { model_output_after_close : bool }
  | Tool_settled
  | Tool_unfinished

type active_tool_call = {
  tool_use_id : string;
  stream_scope : int option;
  tool_name : string;
  args_preview : string option;
  progress_label : string option;
  tool_state : tool_call_state;
  ok : bool option;
  output_preview : string option;
}

type chat_queue = {
  operations : Wire_fleet.chat_operation list;
  read : unit Observed.t;
}

type model_activity
type response_start

type chat_stream_buffer = {
  request_id : string;
  operation_id : string option;
  turn_ref : string option;
  run_started : bool;
  interrupting : bool;
  text : string;
  text_ownership : Cut_reply.ownership;
  thinking : string;
  model_activity : model_activity;
  response_start : response_start option;  (** Evidence from message-start frames in this run. *)
  tools : active_tool_call list;
  active_runtime_id : string option;
  attempt_index : int option;
  retry_notice : string option;
  checkpoint_notice : string option;
  protocol_warning : string option;
  active : bool;
  ended : bool;
  last_error : string option;
}

val empty_model_activity : model_activity

val current_model_content : chat_stream_buffer -> Wire_fleet.model_content_channel option
val current_tool : chat_stream_buffer -> active_tool_call option

type t = {
  shell : Wire_fleet.dashboard_shell Observed.t;
  raw_shell_scorecard : Wire_fleet.daily_scorecard option;
  keepers : Wire_fleet.keeper_summary list Observed.t;
  unreadable_keepers : Wire_fleet.unreadable_keeper list;
      (** Roster rows whose effective meta did not read, from the last roster. *)
  turns : Wire_fleet.keeper_turn_row list Observed.t;
  turn_preview_updates : Wire_fleet.turn_preview_update String_map.t;
  interrupting_turn_tokens : string String_map.t;
      (** In-flight interrupt token per keeper for observed turns without a
          local chat stream or pending tx. *)
  esc_attempted_turn_tokens : string String_map.t;
  esc_attempted_operation_ids : string String_map.t;
  turn_records : Wire_fleet.keeper_turn_records Observed.t String_map.t;
      (** Recent turn records per keeper, read for the Ctrl+T Context tab. *)
  chat_control_tokens : string String_map.t;
  sandbox_profiles : Wire_fleet.keeper_sandbox_profile String_map.t;
  candle_balances_milli : int String_map.t;
  candle_summary_fallback : Wire_fleet.candle_observation option;
  turn_pulses : Wire_fleet.turn_pulse String_map.t;
      (** Each keeper's turn pulse from the last roster read. *)
  wall_unix : float;
      (** Current wall-clock Unix seconds used to anchor 24h pulse windows. *)
  fleet_reading : Wire_fleet.fleet_stream_reading Observed.t;
  fleet_degradation : Wire_fleet.fleet_degradation option;
  fleet_mode : Nav.keepers_fleet_mode;
  selected_index : int;
  scroll_offset : int;
  pulse_scroll_offset : int;
  filter_query : string;
  selected_keeper : string option;
  selected_collapsed_company : string option;
  collapsed_companies : String_set.t;
  chat_histories : Wire_fleet.chat_history_page Observed.t String_map.t;
  chat_queues : chat_queue String_map.t;
  chat_streams : chat_stream_buffer String_map.t;
  cut_replies : Cut_reply.t Observed.t Operation_map.t;
      (** The reply text each cut operation's journal holds, read for its
          failure row. *)
  chat_origin_mode : chat_display_origin;
  chat_tools_mode : Slash.tools_mode;
  chat_thinking_mode : thinking_display;
  chat_turn_details_expanded : bool;
  chat_scroll_offset : int;
  keeper_dive_tab : Nav.keeper_tab;
}

val empty : t

val equal_chat_display_origin : chat_display_origin -> chat_display_origin -> bool
val equal_thinking_display : thinking_display -> thinking_display -> bool

val keeper_live_state : Wire_fleet.keeper_summary -> Health.live_state
(** Project authoritative [keeper_health] onto Channel 2 {!Health.live_state}. *)

(** What a context cell shows for one [Wire_fleet.context_reading]. *)
type context_display =
  | Context_fill of { ratio : float; estimated : bool }
      (** [ratio] clamped to [[0, 1]]; [estimated] marks the server's estimate. *)
  | Context_tokens_only of int
      (** A measured input with no reported window. *)
  | Context_unavailable of Wire_fleet.context_unavailable_reason

val context_display : Wire_fleet.context_reading -> context_display

val context_fill_label : estimated:bool -> float -> string
(** ["42%"], or ["~42%"] for an estimate. *)

val context_unavailable_label : Wire_fleet.context_unavailable_reason -> Say.t
(** Short label for why the server has no measured context ratio. *)

type fleet_health_counts = {
  total : int;
  active : int;
  working : int;
  healthy : int;
  degraded : int;
  failing : int;
  paused : int;
  offline : int;
}
(** Single-source-of-truth health breakdown across Pulse Hero, Pulse Companies,
    and Keepers Fleet. Strictly separates [offline] (ordinary stopped keepers)
    from [failing] (true live execution faults).
    Invariant: [active = working + healthy + degraded] and
    [active + failing + paused + offline = total]. *)

val fleet_health_counts : Wire_fleet.keeper_summary list -> fleet_health_counts
(** Compute {!fleet_health_counts} over a keeper list. *)

type companies_nav_row =
  | Nav_company_collapsed of string
  | Nav_keeper of Wire_fleet.keeper_summary

val filtered_keepers : t -> Wire_fleet.keeper_summary list
val companies_nav_rows : t -> companies_nav_row list
val company_groups :
  ?attention:Wire_fleet.attention_item list ->
  ?now_unix:float ->
  t ->
  Wire_fleet.company_group list
val company_groups_with_costs :
  ?attention:Wire_fleet.attention_item list ->
  ?now_unix:float ->
  keeper_costs_24h:(string * float) list ->
  t ->
  Wire_fleet.company_group list
val sandbox_profile_of : keeper:string -> t -> Wire_fleet.keeper_sandbox_profile option
val fleet_infra_counts : t -> int * int * int
(** [(microvm_count, remote_ssh_count, docker_count)] derived from keeper
    [meta.sandbox_profile]. *)
val set_wall_unix : float -> t -> t
(** Advance the fleet store's wall clock used to anchor 24h pulse windows and
    activity ordering. *)
val sparkline_24h : now_unix:float -> keeper:string -> t -> float list
(** 48 half-hour slots ending at the slot holding [now_unix] for [keeper]'s
    turn pulse, or [[]] when [keeper] has no turn pulse. *)
val keeper_turns_24h : now_unix:float -> keeper:string -> t -> int option
(** Executed turns ([ok + failed]) in the 24h window ending at [now_unix] for
    [keeper], or [None] when [keeper] has no turn pulse. *)
val total_turns_24h : now_unix:float -> t -> int option
(** Sum of executed turns ([ok + failed]) in the 24h window ending at [now_unix]
    across keepers in the fleet with turn pulse data, or [None] when no keeper
    has pulse data yet. *)
val find_keeper : name:string -> t -> Wire_fleet.keeper_summary option
val selected_keeper_summary : t -> Wire_fleet.keeper_summary option
val selected_company_keeper : t -> Wire_fleet.keeper_summary option
(** Resolve the selected keeper across {!company_groups} regardless of
    [collapsed_companies] (for Pulse company-row highlight and dive). *)
val chat_control_token_for : keeper:string -> t -> string option
val update_chat_control_token : keeper:string -> token:string -> t -> t
val active_turn_for : keeper:string -> t -> Wire_fleet.active_turn option
val has_active_chat_stream : keeper:string -> t -> bool

val apply_shell :
  observed_at:Clock.Mono.t -> Wire_fleet.dashboard_shell -> t -> t
val apply_keepers :
  observed_at:Clock.Mono.t -> Wire_fleet.keeper_summary list -> t -> t
val apply_roster :
  observed_at:Clock.Mono.t -> Wire_fleet.keepers_roster -> t -> t
(** [apply_keepers] for the readable rows; replaces [unreadable_keepers]. *)
val apply_roster_extras : Wire_fleet.keeper_roster_extras -> t -> t

val turn_pulse : t -> string -> Wire_fleet.turn_pulse option
(** The named keeper's turn pulse, [None] when the last roster read sent none. *)
val apply_execution_enrichments :
  observed_at:Clock.Mono.t ->
  Wire_fleet.execution_keeper_enrichment list * Wire_fleet.candle_observation option ->
  t ->
  t
val enrich_scorecard :
  (Wire_fleet.daily_scorecard -> Wire_fleet.daily_scorecard) -> t -> t
val apply_turns :
  observed_at:Clock.Mono.t -> Wire_fleet.keeper_turn_row list -> t -> t
val observe_turn_preview :
  keeper:string -> Wire_fleet.turn_preview_update -> t -> t
(** Reconcile a preview only with the matching observed Owner slot. A preview
    received first is available to the next matching turns response. *)
val clear_turn_preview_updates : t -> t
(** [turn_preview_updates] revisions are meaningful within one observer
    process and workspace. *)
val apply_fleet_stream_event :
  observed_at:Clock.Mono.t -> Wire_fleet.fleet_stream_event -> t -> t
val apply_heartbeat :
  keeper:string ->
  phase:string option ->
  in_turn:bool option ->
  at_unix:float ->
  t ->
  t

val apply_chat_history :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  Wire_fleet.chat_history_page ->
  t ->
  t

val start_chat_stream : keeper:string -> request_id:string -> t -> t

val apply_chat_stream_chunk :
  ?allow_takeover:bool ->
  keeper:string ->
  request_id:string ->
  Wire_fleet.chat_stream_chunk ->
  t ->
  t
(** Strictly enforces [request_id] ownership on [chat_streams[keeper]]:
    late chunks/errors from a different [request_id] are dropped unless
    [allow_takeover = true] and either the prior buffer is inactive or the chunk
    signals explicit execution start ([Chunk_run_started] /
    [Chunk_accepted { state = Running }]). *)

val set_operation_interrupting :
  keeper:string -> operation_id:string -> interrupting:bool -> t -> t

val is_operation_interrupting : keeper:string -> operation_id:string -> t -> bool

val mark_turn_interrupting : keeper:string -> interrupt_token:string -> t -> t
val clear_turn_interrupting : keeper:string -> interrupt_token:string -> t -> t
val is_turn_interrupting : keeper:string -> interrupt_token:string -> t -> bool
val mark_esc_interrupt_attempted_turn :
  keeper:string -> interrupt_token:string -> t -> t
val is_esc_interrupt_attempted_turn :
  keeper:string -> interrupt_token:string -> t -> bool
val mark_esc_interrupt_attempted_op :
  keeper:string -> operation_id:string -> t -> t
val is_esc_interrupt_attempted_op :
  keeper:string -> operation_id:string -> t -> bool

val clear_inactive_chat_stream_error : keeper:string -> t -> t

val finish_chat_stream :
  keeper:string -> request_id:string -> error:string option -> t -> t

val detach_chat_streams : t -> t
(** End every active stream buffer and keep what it received. For a new epoch,
    whose guard drops the frames those streams still send. *)

val set_fleet_mode : Nav.keepers_fleet_mode -> t -> t
val cycle_fleet_mode : Keymap.cycle_dir -> t -> t
val set_keeper_dive_tab : Nav.keeper_tab -> t -> t
val cycle_keeper_dive_tab : Keymap.cycle_dir -> t -> t

val cycle_origin_mode : t -> t
val set_tools_mode : Slash.tools_mode -> t -> t
val cycle_tools_mode : t -> t
val cycle_thinking_mode : t -> t
val toggle_turn_details : t -> t

val toggle_company_collapsed : string -> t -> t
val select_keeper : string -> t -> t
val move_selection : ?viewport_rows:int -> delta:int -> t -> t
val move_company_selection : ?viewport_rows:int -> delta:int -> t -> t
(** Step strictly [±delta] company rows in {!company_groups} (for Pulse
    Companies navigation), updating [pulse_scroll_offset] and selecting the
    target company's lead keeper. *)
val move_chat_scroll : ?max_scroll:int -> delta:int -> t -> t
val reset_chat_scroll : t -> t
val set_filter : string -> t -> t

val mark_stale_all : t -> t
val mark_keepers_stale : t -> t
(** Also marks every keeper's [turn_records] stale. *)

val chat_queue_for : keeper:string -> t -> chat_queue
val set_chat_queue :
  keeper:string -> chat_queue -> t -> t

val turn_records_for :
  keeper:string -> t -> Wire_fleet.keeper_turn_records Observed.t
(** [Unreported] when the keeper's turn records were never read. *)

val set_turn_records :
  keeper:string -> Wire_fleet.keeper_turn_records Observed.t -> t -> t

val cut_reply_for :
  keeper:string -> operation_id:string -> t -> Cut_reply.t Observed.t
(** [Unreported] when the operation's journal was never read. *)

val set_cut_reply :
  keeper:string -> operation_id:string -> Cut_reply.t Observed.t -> t -> t

val cut_reply_rows : keeper:string -> t -> (string * string) list
(** [(row id, operation_id)] of each failure row in [keeper]'s loaded history
    that stands for a cut reply: the first failure row of its operation, when
    no assistant row of that operation is in the history. An assistant row of
    an operation is its delivered reply, and a failure settled after it is
    not a cut. *)

val cut_replies_by_row : keeper:string -> t -> string String_map.t
(** The rebuilt text to draw under each {!cut_reply_rows} row, keyed by the
    row id: only rows whose journal was read to the end and left text. *)

val mark_chat_history_loading : keeper:string -> t -> t
val mark_chat_history_failed :
  at:Clock.Mono.t -> keeper:string -> reason:string -> retryable:bool -> t -> t
val mark_chat_history_stale : keeper:string -> t -> t
