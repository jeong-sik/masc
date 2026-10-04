(** One row per model binding in runtime.toml, for the pane that answers
    "which knobs are actually set on this model".

    The knobs live in different tables. [reasoning-effort] and [temperature]
    are read from [\[models.NAME\]] and [max-tokens] from [\[PROVIDER.NAME\]]
    (runtime_toml.ml:1102 and the binding parser respectively). Reading the
    file top to bottom hides that split across hundreds of lines, so an
    operator adding a knob copies whichever sibling they happened to scroll
    past. This table puts all three columns beside the model name.

    Absence is a value here, not a blank: a binding with no effort sends no
    [reasoning_effort] field, and Ollama then turns thinking on by itself
    (docs.ollama.com/api/openai-compatibility). {!row} keeps [None] so the
    renderer can say so. *)

type row =
  { model : string
        (** Binding name as written in the section header, quotes stripped. *)
  ; provider : string  (** Section prefix: [ollama_cloud], [glm-coding], ... *)
  ; api_name : string option  (** [api-name] when the binding renames the model. *)
  ; reasoning_effort : string option  (** From [\[models.NAME\]]. *)
  ; temperature : string option
        (** From [\[models.NAME\]], preserving the source spelling. *)
  ; max_tokens : int option  (** From [\[PROVIDER.NAME\]]. *)
  }

val parse : string list -> row list
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
