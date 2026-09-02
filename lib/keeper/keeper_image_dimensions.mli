(** Pixel dimensions, read from the leading bytes of an image header.

    This module depends on nothing so the chat store can measure an
    attachment without inheriting the vision tool's dependency cone (which
    closes a module cycle through the store). *)

val image_dimensions : string -> (int * int) option
(** [(width, height)] of the bytes whose format this module admits: PNG
    reads its fixed-offset IHDR, JPEG walks to the first SOF, GIF reads the
    logical screen. WebP answers [None] rather than guessing across its
    three frame layouts. [None] means "say nothing" -- callers show the
    note without a size rather than a wrong one. *)
