(** The Story window docked below the Keepers list (RFC-0515 section 2.5).

    The window shows the Keeper the list cursor is on, on one of three pages.
    This module holds the pages and what a key does to the window, open or
    closed. It reads no Keeper values, so the TUI state can hold a page without
    depending on the readings the window draws. *)

type page =
  | Story
  | Schedule
  | Memory

val pages : page list
(** The pages in tab order. *)

val tab_label : page -> string
(** The name drawn on the page's tab, with the key that jumps to it. *)

type action =
  | Show of page  (** Open the window on this page, or move it to this page. *)
  | Close  (** Close the window. *)
  | Open_detail  (** Close the window and open the Keeper's detail. *)

val action_of_key : on_heading:bool -> page option -> string -> action option
(** What [key] does to the window, [None] when it is closed. [key] is a name
    from the input decoder. [None] means the window does not take the key and
    the list handles it as it does with the window closed. A closed window
    takes Enter alone, and an open one takes the keys of its pages.

    [on_heading] is true while the list cursor stands on a group heading. A
    heading names no Keeper, so a closed window opens nothing there and an open
    one leaves Enter and Right to the list, where Right folds the group. *)
