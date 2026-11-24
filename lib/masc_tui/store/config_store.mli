(** Categorized 7-Tab Settings sub-store: [General & UI] via
    [/api/v1/tui/preferences] plus 6 grouped server TOML tabs from
    [/api/v1/config/schema], search filter, dirty field patch map, [dry_run]
    TOML diff preview state, [snapshot_id] save receipt, target switcher
    ([runtime | keeper:<name> | keeper_create]), and strict typed inline field
    editing (replacing all 16 [$EDITOR] traps). *)

open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

module String_map : Map.S with type key = string
module String_set : Set.S with type elt = string

type settings_pane =
  | Pane_tree
  | Pane_inspector

type settings_tree_section = {
  section_id : string;
  category : Wire_config.config_category;
  tab : Nav.settings_tab;
  title : string;
  subtitle : string;
  is_catalog_group : bool;
  badge_count : int;
  dirty_count : int;
  provenance : Wire_config.provenance;
  reload_scope : Wire_config.reload_scope;
  fields : Wire_config.schema_field list;
}

type settings_tree_row =
  | Tree_category of {
      category : Wire_config.config_category;
      tab : Nav.settings_tab;
      collapsed : bool;
      section_count : int;
      field_count : int;
      dirty_count : int;
    }
  | Tree_models_catalog_toggle of {
      expanded : bool;
      model_count : int;
      dirty_count : int;
    }
  | Tree_section of settings_tree_section

type dry_run_state =
  | Dry_run_idle
  | Dry_run_loading
  | Dry_run_ready of Wire_config.patch_response
  | Dry_run_failed of string

type save_state =
  | Save_idle
  | Save_in_flight
  | Save_succeeded of Wire_config.patch_response
  | Save_failed of string

type t = {
  active_tab : Nav.settings_tab;
  target : Wire_config.config_target;
  preferences : Wire_config.tui_preferences Observed.t;
  schema : Wire_config.config_schema Observed.t;
  field_meta : Wire_config.field_entity_meta String_map.t;
  search_query : string;
  dirty_fields : Wire_config.patch_op String_map.t;
  dirty_by_target :
    (Wire_config.config_target * Wire_config.patch_op String_map.t) list;
  discard_confirm_armed : bool;
  dry_run_preview : dry_run_state;
  dry_run_scroll_offset : int;
  save_state : save_state;
  last_snapshot_id : string option;
  new_keeper_name : string;
  settings_pane : settings_pane;
  selected_section_idx : int;
  tree_scroll_offset : int;
  collapsed_categories : String_set.t;
  models_catalog_expanded : bool;
  selected_field_index : int;
  scroll_offset : int;
  editing_field_key : string option;
  editing_buffer : string;
  editing_cursor : int;
}

val empty : t
val equal_config_target :
  Wire_config.config_target -> Wire_config.config_target -> bool
val equal_settings_pane : settings_pane -> settings_pane -> bool
val is_two_pane_width : cols:int -> bool
(** [true] when the Settings modal's inner body width ([cols - 2]) reaches the
    [72]-column threshold for rendering the 2-pane Tree + Property Inspector. *)

val set_tab : Nav.settings_tab -> t -> t
val cycle_tab : Keymap.cycle_dir -> t -> t
val set_target : Wire_config.config_target -> t -> t
val set_new_keeper_name : string -> t -> t
val set_search_query : string -> t -> t

val set_pane : settings_pane -> t -> t
val toggle_pane : t -> t
val enter_inspector : t -> t
val leave_inspector : t -> t
val move_tree_selection : ?viewport_rows:int -> delta:int -> t -> t
val toggle_tree_node : t -> t
val collapse_or_leave : t -> t
val expand_or_enter : t -> t

val apply_preferences :
  observed_at:Clock.Mono.t -> Wire_config.tui_preferences -> t -> t
val apply_schema :
  ?field_meta:(string * Wire_config.field_entity_meta) list ->
  observed_at:Clock.Mono.t ->
  Wire_config.config_schema ->
  t ->
  t
val apply_schema_meta :
  target:Wire_config.config_target ->
  (string * Wire_config.field_entity_meta) list ->
  t ->
  t

val mark_dry_run_loading : t -> t
val mark_save_in_flight : t -> t
val clear_in_flight : t -> t
(** Reset in-flight [Save_in_flight] and [Dry_run_loading] states back to idle
    when leaving an epoch whose replies are abandoned, preserving staged
    [dirty_fields]. *)
val apply_patch_response :
  dry_run:bool -> Wire_config.patch_response -> t -> t
val apply_patch_error : dry_run:bool -> string -> t -> t

val tree_sections : t -> settings_tree_section list
(** All entity-grouped sections across categories (merging [providers.<id>.*]
    with [<id>.*] binding tables and tagging [models.*] with
    [is_catalog_group = true]), filtered live by [search_query]. *)

val visible_tree_rows : t -> settings_tree_row list
(** Flattened Left-Pane tree rows for 2-pane Settings rendering & navigation. *)

val selected_tree_row : t -> settings_tree_row option
val selected_section : t -> settings_tree_section option
val selected_section_fields : t -> Wire_config.schema_field list
(** Clean leaf fields of the currently active entity section for the Right-Pane
    Inspector. *)

