(** Strict current-decision marker. Caller owns persistence; IO is outside the
    state lock. No ordinary operation settles an unknown write. *)
open Board_types

val path : store -> string
val load : store -> (deletion_plan option, board_error) result
(** Missing/empty means no decision. Otherwise exactly one current-format row
    with canonical, unique fixed IDs is required. No torn-tail repair. *)
val require_empty : store -> (unit, board_error) result
(** Fresh marker admission for delete and ordinary snapshot flush. An observed
    foreign decision is preserved for fresh-store initialization. *)

type write =
  | Recorded of deletion_receipt
  | Cleared of deletion_diagnostic list
  | Not_written of deletion_diagnostic list
  | Unknown of deletion_diagnostic list

type readset =
  | Post_readset of {
      parent : posts_source_observation;
      comments : comments_source_observation;
    }
  | Sub_board_readset of {
      posts : posts_source_observation;
      policy : sub_boards_source_observation;
    }

val record : store -> readset:readset -> deletion_plan -> write
(** Exact Posts then Comments or Policy snapshots stay guarded through marker IO.
    The readset kind must match the operation. Both workspaces are revalidated
    before entry. A refused guard never records a decision;
    cleanup after record is retained before finish propagates a reserved cause. *)
val fence_recovery : store -> write
(** Rewrites the exact observed decision bytes through CAS to obtain a new
    durable receipt. Observation alone is not a prior durability receipt. *)
val clear : store -> deletion_receipt -> write
(** Only the exact owned Sources_written receipt may retire its marker. *)
val finish : write -> ('a, board_error) result -> ('a, board_error) result
(** Publish state first, then preserve any original reserved cleanup cause
    through Board_posts_source's existing settlement carrier. *)
