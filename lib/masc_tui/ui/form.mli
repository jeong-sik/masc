(** Generalized typed in-TUI form engine powering the v2.5 2-Pane Settings
    Property Inspector and replacing all legacy [$EDITOR] workflows.

    Features:
    - Typed field values: text, multiline, int, float, bool toggle, enum
      stepper, and masked secret fields.
    - Provenance pills ([Default], [Global TOML], [Keeper TOML], [Env], [TUI])
      and [reload_scope] badges ([Hot_reload], [Next_turn], [Restart_required]).
    - Section Property Inspector mode ({!section_header}): paints a single
      elevated [surface_2] section provenance/reload header band, suppresses
      redundant per-row badges (rendering exception-only micro-chips), uses
      calm [selection_bg] + {!Masc_tui_core.Glyph.Left_rail} ([▎]) focus, and
      pins a Tier-4 italic focused-field help & diff strip at the bottom.
    - Pure validation producing bilingual {!Masc_tui_core.Say.t} errors.
    - Secret-safe inline unified diff preview via {!Diff}. *)

module Rect = Masc_tui_core.Rect
module Say = Masc_tui_core.Say
module Theme = Masc_tui_core.Theme
module Cell_grid = Masc_tui_term.Cell_grid
module Input = Masc_tui_term.Input_decoder

type provenance =
  | Prov_default
  | Prov_global_toml
  | Prov_keeper_toml of string
  | Prov_env of string
  | Prov_tui_pref

type reload_scope =
  | Hot_reload
  | Next_turn
  | Restart_required

type section_header = {
  title : Say.t;
  canonical_prefix : string option;
  provenance : provenance;
  reload_scope : reload_scope;
}

type field_value =
  | Text_val of string
  | Multiline_val of string
  | Int_val of { raw : string; parsed : int option }
  | Float_val of { raw : string; parsed : float option }
  | Bool_val of bool
  | Enum_val of { selected : int; options : (string * Say.t) array }
  | Secret_val of { raw : string; revealed : bool }

type validator =
  | Required
  | Int_range of { min : int option; max : int option }
  | Float_range of { min : float option; max : float option }
  | Min_length of int
  | Max_length of int
  | Custom of (field_value -> Say.t option)

type field = {
  key : string;
  label : Say.t;
  help : Say.t option;
  value : field_value;
  initial : field_value;
  provenance : provenance;
  reload_scope : reload_scope;
  validators : validator list;
  read_only : bool;
  error : Say.t option;
}

type state = {
  fields : field array;
  focused : int;
  editing : bool;
  filter : string;
}

val int_val : int -> field_value
val int_val_of_raw : string -> field_value
val float_val : float -> field_value
val float_val_of_raw : string -> field_value
val enum_val : selected:int -> (string * Say.t) list -> field_value
val secret_val : ?revealed:bool -> string -> field_value

val equal_provenance : provenance -> provenance -> bool
val equal_reload_scope : reload_scope -> reload_scope -> bool
val equal_field_value : field_value -> field_value -> bool

val strip_key_prefix : prefix:string -> string -> string
(** Strip a dotted [prefix] (e.g. ["providers.acme_api."]) from a
    canonical TOML key to produce a clean short leaf key. *)

val make_field :
  key:string ->
  label:Say.t ->
  ?help:Say.t ->
  ?provenance:provenance ->
  ?reload_scope:reload_scope ->
  ?validators:validator list ->
  ?read_only:bool ->
  field_value ->
  field

val create : field list -> state

val masked_display : string -> string
(** Render a secret string safely without leaking any character of its contents. *)

val provenance_label : provenance -> Say.t
val reload_scope_label : reload_scope -> Say.t

val validate_field : field -> Say.t option
val validate_all : state -> state * bool
(** Validate every field, updating {!field.error} and returning [true] iff all
    fields pass. *)

val is_dirty : state -> bool
val dirty_fields : state -> field list
val visible_indices : state -> int list
(** Indices of fields matching {!state.filter} across key and bilingual labels. *)

val set_filter : string -> state -> state
(** Update {!state.filter}, exit editing mode, and re-anchor {!state.focused}
    onto the first visible field so hidden fields can never remain focused. *)

val set_value : key:string -> field_value -> state -> state
val move_focus : dir:[ `Prev | `Next ] -> state -> state
val toggle_bool : state -> state
val step_enum : dir:[ `Prev | `Next ] -> state -> state
val toggle_secret_reveal : state -> state
val handle_key : Input.key_event -> state -> state

val diff_preview : state -> Diff.numbered list
(** Compute an inline unified diff of all modified fields against their initial
    values. Secret fields always render as ["[redacted]"] in diffs. *)

val inline_text_rows : string -> int
(** Visible height of a focused inline multiline editor before clipping. *)

val draw :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  lang:Say.lang ->
  ?pad_x:int ->
  ?label_width:int ->
  ?section_header:section_header ->
  ?show_row_badges:bool ->
  ?show_help_footer:bool ->
  ?focused:bool ->
  ?elevated:bool ->
  ?edit_cursor:int ->
  state ->
  int
(** Paint fields, calm [selection_bg] + [▎] focus indicator, optional
    [surface_2] section provenance header band, exception-only or per-row
    provenance/reload badges, Tier-4 italic help/descriptions, validation
    errors, and inline diff preview onto [Cell_grid.t]. Returns visible field
    count drawn. *)
