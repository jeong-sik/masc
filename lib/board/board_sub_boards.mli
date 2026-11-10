(** Sub-board policy and CRUD for one Board store.

    Runtime policy mutations take the store's persistence mutex before its
    state mutex. Policy writes compare the exact loaded file under the existing
    stable file lock before publication. Stale writers refuse. This does not
    validate another writer's policy changes atomically with post creation,
    nor make policy deletion and post hearth unlinking one transaction. *)

open Board_types

val sub_board_to_yojson : sub_board -> Yojson.Safe.t
val sub_board_of_yojson : Yojson.Safe.t -> sub_board option

val reload_sub_boards : store -> (int, string * exn) result
(** Explicit source load/reload. Replace both indexes on complete reads;
    partial rows grant no query or mutation authority. Unknown writes and
    interrupted publication require a fresh store. Count physical rows. *)

val create_sub_board :
  store ->
  slug:string ->
  name:string ->
  description:string ->
  owner:string ->
  ?members:string list ->
  ?access:sub_board_access ->
  unit ->
  (sub_board, board_error) result
(** The final uniqueness check precedes append while the persistence lock is
    held. An occupied slug returns [Already_exists] without appending. *)

val get_sub_board :
  store -> sub_board_id:string -> (sub_board, board_error) result

val list_sub_boards : store -> sub_board list
(** Best-effort display only; cannot establish policy completeness. *)

val read_sub_boards : store -> (sub_board list, board_error) result

val update_sub_board :
  store ->
  sub_board_id:string ->
  ?name:string ->
  ?description:string ->
  ?members:string list ->
  ?access:sub_board_access ->
  unit ->
  (sub_board, board_error) result
(** Capture the candidate policy and its snapshot without changing memory.
    Retain persistence while saving outside the state lock, then publish the
    policy under a fresh state lock only after the save succeeds. *)

val delete_sub_board :
  store -> sub_board_id:string -> (unit, board_error) result
(** Persist the policy removal before removing it from memory. The related
    post hearth changes still become dirty work for the posts flusher; this
    interface does not promise a transaction across those two sources. *)
