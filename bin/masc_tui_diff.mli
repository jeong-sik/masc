(** The lines one edit removed and added.

    A keeper's [Edit] is recorded as the exact text it replaced and the exact
    text it wrote, so what an operator wants to see is the difference between
    those two, line by line. That is what this produces.

    {1 What it is not}

    Not a general diff. Both sides come from one tool call, so they are the
    two halves of a single replacement rather than two revisions of a file --
    there is no rename to follow, no context to fetch, and no hunk to
    assemble. The common prefix and suffix are shared lines and everything
    between them changed; that is the whole shape.

    Not a minimal edit script either. A Myers diff would find fewer changed
    lines inside the middle, and for a replacement whose middle is usually a
    handful of lines it would spend that work to move a row or two. If a
    middle ever grows large enough for the difference to show, this is where
    a real algorithm goes. *)

type row =
  | Context of string  (** Unchanged, and in both halves. *)
  | Removed of string
  | Added of string

val rows : before:string -> after:string -> row list
(** The two halves as one sequence, removals before additions in the middle.

    A trailing newline does not make an empty last line: text ending in one is
    the same lines as text without it, and treating them differently would
    show a change nobody made. *)

val counts : row list -> int * int
(** Removed and added line counts, for a caller that wants to say how large a
    change is before drawing it. *)
