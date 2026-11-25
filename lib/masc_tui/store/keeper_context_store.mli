(** Per-keeper Context & Turns Inspector + Tool Calls sub-store.

    Stores per-keeper turn records, turn stepper cursor, 5 context sub-tabs
    ([Ctx_composition | Ctx_flow | Ctx_exact_input | Ctx_input_map | Ctx_response]),
    lazy caches for [provider-input], [provider-input/part], [cache-outcome],
    [next-request], [turn-transcript], [call_evidence], [turn_flow],
    [checkpoints], [operator_note], and per-keeper
    [tool-stats] / [tool-calls] / [tool-result] — ALL guarded against stale
    [(keeper, turn_ref)] or [(keeper, execution_id)] responses. *)

open Masc_tui_core
open Masc_tui_protocol

module String_map : Map.S with type key = string
module String_set : Set.S with type elt = string

type tool_result_fetch_params = {
  offset : int;
  max_bytes : int;
  source_id : string option;
}

type tool_result_page_error =
  | Page_continuation_failed of { reason : string; retryable : bool }
  | Page_source_changed of string

val tool_result_page_size : int
(** Standard 16KB page window for [/api/v1/keepers/:name/tool-result]. *)

val is_binary_encoding : string -> bool
(** True when a [/tool-result] page encoding is [base64] (case-insensitive). *)

type context_subtab =
  | Ctx_composition
  | Ctx_flow
  | Ctx_exact_input
  | Ctx_input_map
  | Ctx_response

type logs_subview =
  | Logs_metrics
  | Logs_sandbox

type github_login_session = {
  running : bool;
  device_url : string option;
  device_code : string option;
  output_lines : string list;
  error : string option;
}

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
  turn_flow : (string * Wire_keeper_context.turn_flow) Observed.t;
  absent_turn_flow_ref : string option;
  checkpoints : Wire_keeper_context.keeper_checkpoints_inventory Observed.t;
  checkpoints_auth_denied : bool;
  checkpoints_absent : bool;
  last_purge_preview : Wire_keeper_context.checkpoint_purge_result option;
  operator_note : Wire_keeper_context.keeper_operator_note Observed.t;
  operator_note_absent : bool;
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
  tool_results : Wire_keeper_context.tool_result_response Observed.t String_map.t;
  tool_result_cache_order : string list;
  tool_result_inflight : String_set.t;
  tool_result_page_errors : tool_result_page_error String_map.t;
  tool_result_auth_denied : bool;
  metrics : Wire_keeper_context.keeper_metrics_snapshot Observed.t;
  sandbox_logs : Wire_keeper_context.keeper_sandbox_logs Observed.t;
  logs_subview : logs_subview;
  logs_scroll_offset : int;
  oauth_attached : Wire_keeper_context.oauth_attached_tools_snapshot Observed.t;
  oauth_auth_denied : bool;
  oauth_pending_login : Wire_keeper_context.oauth_login_result option;
  oauth_attempt_status : Wire_keeper_context.oauth_attempt_status option;
  oauth_last_poll_ns : int64 option;
  oauth_poll_started_ns : int64 option;
  oauth_poll_consecutive_errors : int;
  github_identity : Wire_keeper_context.github_identity_observation Observed.t;
  github_auth_denied : bool;
  github_login : github_login_session;
  identity_selected_idx : int;
  identity_scroll_offset : int;
}

