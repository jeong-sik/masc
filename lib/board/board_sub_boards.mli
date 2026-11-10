(** Sub-board policy and CRUD for one Board store.

    Runtime policy mutations take the store's persistence mutex before its
    state mutex. Post creation uses the same boundary for its final policy
    check and append. This does not serialize different stores or processes;
    startup loaders run before the store is published. Snapshot-save failures
    return a typed error before policy memory is changed. This does not turn
    an unknown filesystem publication into proof of a nonwrite. *)

open Board_types

val sub_board_to_yojson : sub_board -> Yojson.Safe.t
val sub_board_of_yojson : Yojson.Safe.t -> sub_board option

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
