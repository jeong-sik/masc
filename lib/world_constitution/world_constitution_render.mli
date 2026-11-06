(** Rendering the articles a world holds into prompt text (RFC-0442). *)

val articles : World_constitution_types.t list -> string
(** One line per article, id first so a keeper can name the one it wants taken
    back without a second tool to list them.

    Empty for an empty list. That is what keeps a world which never wrote an
    article byte-identical to one from before this existed — the prompt slot
    renders nothing rather than an empty heading. *)

(** How the articles a world holds now differ from the ones a System was
    rendered with (RFC-0491 §3.2), by the id and text {!articles} renders. An
    article edited in place is both: its old line removed, its new line added.
    At least one of the two lists is non-empty. *)
type amendments = private
  { added : World_constitution_types.t list
        (** Held now and not rendered in the System, in the order the world
            holds them. *)
  ; removed : World_constitution_types.Article_id.t list
        (** Rendered in the System and no longer held with that text, in the
            System's order. *)
  }

val amendments :
  built_with:World_constitution_types.t list ->
  World_constitution_types.t list ->
  amendments option
(** [None] when both lists render the same lines. *)

val added_lines : amendments -> string
(** The added articles as {!articles} renders them: id and text, with the
    same escape. Empty when none was added. *)

val removed_lines : amendments -> string
(** One ["- \[id\]"] line per removed article. Empty when none was removed. *)
