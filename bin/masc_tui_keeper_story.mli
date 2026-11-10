(** The Story window docked below the Keepers list (RFC-0515 section 2.5).

    The window shows the Keeper the list cursor is on, on one of three pages.
    This module holds the pages and what a key does to the window, open or
    closed. It reads no Keeper values, so the TUI state can hold a page without
    depending on the readings the window draws. *)

type page =
  | Story
  | Schedule
  | Memory
  | World

val pages : page list
(** The pages in tab order. *)

val tab_label : page -> string
(** The name drawn on the page's tab, with the key that jumps to it. *)

type selection = Keeper_selected | World_selected | No_selection

type memory_destination = Memory_recent | Memory_frequent | Memory_changes | Memory_storage

type action =
  | Show of page  (** Open the window on this page, or move it to this page. *)
  | Close  (** Close the window. *)
  | Open_detail  (** Close the window and open the Keeper's detail. *)
  | Open_world  (** Select World in a memory/age view and open its own dock. *)
  | Open_memory of memory_destination
      (** Open the shared Memory browser for the selected Keeper. *)

val action_of_key : selection:selection -> page option -> string -> action option
(** What [key] does to the window, [None] when it is closed. [key] is a name
    from the input decoder. [None] means the window does not take the key and
    the list handles it as it does with the window closed. A closed window
    takes Enter for the selected row, and an open one takes the keys of its
    pages, [s] and [m] in either case. [W] opens World from any list view;
    lowercase [w] remains the Keeper wake action.

    [selection] distinguishes a Keeper, the shared World, and a heading.
    World Enter opens its own dock; its s/m/Tab/Right never dispatch Keeper
    actions. The Keeper tabs in {!pages} exclude the World dock.
    Without a selected Keeper or World --
    the cursor stands on a group heading, or the list has no Keeper -- Enter
    opens nothing and an open window leaves Enter and Right to the list,
    where on a heading Left folds the group and Right unfolds it.
    On a selected Keeper's Memory preview, Enter or [1] opens recent records,
    [2] recorded retrievals, [3] committed changes and [4] storage in the same
    Memory browser. The preview has no separate detail pages or cursor. *)
