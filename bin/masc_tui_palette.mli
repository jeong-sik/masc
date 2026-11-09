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
  | Palette_collab
  | Palette_msx
  | Palette_dos
  | Palette_lane_addons
  | Palette_lane_history of Lane_run_identity.t
      (** Retained logical observations, independent of current settings rows
          and installed Addons. Selection does not grant read authority. *)
  | Palette_addon_results of string
      (** One installation's Results, by its declaration id. *)
  | Palette_goto of Masc_tui_types.surface
  | Palette_usage_scope of string option
  | Palette_config of Masc_tui_types.config_pane
  | Palette_ui_language of Masc_tui_types.ui_language
  | Palette_gate_mode of gate_lane * Masc.Keeper_gate_mode.t
  | Palette_chat of string
  | Palette_task of string
  | Palette_task_creation of Masc_tui_types.task_dispatch_request
      (** The exact completed creation retained by the selected composer Keeper.
          Activation must recheck original membership and workspace. This opens
          reading only; it does not consume or restore the composer draft. *)
  | Palette_board_hearth of string option
  | Palette_board_post of string
  (* (question, symbol): a language-server question about a name on the
     Code pane's cursor line — the K/D candidates ride the palette as
     entries so one keypress can also be a choice among several names. *)
  | Palette_lsp of string * string
  | Palette_code_file of string
  | Palette_code_location of Masc_tui_types.code_location_offer * Masc.Tui_decode.lsp_location
  | Palette_code_branch of Masc.Tui_decode.git_branch
  | Palette_code_worktree of Masc.Tui_decode.git_worktree
  | Palette_code_search_match of Masc.Tui_decode.workspace_search_match

val gate_lane_label : gate_lane -> string
val gate_mode_label : Masc.Keeper_gate_mode.t -> string
val code_cursor_line_symbols : Masc_tui_types.state -> string list
val lsp_question_prefixes : (string * string) list
val palette_entries : Masc_tui_types.state -> (string * palette_action) list
val palette_matches : Masc_tui_types.state -> (string * palette_action) list
(** Search the existing typed destinations and content. Canonical top-level
    surface names come from [surface_ring]. An empty jump query offers only
    those destinations; other commands and content require a search. Aliases
    are search terms on one action, never extra rows. An
    entry whose label or alias is the whole query comes first, then a prefix
    candidate, before unrelated substring matches; entry order decides only
    between entries of one rank. Matching does not introduce another
    destination or execute an action. *)

val selected_file : Masc_tui_types.state -> string option
val selected_location : Masc_tui_types.state ->
  (Masc_tui_types.code_location_offer * Masc.Tui_decode.lsp_location) option
val branch_label : Masc.Tui_decode.git_branch -> string
(** One palette row for a branch: checked-out mark, name, standing against the
    upstream, tip date (UTC) and subject. *)
val worktree_label : Masc.Tui_decode.git_worktree -> string
(** One palette row for a worktree: main mark, directory name, what is checked
    out (branch, or the short HEAD when detached, or bare) and the locked and
    prunable flags. *)
val selected_search_match : Masc_tui_types.state ->
  Masc.Tui_decode.workspace_search_match option

type search_enter =
  | Enter_opens of Masc.Tui_decode.workspace_search_match
  | Enter_searches
(** What Enter does in the "search in files" prompt. It opens the match under
    the cursor when the answer on screen is for the typed text and holds one.
    In every other case it searches the typed text: no answer yet, text typed
    since the answer, an answer that failed, and an answer with no match. The
    key handler and the overlay's hints both read this, so the text cannot
    name an Enter the handler does not take. *)

val search_enter : Masc_tui_types.state -> search_enter

(** True when Enter in the [:] command palette has nothing to run: the typed
    text matches no command and is not a Code question (those run without a
    listed row). The key then leaves the palette open with its text, and the
    footer drops Enter, both from this one answer. The other prompts never read
    it: "search in files" searches the typed text, and the branch and worktree
    lists close on Enter. *)
val command_enter_has_nothing : Masc_tui_types.state -> bool

val palette_starts_with : needle:string -> string -> bool
val palette_subsequence : needle:string -> string -> bool

val palette_typed_question : string -> (string * string option) option
