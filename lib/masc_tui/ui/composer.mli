(** Persistent bottom composer widget supporting collapsed 1-line mode, active
    multi-line editing, Compact auto-fold footer pill, per-keeper draft badges,
    honest pending transmission pills ([전송 대기]/[전송 중]/[응답 대기]/[확인 중]),
    live Voice PTT Braille mic waveform, and [@] keeper / [/] slash popups.

    v2.5 visual polish: refined [surface_1]/[surface_2] elevation, calm
    {!Masc_tui_core.Glyph.Left_rail} ([▎]) accent when focused, Tier-4 italic
    placeholder hints, and elevated keycap send pill. *)

module Glyph = Masc_tui_core.Glyph
module Rect = Masc_tui_core.Rect
module Say = Masc_tui_core.Say
module Theme = Masc_tui_core.Theme
module Cell_grid = Masc_tui_term.Cell_grid
module Presenter = Masc_tui_term.Presenter

type turn_running_kind =
  | Turn_kind_active
  | Turn_kind_tool
  | Turn_kind_attention

type pending_tx =
  | Tx_idle
  | Tx_queued           (** 전송 대기 / Queued *)
  | Tx_queued_count of int (** 대기열 N / Queued N *)
  | Tx_sending          (** 전송 중 / Sending *)
  | Tx_awaiting_turn    (** 응답 대기 / Waiting for response *)
  | Tx_thinking         (** 추론 중… / Thinking… *)
  | Tx_tool_running of string
  | Tx_tool_waiting of string
  | Tx_streaming        (** 생성 중… / Streaming… *)
  | Tx_turn_running of { kind : turn_running_kind; label : Say.t }
      (** 실행 중인 턴 관측 / Observed running turn *)
  | Tx_confirming       (** 전송 확인 중 / Confirming *)
  | Tx_interrupting     (** 중단 요청 중 / Interrupting *)
  | Tx_failed of string (** 전송 실패 / Send failed *)

type voice_state =
  | Voice_off
  | Voice_recording of { levels : float array; elapsed_s : float }
  | Voice_transcribing

type popup_item = {
  trigger : string;
  label : string;
  detail : string option;
}

type popup =
  | Popup_none
  | Popup_slash of { query : string; items : popup_item list; selected : int }
  | Popup_mention of { query : string; items : popup_item list; selected : int }

type mode =
  | Auto_folded_pill    (** Compact 80..99 idle empty draft & voice off: folded into footer *)
  | Collapsed_bar       (** Unfocused 1-line persistent bar *)
  | Expanded_multiline  (** Active editing, multiline draft, or Voice PTT *)

type state = {
  target_keeper : string;
  draft : string;
  cursor : int;
  focused : bool;
  pending_tx : pending_tx;
  voice : voice_state;
  popup : popup;
  draft_count_other_keepers : int;
}

val equal_pending_tx : pending_tx -> pending_tx -> bool
val equal_mode : mode -> mode -> bool

val empty : target_keeper:string -> state

val pending_tx_label : pending_tx -> Say.t option
val pending_tx_badge : pending_tx -> (Glyph.t * Theme.status_token * Say.t) option
(** Exact honest transmission state copy ([전송 대기] / [전송 중] / [응답 대기] /
    [확인 중]) per [tui-chat-design/SKILL.md], or [None] when {!Tx_idle}. *)

val resolve_mode : breakpoint:Layout.breakpoint -> state -> mode
(** Deterministically resolve composer visual mode. On {!Layout.Compact}, folds
    into the footer pill strictly when unfocused with empty draft, voice off,
    and {!Tx_idle}. *)

val desired_height :
  breakpoint:Layout.breakpoint -> max_height:int -> state -> int
(** Rows reserved above the footer ([0] when {!Auto_folded_pill}, [1] when
    {!Collapsed_bar}, [2..min 6 max_height] when {!Expanded_multiline}). *)

val folded_footer_pill : lang:Say.lang -> state -> string
(** Compact footer badge shown when {!resolve_mode} returns {!Auto_folded_pill}
    (e.g. ["› @alpha-keeper [i]"]). *)

val insert_text : string -> state -> state
val insert_newline : state -> state
val backspace : state -> state
val kill_word : state -> state
val move_cursor : [ `Left | `Right | `Home | `End ] -> state -> state

val render_voice_waveform :
  ?clip:Rect.t ->
  Cell_grid.t ->
  x:int ->
  y:int ->
  width:int ->
  theme:Theme.t ->
  bg:Masc_tui_term.Color.t ->
  float array ->
  int
(** Paint live Voice PTT microphone levels directly via
    {!Masc_tui_term.Cell_grid.put_braille} (zero string allocations). *)

val draw_popup :
  Cell_grid.t ->
  anchor:Rect.t ->
  theme:Theme.t ->
  lang:Say.lang ->
  popup ->
  Rect.t option
(** Paint an active [/] slash or [@] mention completion popup cleanly above
    [anchor], returning the painted popup rectangle (or [None] if closed). *)

val draw :
  ?show_pending_tx:bool ->
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  lang:Say.lang ->
  breakpoint:Layout.breakpoint ->
  state ->
  Presenter.cursor
(** Paint the persistent composer bar/multiline editor onto [Cell_grid.t] and
    return the exact {!Presenter.cursor} for the terminal presenter. *)
