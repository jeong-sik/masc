(** Command-palette projections over loaded TUI state. *)

type gate_lane = Workspace_gate | External_gate

type palette_action =
  | Palette_browser_lane
  | Palette_hide_browser_lane
  (* Connectors draws two screens: the transport list, and the Browser Lane
     that [show_browser_lane] opens under the same view. A plain
     [Palette_goto Connectors] lands on whichever the lane's visibility says,
     so the list -- the half with no key of its own -- would still be
     unreachable whenever the lane had been opened once. This one names the
     list and closes the lane to get there. *)
  | Palette_connectors
  | Palette_msx
  | Palette_dos
  | Palette_lane_addons
  | Palette_goto of Masc_tui_types.surface
  | Palette_config of Masc_tui_types.config_pane
  | Palette_gate_mode of gate_lane * Masc.Keeper_gate_mode.t
  | Palette_chat of string
  | Palette_task of string
  | Palette_board_hearth of string option
  | Palette_board_post of string
  (* (question, symbol): a language-server question about a name on the
     Code pane's cursor line — the K/D candidates ride the palette as
     entries so one keypress can also be a choice among several names. *)
  | Palette_lsp of string * string

val gate_lane_label : gate_lane -> string
val gate_mode_label : Masc.Keeper_gate_mode.t -> string
val code_cursor_line_symbols : Masc_tui_types.state -> string list
val lsp_question_prefixes : (string * string) list
val palette_entries : Masc_tui_types.state -> (string * palette_action) list
val palette_matches : Masc_tui_types.state -> (string * palette_action) list
val palette_starts_with : needle:string -> string -> bool
val palette_subsequence : needle:string -> string -> bool

val palette_typed_question : string -> (string * string option) option
