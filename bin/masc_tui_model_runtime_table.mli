(** Account/model settings projected from the same typed TOML parser as the
    runtime. Shared model sets expand to one row per account binding; quoted
    paths and comments follow TOML syntax rather than line heuristics. *)

type row =
  { model : string
        (** Binding name as written in the section header, quotes stripped. *)
  ; provider : string  (** Section prefix: [ollama_cloud], [glm-coding], ... *)
  ; api_name : string option  (** [api-name] when the binding renames the model. *)
  ; reasoning_effort : string option  (** From [\[models.NAME\]]. *)
  ; temperature : string option
        (** From [\[models.NAME\]], using a round-trip-safe float representation;
            unchanged form values preserve the original source spelling. *)
  ; context : (string * int) option
        (** Declared context precedence: binding, provider, model; absent requires catalog resolution. *)
  ; model_context : int option (** Original shared model declaration, before overrides. *)
  ; max_tokens : int option  (** From [\[PROVIDER.NAME\]]. *)
  }

val parse : string list -> (row list, string) result
(** [parse lines] reads the runtime.toml source the TUI already fetches for
    the raw config pane. Rows come back sorted by provider then model.

    A model with a [\[models.NAME\]] table but no provider binding is
    skipped: it names no lane and has no [max-tokens] column to show. *)

val render : width:int -> ?pane:int -> row list -> string list
(** Fixed-column table when every mandatory reading fits, and a stacked
    item layout when one does not.

    [width] is the width the table may spend. [pane], when given, is the
    number of cells the drawing surface actually offers the table after its
    own frame and indent. A table wider than the pane used to be handed back
    anyway and the frame cut its tail, so a mandatory reading silently lost
    cells; [render] now falls back to stacked wrapped lines before that can
    happen. The two knob columns keep their width in table mode because a
    truncated number reads as a different number. *)

val fits : width:int -> row list -> bool
(** [fits ~width rows] reports whether the fixed-column table renders every
    mandatory reading (provider, model, effort, temperature, max-tokens) in
    [width] cells. The pane needs this to decide between the table and the
    stacked layout before drawing; the table itself always renders, so this
    is a query, not a precondition. *)

val stacked_item_starts : pane:int -> row list -> int list
(** [stacked_item_starts ~pane rows] is the 0-based line index, into the
    document {!render} produces in stacked mode, where each binding's item
    begins -- one entry per row, in order. The pane's cursor walks bindings,
    not wrapped lines, so this is how it finds the line to mark and follow. *)

val detail_lines : row -> string list
(** Selected-binding explanation for the Models pane. It names the effective
    API model and the exact TOML sections that own each knob. A model name that
    is not a bare TOML key is quoted in the section path. *)
