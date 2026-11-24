(** Per-keeper Context & Turns Inspector + Tool Calls sub-store.

    Stores per-keeper turn records, turn stepper cursor, 4 context sub-tabs
    ([Ctx_composition | Ctx_exact_input | Ctx_input_map | Ctx_response]),
    lazy caches for [provider-input], [provider-input/part], [cache-outcome],
    [next-request], [turn-transcript], [call_evidence], and per-keeper
    [tool-stats] / [tool-calls] / [tool-result] — ALL guarded against stale
    [(keeper, turn_ref)] or [(keeper, execution_id)] responses. *)

open Masc_tui_core
open Masc_tui_protocol

module String_map : Map.S with type key = string

type context_subtab =
  | Ctx_composition
  | Ctx_exact_input
  | Ctx_input_map
  | Ctx_response

type keeper_state = {
  turn_records : Wire_keeper_context.turn_records_page Observed.t;
  selected_turn_idx : int;
  subtab : context_subtab;
  provider_input : (string * Wire_keeper_context.provider_input_manifest) Observed.t;
  provider_input_auth_denied : bool;
  absent_provider_input_ref : string option;
  selected_part_idx : int;
  part_content :
    (string * int * Wire_keeper_context.provider_input_part_content) Observed.t;
  cache_outcome : (string * Keeper_cache_outcome_reading.reading) Observed.t;
  absent_cache_outcome_ref : string option;
  next_request : Wire_keeper_context.next_request_forecast Observed.t;
  next_request_absent : bool;
  turn_transcript : (string * Wire_keeper_context.turn_transcript) Observed.t;
  absent_transcript_ref : string option;
  call_evidence : (string * Wire_keeper_context.tool_call_entry list) Observed.t;
  call_evidence_auth_denied : bool;
  absent_call_evidence_ref : string option;
  scroll_offset : int;
  tool_stats : Wire_keeper_context.keeper_tool_stats Observed.t;
  tool_stats_absent : bool;
  tool_calls : Wire_keeper_context.keeper_tool_calls_page Observed.t;
  tool_calls_auth_denied : bool;
  tool_calls_absent : bool;
  selected_call_idx : int;
  call_scroll_offset : int;
  call_detail_scroll_offset : int;
  tool_result : (string * Wire_keeper_context.tool_result_response) Observed.t;
  tool_result_auth_denied : bool;
}

type t = {
  by_keeper : keeper_state String_map.t;
}

val empty : t
val empty_keeper_state : keeper_state
val get_keeper : keeper:string -> t -> keeper_state

val equal_context_subtab : context_subtab -> context_subtab -> bool
val all_context_subtabs : context_subtab list
val context_subtab_label : context_subtab -> Say.t
val next_context_subtab : context_subtab -> context_subtab

val selected_turn_entry :
  keeper_state -> Wire_keeper_context.turn_record_entry option

val selected_turn_ref : keeper_state -> string option
val selected_provider_part :
  keeper_state -> Wire_keeper_context.provider_input_part option
val selected_tool_call :
  keeper_state -> Wire_keeper_context.tool_call_entry option

val provider_input_for_selected_turn :
  keeper_state -> Wire_keeper_context.provider_input_manifest option

val part_content_for_selected :
  keeper_state -> Wire_keeper_context.provider_input_part_content option

val cache_outcome_for_selected_turn :
  keeper_state -> Keeper_cache_outcome_reading.reading option

val transcript_for_selected_turn :
  keeper_state -> Wire_keeper_context.turn_transcript option

val call_evidence_for_selected_turn :
  keeper_state -> Wire_keeper_context.tool_call_entry list option

val tool_result_for_selected_call :
  keeper_state -> Wire_keeper_context.tool_result_response option

val cycle_subtab : keeper:string -> t -> t
val set_subtab : keeper:string -> context_subtab -> t -> t
val step_turn : keeper:string -> delta:int -> t -> t
val move_scroll : keeper:string -> ?max_scroll:int -> delta:int -> t -> t
val move_part_selection : keeper:string -> delta:int -> t -> t
val move_call_selection : keeper:string -> ?viewport_rows:int -> delta:int -> t -> t
val move_call_detail_scroll : keeper:string -> ?max_scroll:int -> delta:int -> t -> t

val apply_turn_records :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  Wire_keeper_context.turn_records_page ->
  t ->
  t

val apply_provider_input :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  turn_ref:string ->
  Wire_keeper_context.provider_input_manifest ->
  t ->
  t

val mark_provider_input_denied :
  at:Clock.Mono.t -> keeper:string -> ?turn_ref:string -> reason:string -> t -> t
val mark_provider_input_part_denied :
  at:Clock.Mono.t ->
  keeper:string ->
  turn_ref:string ->
  index:int ->
  reason:string ->
  t ->
  t
val mark_turn_records_failed :
  at:Clock.Mono.t -> keeper:string -> reason:string -> retryable:bool -> t -> t
val mark_provider_input_absent : keeper:string -> turn_ref:string -> t -> t
val mark_cache_outcome_absent : keeper:string -> turn_ref:string -> t -> t
val mark_turn_transcript_absent : keeper:string -> turn_ref:string -> t -> t
val mark_call_evidence_absent : keeper:string -> turn_ref:string -> t -> t
val mark_next_request_absent : keeper:string -> t -> t
val mark_tool_calls_absent : keeper:string -> t -> t
val mark_tool_stats_absent : keeper:string -> t -> t
val mark_tool_result_denied :
  at:Clock.Mono.t ->
  keeper:string ->
  ?execution_id:string ->
  reason:string ->
  t ->
  t

val apply_provider_input_part :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  turn_ref:string ->
  index:int ->
  Wire_keeper_context.provider_input_part_content ->
  t ->
  t

val apply_cache_outcome :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  turn_ref:string ->
  Keeper_cache_outcome_reading.reading ->
  t ->
  t

val apply_next_request :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  Wire_keeper_context.next_request_forecast ->
  t ->
  t

val apply_turn_transcript :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  turn_ref:string ->
  Wire_keeper_context.turn_transcript ->
  t ->
  t

val apply_call_evidence :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  turn_ref:string ->
  Wire_keeper_context.tool_call_entry list ->
  t ->
  t

val mark_call_evidence_denied :
  at:Clock.Mono.t -> keeper:string -> ?turn_ref:string -> reason:string -> t -> t

val apply_tool_stats :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  Wire_keeper_context.keeper_tool_stats ->
  t ->
  t

val apply_tool_calls :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  Wire_keeper_context.keeper_tool_calls_page ->
  t ->
  t

val mark_tool_calls_denied :
  at:Clock.Mono.t -> keeper:string -> reason:string -> t -> t

val apply_tool_result :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  execution_id:string ->
  Wire_keeper_context.tool_result_response ->
  t ->
  t

val mark_stale_all : t -> t
