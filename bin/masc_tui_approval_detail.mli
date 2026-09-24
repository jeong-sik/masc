(** The whole ask an approval is asking about, as rows a pane can draw.

    The Approvals list draws each ask on one row through [single_line], which
    escapes every byte under 0x20: a newline becomes the six characters
    [\x0A] and the row is then cut to the terminal's width. An [Edit] whose
    replacement is a page of code reads as its first forty characters, and
    there was no second screen to open. The operator pressed [y] on something
    they had not seen.

    These rows keep the newlines the ask was written with and wrap the rest,
    so what is approved is what was read. *)

type line = private
  { label : string option
        (** The field name this row opens with, when it has one. A short value
            sits beside its name on the same row; a long or multi-line one
            keeps the name a row of its own. *)
  ; text : string
  }

val of_fields : width:int -> (string * string) list -> line list
(** [of_fields ~width fields] is [(label, value)] pairs laid out for a pane
    [width] cells wide. A value keeps its own line breaks and each line wraps;
    a blank value is drawn as such rather than omitted, because a field that
    is present and empty is a different fact from one that is absent.

    Every label goes through [Masc.Tui_decode.sanitize_terminal_text] and
    every value through [Masc.Tui_decode.sanitize_terminal_lines] first: a
    value's newlines stay line breaks, and every other control character is
    drawn as its visible escape ([\x1B], [\x09]), so no field can carry an
    escape sequence to the terminal and none is hidden as a space. [line] is
    private, so this is the only way a row of the pane is made. *)
