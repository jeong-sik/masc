module Lane = Librarian_memory_lane
module Digest = Agent_core.Checkpoint_objects

type read =
  | Committed
  | Refused_not_all_sized of
      { basis : Digest.digest
      ; lane : Lane.t
      ; slots : (Lane.slot_key * Librarian_slot_outcome.unanswered) list
      }
  | Lane of
      { one_item : bool
      ; silent : bool
      ; basis : Digest.digest
      ; slots : (Lane.slot_key * Librarian_slot_outcome.unanswered) list
      }
  | Input_fault of Librarian_unit.input_fault
  | Ask_failed of Librarian_read_result.failed

type room =
  | Made
  | Unchanged
  | Stale
  | Not_judged
  | Fits_none of
      { memory : Digest.digest
      ; lane : Lane.t
      }

let silent (lane : Lane.t) slots =
  (not (List.is_empty lane.unadmitted))
  || List.exists
       (fun key ->
          match List.find_opt (fun (slot, _) -> Lane.equal_slot_key key slot) slots with
          | None | Some ((_ : Lane.slot_key), Librarian_slot_outcome.Silent _) -> true
          | Some ((_ : Lane.slot_key), Refused (_ : Librarian_slot_outcome.refusal)) -> false)
       (lane.http @ lane.cli)
;;
