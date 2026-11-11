(** Comment queries and write-ahead mutations for one Board store.

    Staging validates without publishing state. The persistence lock spans
    append and a fresh state-lock commit. If that commit refuses the appended
    row, cleanup rewrites the current comments within the same persistence lock.
    This owner retains the existing admission and partial-source policies. *)

open Board_types

val compare_comments_oldest_first : comment -> comment -> int
(** Shared ordering for standalone and atomic post/thread reads: creation
    timestamp, then canonical comment ID. Hidden by the public Core interface. *)

val observe_comments_unlocked : store -> Post_id.t -> comments_observation
(** Capture indexed rows and completeness while the caller holds persistence
    then state locks. Does not acquire locks or perform source I/O. *)

val observe_comments :
  store -> post_id:string -> (comments_observation, board_read_error) result
(** Display rows with their completeness, including accepted prefixes of a
    refused source. Does not require the parent post to exist. *)

val add_comment :
  store ->
  reader:Board_access.reader ->
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
  reader:Board_access.reader ->
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
(** Complete indexed comments for the parsed post ID, without checking parent
    existence. Only a complete source may answer [Ok []]. An incomplete source
    answers [Read_source_unavailable]; retained orphan rows remain readable. *)

val get_comment :
  store -> comment_id:string -> (comment, board_error) result
(** Complete-source point query; display rows remain available through
    {!observe_comments} when the source is incomplete. *)

val list_comments : store -> ?limit:int -> unit -> comment list
