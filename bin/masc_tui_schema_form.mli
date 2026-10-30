(** Pure editor for the same schema subset enforced at the Lane boundary.
    Ctrl-E opens object-array item editing. Item review/apply remains local;
    only the enclosing review emits Submit. Esc discards nested edits. *)
type t
type event = Updated of t | Submit of Yojson.Safe.t | Cancel
val create : schema:Yojson.Safe.t -> initial:Yojson.Safe.t -> (t, string) result
val insert_text : text:string -> t -> t
val handle : key:string -> t -> (event, string) result
val lines : ?show_description:bool -> t -> string list
(** Render the selected field and its available controls. When
    [show_description] is true, also render the selected field's schema
    description; it defaults to false. *)
val value : t -> (Yojson.Safe.t, string) result