val field_label : lang:Say.lang -> Wire_config.schema_field -> string
(** Localized human-readable leaf label for a property row (never raw dotted
    [full_key]). *)

val field_sub_group : t -> Wire_config.schema_field -> string option
(** Sub-group identifier honoring server-supplied [sub_group] metadata first,
    falling back to quote-aware {!Wire_config.field_sub_group}. *)

val visible_fields : t -> Wire_config.schema_field list
val keeper_visible_fields : ?lang:Say.lang -> t -> Wire_config.schema_field list
(** All fields flattened across every section of [schema.sections] (never
    filtered by [active_tab]) and filtered by [search_query] using the single
    shared predicate matching localized label, [full_key], [label], and
    [description]. Returns [[]] when the schema is unloaded or belongs to a
    different target. *)

val keeper_selected_field : ?lang:Say.lang -> t -> Wire_config.schema_field option
(** Currently focused field in {!keeper_visible_fields}. *)

val inspector_fields : t -> Wire_config.schema_field list
(** Exact fields displayed in the Right-Pane Property Inspector, including
    synthesized [tui.*] preference fallback rows when [General & UI] has no
    server schema section and [search_query = ""]. *)
val is_tui_pref_key : string -> bool
val selected_field : t -> Wire_config.schema_field option
val apply_tui_pref_op :
  observed_at:Clock.Mono.t ->
  full_key:string ->
  Wire_config.patch_op ->
  t ->
  t

val stage_patch : full_key:string -> Wire_config.patch_op -> t -> t
val unstage_patch : full_key:string -> t -> t
val clear_dirty : t -> t
val dirty_count : t -> int
val arm_discard_confirm : t -> t
val disarm_discard_confirm : t -> t

val step_field :
  delta:int -> Wire_config.schema_field -> t -> (t * bool, string) result
(** Step a writable discrete/numeric field by [delta] ([Field_enum] wrap-cycles,
    [Field_bool] toggles, [Field_int] steps by [delta] clamped to bounds,
    [Field_float] steps by [delta *. 0.1] clamped to bounds, unstaging when
    returning to the original schema value). Returns [Ok (t, false)] for
    non-steppable string/list fields and [Error reason] for read-only, secret,
    or structured fields. *)

val step_selected_field : delta:int -> t -> (t * bool, string) result
(** {!step_field} applied to {!selected_field} in Settings [Pane_inspector]. *)

val step_keeper_field :
  ?lang:Say.lang -> delta:int -> t -> (t * bool, string) result
(** {!step_field} applied to {!keeper_selected_field} in [Keeper_config]. *)

val build_patch_request :
  dry_run:bool -> t -> (Wire_config.patch_request, string) result

val new_keeper_name_field_key : string
(** Sentinel [editing_field_key] used while typing [new_keeper_name] for
    {!Wire_config.Target_keeper_create}. *)

val is_editing_field : t -> bool
val is_editing_new_keeper_name : t -> bool
val begin_edit_new_keeper_name : t -> t
val begin_edit_field :
  ?step_enum:bool -> Wire_config.schema_field -> t -> (t, string) result
(** Begin editing or immediately toggle/step [field]. [Field_bool] always
    toggles immediately; [Field_enum] steps [+1] when [step_enum = true]
    (default) or opens inline text edit when [step_enum = false]; scalar/list
    fields open [editing_field_key]/[editing_buffer]. *)

val begin_edit_selected : t -> (t, string) result
val begin_edit_keeper_selected : ?lang:Say.lang -> t -> (t, string) result
val stage_remove_field : Wire_config.schema_field -> t -> (t, string) result
val stage_remove_selected : t -> (t, string) result
(** Stage (or unstage if already staged) a {!Wire_config.Remove_key} patch op
    for the currently selected writable field. *)
val stage_remove_keeper_selected : ?lang:Say.lang -> t -> (t, string) result
val update_edit_buffer : string -> t -> t
val append_edit_char : string -> t -> t
val backspace_edit_buffer : t -> t
val delete_edit_forward : t -> t
val kill_edit_line_start : t -> t
val clamp_edit_cursor : string -> int -> int
val kill_edit_word : t -> t
val move_edit_cursor : [ `Left | `Right | `Home | `End ] -> t -> t
val cancel_edit_field : t -> t
val commit_edit_field : t -> (t, string) result
(** Strictly parse [editing_buffer] against the selected field's
    {!Wire_config.field_kind} (never silently defaulting invalid ints, floats,
    bools, or enum choices) and stage the resulting {!Wire_config.patch_op}. *)

val move_selection : ?viewport_rows:int -> delta:int -> t -> t
val move_keeper_selection :
  ?viewport_rows:int ->
  ?lang:Say.lang ->
  ?fallback_count:int ->
  delta:int ->
  t ->
  t
(** Move [selected_field_index] across all {!keeper_visible_fields} (or
    [fallback_count], default [5], while the target keeper's schema is still
    unloaded). *)
val move_dry_run_scroll : max_scroll:int -> delta:int -> t -> t
val mark_stale_all : t -> t
