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
(** True when a finished non-error stream buffer's assistant text already
    appears in persisted chat history (suppressing duplicate stream rows). *)

type viewport_geometry = {
  body_h : int;
  prose_w : int;
}

val chat_viewport_geometry : model:Model.t -> viewport_geometry
(** Exact Keeper Dive chat transcript viewport height and prose column width
    matching [Chrome.compute_layout], [Layout.inset_body], [Card.draw], and
    [Keeper_dive.render_chat_tab]. *)

val count_transcript_rows : model:Model.t -> keeper:string -> width:int -> int
(** Exact rendered transcript row count (history + active/unpersisted stream +
    visible pending transmissions + inter-section blank separators) for
    [keeper] at prose column [width]. *)

val max_scroll_for_model : model:Model.t -> keeper:string -> int
(** Exact upper bound [max 0 (total_rows - body_h)] for [chat_scroll_offset]
    matching [Keeper_dive.draw_transcript_rows]. *)
