(** Pure application and support maintenance of one Librarian decision.
    All publication effects belong to the caller. *)
open Keeper_memory_os_types

type t = private
  { facts : fact list
  ; claims_refused : fact list
  ; absorbed_into : string Set_util.StringMap.t
    (** Only absorptions whose destinations survive support maintenance. *)
  ; invalidated : Keeper_memory_os_current_types.support_invalidation list
  }

val plan
  :  current:fact list
  -> dropped:dropped_statement list
  -> absorbed:absorbed_statement list
  -> revisions:revision list
  -> new_claims:fact list
  -> t
(** Preserve current fact fields/order and first accepted new-claim order.
    A new successor of a no-longer-current source is refused. Successor-linked
    retirements and absorptions require a destination in the maintained facts.
    A removal whose destination disappears is withdrawn before recomputing
    support; ordinary support invalidation can still remove its source.
    Withdrawn removals are never enabled
    again in this decision, even if retaining a source restores support for the
    destination. Each retry strictly shrinks the removal sets. Plain drops have
    no destination and remain unconditional. Claimed successors of missing
    original sources remain refused through every retry. *)
