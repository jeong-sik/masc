(** Per-Keeper persistent Composer draft map, honest pending transmission
    lifecycle ([tui-chat-design/SKILL.md]), [Steer | Follow_up] delivery mode,
    Voice PTT state, and [/btw] ephemeral side-query state.

    Drafts are preserved across every workspace, dive, and overlay switch. *)

open Masc_tui_core
open Masc_tui_protocol

module String_map : Map.S with type key = string

type delivery_mode =
  | Mode_direct
  | Mode_follow_up
  | Mode_steer

type tx_state =
  | Queued
  | Sending
  | Pending_processing
  | Confirming_delivery
  | No_operation_record
  | Interrupting
  | Delivered
  | Failed_retryable of { reason : string }

type pending_message = {
  request_id : string;
  keeper : string;
  body : string;
  mode : delivery_mode;
  operation_id : string option;
  batch_execution_id : Keeper_chat_operation.Operation_id.t option;
  state : tx_state;
  created_at : Clock.Mono.t;
  updated_at : Clock.Mono.t;
}
(** Session-owned transmission. The operation id from acceptance identifies
    it on the server. Visible history rows own their own delivery evidence. *)

type keeper_draft = {
  text : string;
  cursor : int;
  preferred_mode : delivery_mode;
}

type voice_phase =
  | Voice_off
  | Voice_recording of {
      started_at : Clock.Mono.t;
      levels : float list;
      elapsed_s : float;
    }
  | Voice_transcribing
  | Voice_error of string

type voice_capabilities = {
  recorder_available : bool;
  recorder_cmd : string option;
  stt_available : bool;
}

type btw_status =
  | Btw_idle
  | Btw_sending of {
      request_id : string;
      keeper : string;
      prompt : string;
      started_at : Clock.Mono.t;
    }
  | Btw_streaming of {
      request_id : string;
      keeper : string;
      prompt : string;
      buffer : string;
      ownership : Cut_reply.ownership;
    }
  | Btw_answered of { keeper : string; prompt : string; reply : string }
  | Btw_failed of { keeper : string; prompt : string; reason : string }

type t = {
  active_keeper : string option;
  focused : bool;
  by_keeper : keeper_draft String_map.t;
  pending_txs : pending_message list;
  next_request_seq : int;
  voice : voice_phase;
  voice_caps : voice_capabilities option;
  btw : btw_status;
  popup_selected : int;
  popup_navigated : bool;
  popup_dismissed : bool;
}

val default_keeper_key : string
val empty_keeper_draft : keeper_draft
val empty : t

val equal_delivery_mode : delivery_mode -> delivery_mode -> bool
val equal_tx_state : tx_state -> tx_state -> bool
val absence_notice : pending_message -> Say.t
val tx_state_label : tx_state -> Say.t option

val target_keeper_key : t -> string
val draft_for : keeper:string -> t -> keeper_draft
val current_draft : t -> keeper_draft

