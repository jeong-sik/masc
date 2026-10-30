(** System Config screens (Prompts, Presets, Themes, Runtime TOML, Models,
    Runtime Parameters, and Voice) and their viewport/scroll calculators. *)

val selected_model_reading :
  Masc_tui_types.state -> Masc_tui_detail_reading.t option
(** Read the selected model's complete account, effective values and owning
    sections without entering the editor. *)

val config_models_scrolled : Masc_tui_types.state -> Masc_tui_types.scrolled
(** The models pane's scroll bound: the document it actually draws (table or
    stacked items at the current width), not a row count. *)

val config_models_stacked : Masc_tui_types.state -> bool
(** Whether the models pane draws stacked items at the current width. *)

val config_content_height : Masc_tui_types.state -> int

val prompts_detail_viewport : Masc_tui_types.state -> int * int
(** Wrapped selected prompt/asset row count and the detail's visible rows.
    Page and edge keys use the same document and geometry as drawing. *)

val presets_viewport : Masc_tui_types.state -> int * int
(** Wrapped detail row count and height below the Presets selection list. *)

val preset_confirmation_ready : Masc_tui_types.state -> bool
(** The current save confirmation was actually presented from start to end. *)

val preset_save_receipt_lines :
  ko:bool -> Masc_tui_types.preset_save_receipt -> string list
(** A save receipt's localized outcome and, when needed, recovery guidance. *)

val runtime_config_status_scroll_limit :
  Masc_tui_types.state -> terminal_rows:int -> cols:int -> int

val render_runtime_params :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_prompts :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_presets :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_themes :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_config_models :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_voice :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_config :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
