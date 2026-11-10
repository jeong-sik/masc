open Board_types

type deletion_authorization =
  | Operator_deletion
  | Author_deletion of { reader : Board_access.reader; author : Agent_id.t }
  | Cleanup_deletion of Board_access.reader
(** Calling-boundary authority, never decoded from request JSON. Author and
    cleanup retain the actual reader; neither is promoted to operator. *)

val delete_post :
  store -> authorization:deletion_authorization -> post_id:string ->
  (deletion_outcome, board_error) result
(** Record the fixed decision before model changes. Decision_pending does not
    imply an applied deletion. Persistence_pending does. Error is pre-decision.
    Recheck actor/reader against the current model and the canonical parent in
    the expected source snapshot: settling a file write does not publish its
    model. The child IDs come from the canonical comments snapshot. Guard Posts
    then Comments through recording, so a child accepted before the decision
    is captured or causes a pre-decision refusal, before model changes. *)
val delete_sub_board :
  store -> authorization:sub_board_deletion_authorization -> sub_board_id:string ->
  (deletion_outcome, board_error) result
(** Resolve ID/slug from canonical policy, verify the current owner and complete
    model/source correspondence, then record the exact affected Posts IDs while
    guarding Posts -> Policy -> decision. Persist only Posts and Policy. Fresh
    recovery unlinks those IDs still in the original hearth and preserves later
    rows, moved posts and a new board with the same slug but another ID. *)
val flush_dirty : store -> unit
(** Resume owned known work; never replay a marker-unknown store. *)
val recover_on_initialize : store -> (unit, board_error) result
(** Fresh initialization only: durably fence a strict observed plan, then filter
    its fixed IDs from complete fresh sources through their own CAS writers. *)
