(** Sub-board policy and CRUD for one Board store.

    Runtime policy mutations take the store's persistence mutex before its
    state mutex. Post creation uses the same boundary for its final policy
    check and append. This does not serialize different stores or processes;
    startup loaders run before the store is published. Snapshot-save failures
    retain the existing logging behavior and are not a durable receipt. *)

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
(** Capture the changed policy and its snapshot under the state lock, then
    save outside that lock while retaining the persistence lock. *)

val delete_sub_board :
  store -> sub_board_id:string -> (unit, board_error) result
