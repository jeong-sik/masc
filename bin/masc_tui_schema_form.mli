(** Pure editor for the same schema subset enforced at the Lane boundary.
    Ctrl-E opens object-array item editing. Item review/apply remains local;
    only the enclosing review emits Submit. Esc discards nested edits.

    A root [{"type":"object","oneOf":[…]}] schema is edited one alternative
    at a time, and only the chosen alternative's fields are shown. With two
    or more alternatives the first slot chooses one with Left/Right; choosing
    another alternative drops what was typed for the previous one. The value
    must be one of the chosen alternative. Any other [oneOf] node, including
    the root of an array item's form, stays one JSON field. *)
type t
type event = Updated of t | Submit of Yojson.Safe.t | Cancel
val create : schema:Yojson.Safe.t -> initial:Yojson.Safe.t -> (t, string) result
(** With two or more alternatives, [initial] opens the alternative it is a
    valid value of when exactly one is; otherwise nothing is chosen and an
    alternative chosen later starts empty. A schema with one alternative
    opens it with [initial], like a schema without alternatives. *)
val create_for_row :
  schema:Yojson.Safe.t -> branch:int option -> locked:(string * Yojson.Safe.t) list ->
  (t, string) result
(** Opens a row action on the alternative at position [branch] of the
    schema's [oneOf], or on the schema itself when [branch] is [None]. The
    alternative cannot be changed. Each [locked] top-level member is shown
    with its value and reaches the action unchanged: no slot holds it, so no
    key can edit it. The cursor starts on the first member left to fill.
    Errors when the schema and [branch] disagree about alternatives, when
    [branch] is negative or past the last alternative, or when a locked
    member is named twice, is not a member of the alternative or fails its
    schema. *)
val insert_text : text:string -> t -> t
val handle : key:string -> t -> (event, string) result
val lines : ?show_description:bool -> t -> string list
(** Render the selected field and its available controls. When
    [show_description] is true, also render the selected field's schema
    description; it defaults to false. *)
val value : t -> (Yojson.Safe.t, string) result
