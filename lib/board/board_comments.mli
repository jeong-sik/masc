(** Comment queries and write-ahead mutations for one Board store.

    Staging validates without publishing state. The persistence lock spans
    append and a fresh state-lock commit. If that commit refuses the appended
    row, cleanup rewrites the current comments only after the lock is released.
    This owner retains the existing admission and partial-source policies. *)

open Board_types

val compare_comments_oldest_first : comment -> comment -> int
(** Shared ordering for standalone and atomic post/thread reads: creation
    timestamp, then canonical comment ID. Hidden by the public Core interface. *)

val add_comment :
  store ->
  lookup:Recipient_lookup.t ->
  post_id:string ->
  author:string ->
  content:string ->
  ?parent_id:string ->
  ?ttl_hours:int ->
  unit ->
  (comment, board_error) result

val add_comment_with_audience :
  store ->
  lookup:Recipient_lookup.t ->
  post_id:string ->
  author:string ->
  content:string ->
  ?parent_id:string ->
  ?ttl_hours:int ->
  unit ->
  (comment_creation, board_error) result

val read_comments :
  store -> post_id:string -> (comment list, board_read_error) result
(** Reads indexed comments for the parsed post ID without checking whether
    the post exists. No indexed rows yields [Ok []]; retained orphan rows
    remain readable under their recorded post ID. *)

val get_comment :
  store -> comment_id:string -> (comment, board_error) result

val list_comments : store -> ?limit:int -> unit -> comment list
