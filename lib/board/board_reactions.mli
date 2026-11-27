(** Reaction queries require a complete observed reaction source. Toggles
    retain persistence across staging, exact snapshot CAS, model publication
    and receipt acknowledgement. Uncertain writes and failed publication do
    not authorize a normal retry or blind rollback. *)

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

val normalize_reaction_user_id : string option -> string option

val reaction_summaries_batch_unlocked :
  store ->
  targets:(reaction_target_type * string) list ->
  ?user_id:string ->
  unit ->
  ((reaction_target_type * string) * reaction_summary list) list
(** Compute batch reaction summaries while caller holds [persist_mutex] and
    [store.mutex] and has already canonicalized [targets]. *)

val list_reactions_batch :
  store ->
  targets:(reaction_target_type * string) list ->
  ?user_id:string ->
  unit ->
  (((reaction_target_type * string) * reaction_summary list) list, board_error) result
(** One scan produces a row for each distinct requested target, in unspecified
    order. A target with no matching reaction rows receives an empty summary;
    target existence is not checked. *)

val toggle_reaction :
  store ->
  reader:Board_access.reader -> target_type:reaction_target_type ->
  target_id:string ->
  user_id:string ->
  emoji:string ->
  (reaction_toggle_result, board_error) result
(** Retain the original reader independently of user_id and guard complete
    canonical parent snapshots through rewrite. The result's post_id is that
    exact admitted parent, including for a comment target. *)
