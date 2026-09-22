(** Keeper_carried_range — how the oldest carried atom moves when a request
    outgrew its marks (RFC keeper-context-window-in-tokens §10.5).

    The ledger says what the last request carried and what the provider
    counted for it. This module decides, from those numbers alone, which
    blocks leave the front so the next request comes down to the low-water
    mark. It never estimates: a block of known size is subtracted, a block of
    unknown size is evicted whole and ends the walk with the total unknown
    until the next usage, and the newest block is never evicted, so a request
    always carries the turn it is in.

    Three triggers, one walk. At a turn boundary, before the candidate's
    first composition of the turn, the ledger's total against the high-water
    mark: every request of the turn then composes from one front, and the
    prefix the provider cached for the turn's first request still matches
    the next. Inside a turn, before every later composition, the same
    judgment again but floored at the turn's first atom: a turn of many tool
    rounds grows the request from one front for hours, so the marks are
    checked each time the last usage is in hand, and the walk takes only
    blocks that lie wholly before the turn in progress ({!within_turn}).
    On a provider refusal, the walk runs at once regardless of the total,
    and without marks it takes exactly one block.

    {!apply_turn_boundary} applies a turn-boundary step to a ledger. A caller
    handling a provider refusal applies an [Evicted] step with
    {!Keeper_model_input_ledger.move_front} before deciding again: the refused
    request reports no usage, so without that the next decision would walk the
    same blocks from the same front. Which blocks are eligible (the
    librarian's reading) and a pinned head are later steps of RFC §11 and are
    not modelled here: the walk starts at the oldest carried block. *)

type reason =
  | Total_unknown  (** The ledger has no measured total to compare. *)
  | Within_high_water  (** The total does not pass the high-water mark. *)
  | Nothing_evictable
      (** Nothing older than the newest block is carried, or the walk took
          nothing. *)
  | Held_by_turn_floor
      (** The total passed the high-water mark, but the oldest carried block
          reaches into the turn in progress, so an in-turn walk takes
          nothing: the turn's own atoms are not evicted from under it. *)

type step =
  | Unchanged of reason
  | Evicted of
      { evicted_blocks : int
      ; evicted_atoms : int
      ; evicted_tokens : int option
            (** Known when every evicted block was measured. *)
      ; first_atom : int  (** The oldest carried atom after the eviction. *)
      ; front_digest : string
            (** The opening-message digest of [first_atom], from the block
                the walk stopped at: what {!Keeper_model_input_ledger.move_front}
                records the moved front with. *)
      ; projected_total : int option
            (** The last measured total minus the evicted tokens, when both
                were known; the next usage replaces it either way. *)
      }

val at_turn_boundary
  :  marks:Runtime_schema.context_marks
  -> Keeper_model_input_ledger.t
  -> step
(** Evict from the front while the projected total is above the low-water
    mark, only when the measured total passed the high-water mark. A request
    with [No_atom_carried] has no named front to advance and is unchanged. *)

val apply_turn_boundary
  :  marks:Runtime_schema.context_marks
  -> Keeper_model_input_ledger.t
  -> Keeper_model_input_ledger.t * step
(** Apply {!at_turn_boundary} to the ledger. An [Evicted] step always advances
    to the block that the same calculation selected; failure to advance is an
    internal contract violation rather than an unchanged projection. *)

val within_turn
  :  marks:Runtime_schema.context_marks
  -> turn_first_atom:int
  -> Keeper_model_input_ledger.t
  -> step
(** {!at_turn_boundary} floored at [turn_first_atom], the first atom of the
    turn in progress (the caller's completed-turn boundary): the walk evicts
    only blocks whose atoms all lie before it, and stops at the first block
    that reaches into the turn even while the projected total is still above
    the low-water mark. [Unchanged Held_by_turn_floor] when the total passed
    the high-water mark and already the oldest carried block reaches into the
    turn. A caller reading a projected total above the low-water mark, or that
    reason, knows the turn's own atoms are what is left to shrink. *)

val apply_within_turn
  :  marks:Runtime_schema.context_marks
  -> turn_first_atom:int
  -> Keeper_model_input_ledger.t
  -> Keeper_model_input_ledger.t * step
(** Apply {!within_turn} to the ledger, as {!apply_turn_boundary} does. *)

val after_overflow
  :  marks:Runtime_schema.context_marks option
  -> Keeper_model_input_ledger.t
  -> step
(** The provider refused the request as too long. With marks, walk down to
    the low-water mark from whatever the ledger knows; without marks, or
    without a measured total, evict the oldest block alone. *)

val step_to_json : step -> Yojson.Safe.t
