(** One row per model binding in runtime.toml, for the pane that answers
    "which knobs are actually set on this model".

    The two knobs live in different tables. [reasoning-effort] is read from
    [\[models.NAME\]] and [max-tokens] from [\[PROVIDER.NAME\]]
    (runtime_toml.ml:1102 and the binding parser respectively). Reading the
    file top to bottom hides that split across hundreds of lines, so an
    operator adding a knob copies whichever sibling they happened to scroll
    past. This table puts both columns beside the model name.

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
  ; max_tokens : int option  (** From [\[PROVIDER.NAME\]]. *)
  }

val parse : string list -> row list
(** [parse lines] reads the runtime.toml source the TUI already fetches for
    the raw config pane. Rows come back sorted by provider then model.

    A model with a [\[models.NAME\]] table but no provider binding is
    skipped: it names no lane and has no [max-tokens] column to show. *)

val render : width:int -> row list -> string list
(** Fixed-column table. [width] clips the model column when the terminal is
    narrow; the two knob columns keep their width because a truncated number
    reads as a different number. *)
