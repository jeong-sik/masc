(** Single-source-of-truth chat transcript layout, wrapping, secret scrubbing,
    tool-output flattening, and viewport geometry shared between
    {!Masc_tui_screens_ops.Keeper_dive} rendering and {!Update_nav} scroll
    clamping. *)

open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol
open Masc_tui_ui

val scrub_secrets_in_text : string -> string
val scrub_json_secrets : Yojson.Safe.t -> Yojson.Safe.t
val rewrite_masc_links_for_markdown : string -> string

val wrap_plain_lines : width:int -> string -> string list
(** Word-boundary plain-text line wrapper shared by thinking blocks and
    non-JSON tool output previews. *)

val tool_output_display_lines :
  tools_mode:Slash.tools_mode -> width:int -> string -> string list * int
(** [(shown_lines, hidden_count)] for a tool output payload using
    {!Json_tree.flatten} (8-line cap in [Tools_results], 48-line cap in
    [Tools_full]) or {!wrap_plain_lines} for non-JSON payloads. *)

val markdown_body_lines :
  theme:Theme.t ->
  width:int ->
  rail_present:bool ->
  prefix:string ->
  string ->
  Markdown.rendered_line list
(** Render chat message body through {!Markdown.render_lines} with the exact
    rail and prefix width subtraction used by [Keeper_dive]. *)

val stream_reply_already_persisted :
  Wire_fleet.chat_message list -> Fleet_store.chat_stream_buffer -> bool
(** Whether the operation's durable terminal transcript row has arrived. *)

type live_chat_phase =
  | Phase_idle
  | Phase_sending
  | Phase_queued of int
  | Phase_awaiting_turn
  | Phase_thinking
  | Phase_tool_running of string
  | Phase_tool_waiting of string
  | Phase_streaming
  | Phase_turn_running of {
      turn : Wire_fleet.active_turn;
      queued_count : int;
    }
  | Phase_confirming
  | Phase_interrupting
  | Phase_failed of string

val equal_live_chat_phase : live_chat_phase -> live_chat_phase -> bool

val active_turn_short_activity : Wire_fleet.active_turn -> Say.t
(** Concise live activity label for a running Owner-slot turn, derived from
    [turn.preview] (or fallback [tool_in_flight]/[phase]). *)

val active_turn_detail_summary : Wire_fleet.active_turn -> Say.t
(** Single-line progress summary ([<lane> · <activity/preparation/last tool>])
    for the active-turn transcript observation row. *)

val active_turn_preview_tail : Wire_fleet.active_turn -> string option
(** Secret-scrubbed single-line preview snippet from [turn.preview.text_tail],
    or [None] when blank or absent. *)

val live_chat_phase : model:Model.t -> keeper:string -> live_chat_phase
(** Single-source-of-truth live chat turn phase driving the Keeper header badge,
    header hotkey, composer pill, and viewport geometry from the same state. *)

val live_chat_phase_badge :
  model:Model.t -> keeper:string -> (Glyph.t * Theme.status_token * Say.t) option
(** Width-1 geometric glyph, status tone, and bilingual label for an active or
    failed {!live_chat_phase}, or [None] when {!Phase_idle}. *)

val show_active_turn_summary :
  model:Model.t -> keeper:string -> Wire_fleet.active_turn -> bool
(** Retain an inline summary when it adds information to the status strip,
    records an attempt failure, or the operator has enabled chat details. *)

val composer_pending_tx_of_phase : live_chat_phase -> Composer.pending_tx
(** Project {!live_chat_phase} onto {!Composer.pending_tx}. *)

val is_phase_interruptible : live_chat_phase -> bool
(** True when {!live_chat_phase} represents an actively executing turn that the
    operator can interrupt. *)

val interrupt_target_pending :
  model:Model.t -> keeper:string -> Cmd.keeper_turn_interrupt_target -> bool

val escape_interrupt_target :
  model:Model.t -> keeper:string -> Cmd.keeper_turn_interrupt_target option
(** The target Esc is allowed to interrupt from the Keeper chat dive.
    [None] leaves Esc available for navigation. *)

val explicit_interrupt_target :
  model:Model.t ->
  keeper:string ->
  Wire_fleet.active_turn option ->
  Cmd.keeper_turn_interrupt_target option

type stream_projection = {
  buf : Fleet_store.chat_stream_buffer;
  show_runtime_meta : string option;
  show_retry : string option;
  show_checkpoint : string option;
  show_protocol_warning : string option;
  show_thinking : bool;
  show_tools : bool;
  show_text : bool;
  show_error : string option;
}

type pending_tx_projection = {
  tx : Drafts.pending_message;
  notice_only : bool;
}

type transcript_section =
  | Section_history of Wire_fleet.chat_message list
  | Section_active_turn of Wire_fleet.active_turn
  | Section_pending of pending_tx_projection list
  | Section_stream of stream_projection

val project_transcript :
  model:Model.t -> keeper:string -> transcript_section list
(** Single-source-of-truth chronological transcript projection consumed
    identically by {!count_transcript_rows} and [Keeper_dive.render_chat_tab]:
    persisted history -> unpersisted pre-stream & active user txs -> active
    stream buffer -> queued / newer pending txs. *)

type viewport_geometry = {
  body_h : int;
  prose_w : int;
}

val keeper_content_rect_size : embedded:bool -> model:Model.t -> int * int
(** Exact [(content_w, content_h)] of the tab content rect inside
    [Keeper_dive.render_tabs_body] for both Dive ([embedded = false]) and
    [4 Keepers] Split [pane 1] ([embedded = true]). *)

val chat_viewport_geometry : model:Model.t -> viewport_geometry
(** Exact Keeper Dive chat transcript viewport height and prose column width
    matching [Chrome.compute_layout], [Layout.inset_body], [Card.draw], and
    [Keeper_dive.render_chat_tab]. *)

val chat_viewport_geometry_for :
  embedded:bool -> model:Model.t -> viewport_geometry
(** Parameterized {!chat_viewport_geometry} for both Dive ([embedded = false])
    and [4 Keepers] Split [pane 1] ([embedded = true]). *)

val count_transcript_rows : model:Model.t -> keeper:string -> width:int -> int
(** Exact rendered transcript row count (history + active/unpersisted stream +
    visible pending transmissions + inter-section blank separators) for
    [keeper] at prose column [width]. *)

val max_scroll_for_model : model:Model.t -> keeper:string -> int
(** Exact upper bound [max 0 (total_rows - body_h)] for [chat_scroll_offset]
    matching [Keeper_dive.draw_transcript_rows]. *)

val max_scroll_for_model_in :
  embedded:bool -> model:Model.t -> keeper:string -> int
(** Parameterized {!max_scroll_for_model} for both Dive ([embedded = false])
    and [4 Keepers] Split [pane 1] ([embedded = true]). *)