type t = {
  by_keeper : keeper_state String_map.t;
  oauth_providers : Wire_keeper_context.oauth_providers_snapshot Observed.t;
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

val turn_flow_for_selected_turn :
  keeper_state -> Wire_keeper_context.turn_flow option

val tool_result_for_selected_call :
  keeper_state -> Wire_keeper_context.tool_result_response option

val tool_result_for_execution :
  execution_id:string ->
  keeper_state ->
  Wire_keeper_context.tool_result_response Observed.t
(** Look up the per-keeper cached [/tool-result] observation for
    [execution_id], returning [Observed.loading] while an initial fetch is
    in flight and [Observed.unreported] when never fetched. *)

val is_tool_result_inflight : execution_id:string -> keeper_state -> bool

val tool_result_page_error :
  execution_id:string -> keeper_state -> tool_result_page_error option
(** Continuation failure or source rotation error recorded while preserving an
    already-loaded [Tool_result_page] for [execution_id], or [None] when no
    continuation error is pending. *)

val tool_results_snapshot :
  keeper_state ->
  (string
  * Wire_keeper_context.tool_result_response Observed.t
  * bool
  * tool_result_page_error option)
  list
(** Canonical key-sorted snapshot of cached, in-flight, and continuation-errored
    tool results for structural equality checks (e.g. [Keeper_dive.History_rows]). *)

val next_tool_result_params :
  ?allow_non_retryable:bool ->
  allow_next_page:bool ->
  refetch_when_eof:bool ->
  execution_id:string ->
  keeper_state ->
  tool_result_fetch_params option
(** Plan the next [/tool-result] page request for [execution_id], returning
    [None] when already in-flight, binary-encoded, or when no further fetch is
    needed. [allow_non_retryable] defaults to [false] so automatic Chat
    hydration never loops on non-retryable continuation failures, while manual
    Tool Calls retries pass [true]. *)

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

val mark_tool_result_inflight :
  keeper:string -> execution_id:string -> t -> t

val mark_tool_result_absent :
  keeper:string -> execution_id:string -> t -> t

val mark_tool_result_failed :
  at:Clock.Mono.t ->
  keeper:string ->
  execution_id:string ->
  reason:string ->
  retryable:bool ->
  t ->
  t

val mark_tool_result_conflict :
  at:Clock.Mono.t ->
  keeper:string ->
  execution_id:string ->
  reason:string ->
  t ->
  t
(** Record a [409 Conflict] (source rotated mid-pagination): preserves any
    already-loaded [Tool_result_page] with [Page_source_changed] so the next
    fetch restarts cleanly from [offset = 0, source_id = None], or records a
    retryable failure when no page was loaded yet. *)

val apply_tool_result :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  execution_id:string ->
  Wire_keeper_context.tool_result_response ->
  t ->
  t

val mark_stale_all : t -> t
val mark_keeper_context_stale : keeper:string -> t -> t
val mark_keeper_tool_calls_stale : keeper:string -> t -> t

val apply_turn_flow :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  turn_ref:string ->
  Wire_keeper_context.turn_flow ->
  t ->
  t

val mark_turn_flow_absent : keeper:string -> turn_ref:string -> t -> t

val mark_turn_flow_failed :
  at:Clock.Mono.t ->
  keeper:string ->
  turn_ref:string ->
  reason:string ->
  retryable:bool ->
  t ->
  t

val apply_checkpoints :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  Wire_keeper_context.keeper_checkpoints_inventory ->
  t ->
  t

val mark_checkpoints_denied :
  at:Clock.Mono.t -> keeper:string -> reason:string -> t -> t

val mark_checkpoints_absent : keeper:string -> t -> t

val mark_checkpoints_failed :
  at:Clock.Mono.t -> keeper:string -> reason:string -> retryable:bool -> t -> t

val flow_estimated_rows : keeper_state -> int

val apply_purge_result :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  Wire_keeper_context.checkpoint_purge_result ->
  t ->
  t

val apply_operator_note :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  Wire_keeper_context.keeper_operator_note ->
  t ->
  t

val mark_operator_note_absent : keeper:string -> t -> t

val mark_operator_note_failed :
  at:Clock.Mono.t -> keeper:string -> reason:string -> retryable:bool -> t -> t

val equal_logs_subview : logs_subview -> logs_subview -> bool
val toggle_logs_subview : keeper:string -> t -> t
val move_logs_scroll : keeper:string -> ?max_scroll:int -> delta:int -> t -> t
val apply_metrics :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  Wire_keeper_context.keeper_metrics_snapshot ->
  t ->
  t
val mark_metrics_failed :
  at:Clock.Mono.t -> keeper:string -> reason:string -> retryable:bool -> t -> t
val apply_sandbox_logs :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  Wire_keeper_context.keeper_sandbox_logs ->
  t ->
  t
val mark_sandbox_logs_failed :
  at:Clock.Mono.t -> keeper:string -> reason:string -> retryable:bool -> t -> t
val apply_oauth_providers :
  observed_at:Clock.Mono.t ->
  Wire_keeper_context.oauth_providers_snapshot ->
  t ->
  t
val apply_oauth_attached_tools :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  Wire_keeper_context.oauth_attached_tools_snapshot ->
  t ->
  t
val mark_oauth_denied : at:Clock.Mono.t -> keeper:string -> reason:string -> t -> t
val set_oauth_pending_login :
  keeper:string -> Wire_keeper_context.oauth_login_result option -> t -> t
val set_oauth_attempt_status :
  keeper:string -> Wire_keeper_context.oauth_attempt_status option -> t -> t
val is_oauth_attempt_settled : string -> bool
val mark_oauth_polled : now:Clock.Mono.t -> keeper:string -> t -> t
val record_oauth_poll_error : keeper:string -> t -> t
(** Count a transient OAuth status poll error; polling stops after 5
    consecutive errors to preserve 0 Hz idle on persistent server failures. *)
val pending_oauth_polls :
  now:Clock.Mono.t -> ?wall_unix:float -> t -> (string * string * string) list
(** [(keeper, provider, attempt_id)] triples with an active unsettled OAuth
    exchange whose poll cooldown (>= 2s) has elapsed and which has not reached
    its expiry, monotonic window cap, or consecutive-error limit. Empty when idle. *)
val next_oauth_poll_deadline_ns :
  now_ns:int64 -> ?wall_unix:float -> t -> int64 option
(** Earliest monotonic nanosecond deadline for the next active OAuth status
    poll, or [None] when no keeper has a pollable unsettled OAuth exchange (0 Hz). *)
val apply_github_identity :
  observed_at:Clock.Mono.t ->
  keeper:string ->
  Wire_keeper_context.github_identity_observation ->
  t ->
  t
val mark_github_denied : at:Clock.Mono.t -> keeper:string -> reason:string -> t -> t
val start_github_login : keeper:string -> t -> t
val append_github_login_output : keeper:string -> line:string -> t -> t
val finish_github_login :
  keeper:string -> error:string option -> t -> t
val clear_epoch_logins : t -> t
(** Drop process-local OAuth attempts and detach running GitHub logins. *)
(** Reset [github_login.running = false] across all keepers when leaving an
    epoch whose stream replies are abandoned. *)
val move_identity_selection :
  keeper:string -> count:int -> delta:int -> t -> t
val move_identity_scroll :
  keeper:string -> ?max_scroll:int -> delta:int -> t -> t
