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
(** Word-boundary wrapping for literal diagnostics and payloads. *)

val tool_output_display_lines :
  theme:Theme.t -> tools_mode:Slash.tools_mode -> width:int -> string ->
  Markdown.rendered_line list * int
(** [(shown_lines, hidden_count)] for a tool output payload using
    {!Json_tree.flatten} or a literal rendering. Blob references with a
    declared Markdown preview also render the preview. The cap is 12 lines
    (depth 3) in [Tools_results] and 200 lines (depth 6) in [Tools_full]. *)

val thinking_body_lines :
  theme:Theme.t -> width:int -> string -> Markdown.rendered_line list
(** Wrapped reasoning body shared by paint and scroll geometry. *)

type tool_detail_section =
  | Tool_section_label of { text : Say.t; tone : Theme.status_token option }
  | Tool_section_payload of { raw : string; tools_mode : Slash.tools_mode }
  | Tool_section_notice of { text : Say.t; tone : Theme.status_token option }

val project_tool_details :
  tools_mode:Slash.tools_mode ->
  args:string option ->
  inline_result:string option ->
  execution_id:string option ->
  tool_running:bool ->
  keeper_state:Keeper_context_store.keeper_state ->
  tool_detail_section list
(** Single-source-of-truth projection for expanded tool card body rows (Args +
    hydrated or inline Result + honest loading/pending/unavailable status +
    multi-page byte progress) shared identically by {!count_transcript_rows}
    and [Keeper_dive]. *)

val count_tool_detail_rows :
  theme:Theme.t -> width:int -> tool_detail_section list -> int

val markdown_body_lines :
  theme:Theme.t ->
  width:int ->
  rail_present:bool ->
  prefix:string ->
  string ->
  Markdown.rendered_line list
(** Render chat message body through {!Markdown.render_lines} with the exact
    rail and prefix width subtraction used by [Keeper_dive]. *)

val retained_image_height : model:Model.t -> keeper:string -> width:int -> int

val retained_image_rows :
  theme:Theme.t -> lang:Say.lang -> width:int -> height:int -> Wire_fleet.retained_image list ->
  Markdown.rendered_line list

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
    [turn.preview], and "Running" before the turn has one. *)

type keeper_work_row =
  | Work_status of (Glyph.t * Theme.status_token * Say.t)
  | Work_detail of Say.t

val keeper_work_overview : model:Model.t -> keeper:string -> keeper_work_row list
val animation_frames_per_second : int
val reduce_motion : Model.t -> bool

val progress_glyph : Model.t -> Glyph.t
(** The current progress frame, with a steady glyph under reduced motion. *)

val active_turn_detail_summary : Wire_fleet.active_turn -> Say.t
(** Single-line progress summary ([<lane> · <activity/preparation/last tool>])
    for the observed turn and its start decisions. *)

val active_turn_preview_tail : Wire_fleet.active_turn -> string option
(** Secret-scrubbed single-line preview snippet from [turn.preview.text_tail],
    or [None] when blank or absent. *)

val live_chat_phase : model:Model.t -> keeper:string -> live_chat_phase
(** Resolve the current chat phase from the Keeper's turn, stream and drafts. *)

val fresh_turn_state : model:Model.t -> keeper:string -> Wire_fleet.keeper_turn_state option
(** Latest current turn observation for this Keeper. [None] means the turn
    dataset is stale, unavailable, or lacks a row for this Keeper. *)

val live_chat_phase_badge :
  model:Model.t -> keeper:string -> (Glyph.t * Theme.status_token * Say.t) option
(** Width-1 geometric glyph, status tone, and bilingual label for an active or
    failed {!live_chat_phase}, or the latest confirmed completion when idle. *)

val live_chat_phase_badges :
  model:Model.t -> keeper:string ->
  (Glyph.t * Theme.status_token * Say.t) option * (Glyph.t * Theme.status_token * Say.t) option
(** The detailed strip and compact header from the same phase and observation.
    Prior successes remain in the detail strip. *)

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

type delegate_kind =
  | Delegate_invoke
  | Delegate_status
  | Delegate_cancel

type delegate_summary = {
  kind : delegate_kind;
  target_keeper : string option;
  target_keepers : string list;
  operation_count : int;
  prompt_preview : string option;
  operation_id : string option;
  artifact_count : int;
}

val extract_delegate_summary :
  tool_name:string -> raw_json:string -> delegate_summary option
(** Secret-scrubbed Keeper Delegate extractor covering [masc_keeper_delegate],
    [masc_keeper_delegate_status], [masc_keeper_delegate_status_many], and
    [masc_keeper_delegate_cancel]. *)

val format_short_tool_label :
  lang:Say.lang -> tool_name:string -> raw_json:string -> string
(** Short delegate-aware tool label for compact group histograms. *)

val summarize_tool_histogram :
  lang:Say.lang -> ?max_unique:int -> (string * string) list -> string
(** Compact tool frequency histogram (e.g. ["Read ×2 · 위임(@worker-alpha)"]). *)

val count_history_thinking_rows :
  theme:Theme.t ->
  mode:Fleet_store.thinking_display ->
  width:int ->
  Wire_fleet.history_thinking option ->
  int
(** Exact row count for persisted history thinking blocks, shared between
    {!count_transcript_rows} and [Keeper_dive.build_history_rows]. *)

type 'a tool_group = Single of 'a | Grouped of 'a * 'a list

val tools_mode : Model.t -> Slash.tools_mode
val history_tool_groups :
  tools_mode:Slash.tools_mode ->
  Wire_fleet.chat_message list ->
  Wire_fleet.chat_message tool_group list
val stream_tool_groups :
  tools_mode:Slash.tools_mode ->
  Fleet_store.active_tool_call list ->
  Fleet_store.active_tool_call tool_group list

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

val prose_width : content_w:int -> int
(** Width the chat transcript wraps at inside a content rect [content_w]
    cells wide: the whole rect, never below 16 cells. Row counting and
    [Keeper_dive.render_chat_tab] both use it, so scroll bounds match what
    is drawn. *)

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

val flattened_tool_call_lines :
  Keeper_context_store.keeper_state ->
  Wire_keeper_context.tool_call_entry ->
  Masc_tui_ui.Json_tree.line list
(** Cached unfolded + secret-scrubbed + flattened {!Masc_tui_ui.Json_tree.line}
    rows for the selected tool call, shared between scroll clamping and frame
    rendering so large tool payloads are not re-parsed on every keypress or
    frame. *)
