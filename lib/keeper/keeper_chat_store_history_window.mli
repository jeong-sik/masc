(** The window of messages that [load] and [load_page] return.

    [history_window] returns a pair of functions: [push] adds one message in
    file order and [finish] returns the window with a flag that says whether a
    row was evicted. A window keeps at most [max_history] user, assistant and
    failed-request rows and at most the rest of [max_total_lines] in other
    rows, and the oldest row of a kind leaves first. [finish] also drops the
    tool rows at the start of the window whose owning user row was cut off
    ([drop_leading_orphan_tool_messages]).
    [load_page] reads at most [tail_read_bytes] before the cut and keeps the
    messages older than [before] when it is given. It finds the cut by a
    binary search over byte offsets ([find_cut], with [probe_ts] and
    [slice_lines] reading [probe_bytes] at a time), redacts the window and sets
    [has_more] when older rows remain. [load] is the window of [load_page]
    without [before].
    [Keeper_chat_store] includes this module. *)
open Keeper_chat_types

val max_history : int

val max_total_lines : int

type page = { messages : chat_message list; has_more : bool }

(* One row of [load_page]'s running window. *)
type window_row =
  { message : chat_message
  ; mutable in_window : bool
  }

val history_window :
  window_history:int ->
  window_secondary:int ->
  (chat_message -> unit) *
  (unit -> chat_message list * bool)

val load_page :
  base_dir:string -> keeper_name:string -> ?before:float -> ?max_total:int ->
  unit -> page

val load :
  base_dir:string -> keeper_name:string -> chat_message list
