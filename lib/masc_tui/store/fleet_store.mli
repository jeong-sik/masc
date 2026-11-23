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

type chat_display_origin =
  | Display_origin_bare
  | Display_origin_inline
  | Display_origin_row

type thinking_display =
  | Thinking_folded
  | Thinking_full
  | Thinking_hidden

type memory_display =
  | Memory_hidden
  | Memory_summary
  | Memory_full

type active_tool_call = {
  tool_use_id : string;
  tool_name : string;
  args_preview : string option;
  completed : bool;
  ok : bool option;
  output_preview : string option;
}

type chat_stream_buffer = {
  request_id : string;
  operation_id : string option;
  turn_ref : string option;
  run_started : bool;
  interrupting : bool;
  prior_msg_ids : String_set.t;
  text : string;
  thinking : string;
  tools : active_tool_call list;
  active : bool;
  last_error : string option;
}

type t = {
  shell : Wire_fleet.dashboard_shell Observed.t;
  raw_shell_scorecard : Wire_fleet.daily_scorecard option;
  keepers : Wire_fleet.keeper_summary list Observed.t;
  turns : Wire_fleet.keeper_turn_row list Observed.t;
  chat_control_tokens : string String_map.t;
  sandbox_profiles : Wire_fleet.keeper_sandbox_profile String_map.t;
  candle_balances_milli : int String_map.t;
  candle_summary_fallback : Wire_fleet.candle_summary_fallback option;
  fleet_reading : Wire_fleet.fleet_stream_reading Observed.t;
  fleet_degradation : Wire_fleet.fleet_degradation option;
  fleet_mode : Nav.keepers_fleet_mode;
  selected_index : int;
  scroll_offset : int;
  pulse_scroll_offset : int;
  filter_query : string;
  selected_keeper : string option;
  collapsed_companies : String_set.t;
  chat_histories : Wire_fleet.chat_history_page Observed.t String_map.t;
  chat_streams : chat_stream_buffer String_map.t;
  chat_origin_mode : chat_display_origin;
  chat_tools_mode : Slash.tools_mode;
  chat_thinking_mode : thinking_display;
  chat_memory_mode : memory_display;
  chat_turn_details_expanded : bool;
  chat_scroll_offset : int;
  keeper_dive_tab : Nav.keeper_tab;
}

val empty : t

val equal_chat_display_origin : chat_display_origin -> chat_display_origin -> bool
val equal_thinking_display : thinking_display -> thinking_display -> bool
val equal_memory_display : memory_display -> memory_display -> bool

val keeper_live_state : Wire_fleet.keeper_summary -> Health.live_state
(** Project authoritative [keeper_health] onto Channel 2 {!Health.live_state}. *)

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

val filtered_keepers : t -> Wire_fleet.keeper_summary list
val company_groups :
  ?attention:Wire_fleet.attention_item list ->
  t ->
  Wire_fleet.company_group list
val company_groups_with_costs :
  ?attention:Wire_fleet.attention_item list ->
  keeper_costs_24h:(string * float) list ->
  t ->
  Wire_fleet.company_group list
val sandbox_profile_of : keeper:string -> t -> Wire_fleet.keeper_sandbox_profile option
val fleet_infra_counts : t -> int * int * int
(** [(microvm_count, remote_ssh_count, docker_count)] derived from keeper
    [meta.sandbox_profile]. *)
val total_turns_24h : t -> int option
(** Sum of 24h turn counts from keeper [activity_sparkline_24h] slots across
    the fleet, or [None] when no keeper has sparkline data yet. *)
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
val apply_roster_extras : Wire_fleet.keeper_roster_extras -> t -> t
val apply_execution_enrichments :
  observed_at:Clock.Mono.t ->
  Wire_fleet.execution_keeper_enrichment list * Wire_fleet.candle_summary_fallback option ->
  t ->
  t
val enrich_scorecard :
  (Wire_fleet.daily_scorecard -> Wire_fleet.daily_scorecard) -> t -> t
val apply_turns :
  observed_at:Clock.Mono.t -> Wire_fleet.keeper_turn_row list -> t -> t
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
    [Chunk_accepted { state = Accepted_running }]). *)

val mark_chat_stream_interrupting :
  keeper:string -> request_id:string -> interrupting:bool -> t -> t

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
val cycle_memory_mode : t -> t
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
val mark_chat_history_loading : keeper:string -> t -> t
val mark_chat_history_failed :
  at:Clock.Mono.t -> keeper:string -> reason:string -> retryable:bool -> t -> t
val mark_chat_history_stale : keeper:string -> t -> t
