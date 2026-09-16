(** Keeper_carried_range — how the oldest carried atom moves when a request
    outgrew its marks (RFC keeper-context-window-in-tokens §10.5).

    The ledger says what the last request carried and what the provider
    counted for it. This module decides, from those numbers alone, which
    blocks leave the front so the next request comes down to the low-water
    mark. It never estimates: a block of known size is subtracted, a block of
    unknown size is evicted whole and ends the walk with the total unknown
    until the next usage, and the newest block is never evicted, so a request
    always carries the turn it is in.

    Two triggers, one walk. After a response, the ledger's total against the
    high-water mark. On a provider refusal, the walk runs regardless of the
    total, and without marks it takes exactly one block.

    The caller applies an [Evicted] step to the ledger with
    {!Keeper_model_input_ledger.move_front} before deciding again: a refused
    request reports no usage, so without that the next decision would walk
    the same blocks from the same front. Which blocks are eligible (the
    librarian's reading) and a pinned head are later steps of RFC §11 and are
    not modelled here: the walk starts at the oldest carried block. *)

type reason =
  | Total_unknown  (** The ledger has no measured total to compare. *)
  | Within_high_water  (** The total does not pass the high-water mark. *)
  | Nothing_evictable
      (** Nothing older than the newest block is carried, or the walk took
          nothing. *)

type step =
  | Unchanged of reason
  | Evicted of
      { evicted_blocks : int
      ; evicted_atoms : int
      ; evicted_tokens : int option
            (** Known when every evicted block was measured. *)
      ; first_atom : int  (** The oldest carried atom after the eviction. *)
      ; projected_total : int option
            (** The last measured total minus the evicted tokens, when both
                were known; the next usage replaces it either way. *)
      }

val after_response
  :  marks:Runtime_schema.context_marks
  -> Keeper_model_input_ledger.t
  -> step
(** Evict from the front while the projected total is above the low-water
    mark, only when the measured total passed the high-water mark. *)

val after_overflow
  :  marks:Runtime_schema.context_marks option
  -> Keeper_model_input_ledger.t
  -> step
(** The provider refused the request as too long. With marks, walk down to
    the low-water mark from whatever the ledger knows; without marks, or
    without a measured total, evict the oldest block alone. *)

val step_to_json : step -> Yojson.Safe.t