val set_active_keeper : string -> t -> t
(** Switch active composer target while preserving the previous keeper's draft. *)

val set_focus : bool -> t -> t
val is_focused : t -> bool
val has_non_empty_draft : t -> bool
val current_draft_is_multiline : t -> bool
val other_keepers_draft_count : t -> int

val insert_text : string -> t -> t
val set_current_text : string -> t -> t
val set_current_text_and_cursor : text:string -> cursor:int -> t -> t
val insert_newline : t -> t
val backspace : t -> t
val delete_forward : t -> t
val kill_word : t -> t
val kill_line_start : t -> t
val move_cursor : [ `Left | `Right | `Home | `End ] -> t -> t
val move_cursor_vertical : [ `Up | `Down ] -> t -> t
val move_cursor_word : [ `Left | `Right ] -> t -> t
val move_cursor_line : [ `Start | `End ] -> t -> t
val clear_current_draft : t -> t
val set_preferred_mode : delivery_mode -> t -> t

val move_popup : delta:int -> count:int -> wrap:bool -> t -> t
val set_popup_selected : int -> t -> t
val dismiss_popup : t -> t

val enqueue_submission :
  now:Clock.Mono.t ->
  keeper:string ->
  mode:delivery_mode ->
  t ->
  (t * pending_message) option
(** Atomically consume the non-blank draft for [keeper] and create a
    {!Queued} transmission record with a monotonic [request_id]. Returns [None]
    when the draft is blank. *)

val mark_sending : now:Clock.Mono.t -> request_id:string -> t -> t

val mark_queued :
  now:Clock.Mono.t ->
  request_id:string ->
  operation_id:string option ->
  t ->
  t
(** Record a queued receipt for a submission awaiting acceptance or confirmation.
    Later queued receipts preserve an observed start, interrupt or terminal state. *)

val mark_accepted :
  now:Clock.Mono.t ->
  request_id:string ->
  operation_id:string option ->
  t ->
  t
(** Transition a submission to {!Pending_processing} on server acceptance/run. *)

val mark_operation_absent :
  now:Clock.Mono.t -> requested_at:Clock.Mono.t -> keeper:string -> operation_id:string -> t -> t
(** Retain a scoped absence observation for a nonterminal send. A receipt
    started before newer local acceptance cannot displace it. *)

val mark_confirming : now:Clock.Mono.t -> request_id:string -> t -> t
(** Transition a submission to {!Confirming_delivery} while awaiting persisted
    history confirmation. *)

val set_operation_interrupting :
  now:Clock.Mono.t ->
  keeper:string ->
  operation_id:string ->
  interrupting:bool ->
  t ->
  t
(** Mark or release the submission identified by the interrupt POST. *)

val is_operation_interrupting : keeper:string -> operation_id:string -> t -> bool

val downgrade_mode_to_follow_up : request_id:string -> t -> t
(** Downgrade a [Mode_steer] submission to [Mode_follow_up] when server
    acceptance reports stale control token queueing. *)

val mark_delivered :
  now:Clock.Mono.t ->
  request_id:string ->
  keeper:string ->
  body:string ->
  t ->
  t
(** Transition only the entry matching exact [(request_id, keeper, body)]
    identity to {!Delivered}. *)

val mark_failed_retryable :
  now:Clock.Mono.t -> request_id:string -> reason:string -> t -> t

val remove_tx : request_id:string -> t -> t
(** Remove a settled transmission entry (e.g. once both user prompt and
    [Role_request_failure] are durably persisted in history). *)

val dismiss_notices_for_keeper : keeper:string -> t -> t * int
(** Dismiss failure and absent-status notices for the Keeper and return their count. *)

val active_tx_for_keeper : keeper:string -> t -> pending_message option
(** Return the oldest executing transmission for [keeper] prioritized by
    [Interrupting > Pending_processing > Sending > Confirming_delivery > Queued]. *)

val has_active_tx_for : keeper:string -> t -> bool
val has_unreconciled_tx_for : keeper:string -> t -> bool
val queued_count_for_keeper : keeper:string -> t -> int

val pending_txs_for_keeper : keeper:string -> t -> pending_message list
(** Return pending transmissions for [keeper] in chronological (oldest-first)
    order. *)

val tx_position_for_keeper : keeper:string -> request_id:string -> t -> int option
(** Return the 0-based chronological index of [request_id] among [keeper]'s
    retained transmissions, or [None] if absent. *)

val note_batch_execution :
  request_id:string -> Keeper_chat_operation.Operation_id.t -> t -> t

val is_voice_active : t -> bool
val voice_start_recording : now:Clock.Mono.t -> t -> t
val voice_push_level : float -> t -> t
val voice_tick_elapsed : now:Clock.Mono.t -> t -> t
val voice_set_transcribing : t -> t
val voice_set_off : t -> t
val voice_set_error : string -> t -> t
val voice_apply_transcript : string -> t -> t
val set_voice_capabilities : voice_capabilities -> t -> t

val start_btw :
  now:Clock.Mono.t -> keeper:string -> prompt:string -> t -> t * string
(** Start an ephemeral [/btw] side-query, returning the updated store and fresh
    [request_id] without touching the keeper's main composer draft. *)

val reset_btw_run : request_id:string -> t -> t
val retire_btw_attempt : request_id:string -> t -> t
val append_btw_delta :
  ?owner:Wire_chat_journal.text_owner ->
  request_id:string ->
  delta:string ->
  t ->
  t
val finish_btw : request_id:string -> reply:string -> t -> t
val finalize_btw_eof : request_id:string -> t -> t
(** Resolve an in-flight [/btw] query when its stream closes cleanly without an
    explicit [Chunk_turn_done]: commits non-empty buffered text as
    {!Btw_answered} or fails cleanly as {!Btw_failed}. *)
val fail_btw : request_id:string -> reason:string -> t -> t
val clear_btw : t -> t

val detach_streams : now:Clock.Mono.t -> t -> t
(** For a new epoch, whose guard drops the earlier epoch's stream frames:
    every transmission still waiting on its stream ({!Queued}, {!Sending},
    {!Pending_processing}, {!Interrupting}) moves to {!Confirming_delivery} and
    is settled from chat history, and an unanswered [/btw] fails. *)
