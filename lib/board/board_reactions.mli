(** Reaction queries and durable toggles for one Board store.

    Queries schedule the existing sweep before taking the state lock. A toggle
    first rejects an unreadable reaction source, then keeps the persistence
    lock across staging, snapshot write, state commit and any rollback write.
    Staging restores the original memory state before the snapshot is written.
    This private owner uses the canonical Board store and reaction types. *)

open Board_types

val compare_reaction_target_type : reaction_target_type -> reaction_target_type -> int
(** Canonical closed-variant ordering, retained by the public Core include. *)

val list_reactions :
  store ->
  target_type:reaction_target_type ->
  target_id:string ->
  ?user_id:string ->
  unit ->
  (reaction_summary list, board_error) result

val list_reactions_batch :
  store ->
  targets:(reaction_target_type * string) list ->
  ?user_id:string ->
  unit ->
  ((reaction_target_type * string) * reaction_summary list) list
(** One scan produces a row for each distinct requested target, including
    unknown targets with an empty summary. Row order is unspecified. *)

val toggle_reaction :
  store ->
  target_type:reaction_target_type ->
  target_id:string ->
  user_id:string ->
  emoji:string ->
  (reaction_toggle_result, board_error) result
