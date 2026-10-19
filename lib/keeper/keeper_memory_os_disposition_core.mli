(** Pure application of a Librarian decision to the facts current at that step.
    Support maintenance and all publication effects belong to the caller. *)
open Keeper_memory_os_types

type t = private
  { facts : fact list
  ; claims_refused : fact list
  ; absorbed_into : string Set_util.StringMap.t
    (** Candidate absorption destinations, before support maintenance. A target
        in this map is not a guarantee that it survives in the next facts. *)
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
    retirements and absorptions require a held or accepted destination, as in
    the store. Plain drops have no destination. *)
