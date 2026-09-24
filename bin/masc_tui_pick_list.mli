(** A choose-one-of-N list: where its cursor stands and the words typed to
    narrow it.

    The items are not held here. A picker computes them from the snapshot it
    draws, and hands the same list to {!apply} and {!view}, so the key that
    moves the cursor and the frame that draws it read one list.

    The cursor indexes the narrowed list, and every reading clamps it to that
    list, so a filter that shrinks the list, or a reload that drops rows, can
    never leave the cursor past the end. *)

type t = private
  { cursor : int
  ; query : string option
      (** [Some q] while the operator is typing a filter. Every printable key
          goes into [q] then, the picker's letter keys with them. *)
  }

val closed : t
(** Cursor on the first row, no filter. What a picker opens with. *)

type step =
  | Prev
  | Next
  | Page_prev
  | Page_next
  | First
  | Last

type action =
  | Move of step
  | Open_query  (** [/]: start typing a filter. *)
  | Type of string  (** Typed text on the end of the filter. *)
  | Erase  (** Backspace in the filter. *)
  | Back
      (** Esc, or a picker's own close key: drops the filter when one is
          open, and closes the picker when none is. *)
  | Choose  (** Enter. *)

val action_of_key : close_keys:string list -> t -> string -> action option
(** The action a key names in this list, or [None] when the key is not the
    list's. While a filter is being typed, every printable character is
    [Type], so [j], [k], [/] and the picker's [close_keys] are text there.
    Outside a filter, [j]/[k] and the arrows step, [PgUp]/[PgDn] move a page,
    [Home]/[End] jump, [/] opens the filter and [close_keys] close. *)

type 'a outcome =
  | Stay of t
  | Chosen of 'a
  | Dismissed

val apply :
  page:int -> label:('a -> string) -> 'a list -> t -> action -> 'a outcome
(** [page] is the number of rows the picker draws; a page key moves that far.
    [Choose] on an empty narrowed list stays: there is nothing under the
    cursor to choose, and the header already says [0 of N]. *)

val type_text : t -> string -> t
(** The filter with [text] on its end, opening it if none was open: what a
    paste into the filter does. The cursor goes back to the first match. *)

type 'a view =
  { rows : 'a list  (** The window of the narrowed list the picker draws. *)
  ; selected_row : int option
      (** The cursor's row inside [rows]; [None] when [rows] is empty. *)
  ; shown : int  (** How many items the filter keeps. *)
  ; total : int  (** How many items there are before the filter. *)
  ; filter : string option
  }

val view : page:int -> label:('a -> string) -> 'a list -> t -> 'a view

val summary : 'a view -> string
(** The header's count and filter: ["12 of 12 · / filter"] with no filter,
    ["filter: cl▏ 3 of 12"] while one is typed. *)

val lowercase_contains : needle:string -> string -> bool
(** Whether [needle] occurs in the haystack, folding ASCII case on both
    sides. *)
