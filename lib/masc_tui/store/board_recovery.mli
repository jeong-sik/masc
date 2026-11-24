(** Read-only inventory and operator recovery scoped to the same Keeper and quarantine generation. *)
open Masc_tui_core

type outcome = Accepted | Rejected of string | Unconfirmed of string
type command = Idle | Submitting of Board_quarantine.inventory_item
             | Result of Board_quarantine.inventory_item * outcome
type entry = {
  generation : int;
  inventory : Board_quarantine.inventory Observed.t;
  selected : Board_quarantine.inventory_item option;
  command : command;
}
type t
val empty : t
val shown : keeper:string -> t -> bool
val open_view : keeper:string -> t -> t
val close : t -> t
val entry : keeper:string -> t -> entry
val read : keeper:string -> now:Clock.Mono.t -> t -> t * int
val observe : keeper:string -> generation:int -> Board_quarantine.inventory Observed.t -> t -> t
val move : keeper:string -> direction:Masc_tui_keymap.Keymap.move_dir -> page_rows:int -> t -> t
val selection_index : entry -> int option
val actionable : entry -> Board_quarantine.inventory_item option
val start : keeper:string -> t -> (t * Board_quarantine.inventory_item) option
val finish : Board_quarantine.inventory_item -> outcome -> t -> t
val invalidate : t -> t
