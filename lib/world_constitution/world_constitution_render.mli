(** Rendering the articles a world holds into prompt text (RFC-0442). *)

val articles : World_constitution_types.t list -> string
(** One line per article, id first so a keeper can name the one it wants taken
    back without a second tool to list them.

    Empty for an empty list. That is what keeps a world which never wrote an
    article byte-identical to one from before this existed — the prompt slot
    renders nothing rather than an empty heading. *)
