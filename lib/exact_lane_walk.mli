(** One walk over an exact lane's slots, one slot per step.

    RFC exact-lane-walks-one-slot-list sections 3.3, 3.5 and 3.6. A lane
    gives the walk its slots in the order it wants them walked (declared
    order with the Keeper's preference applied), what each slot is, and how
    one slot is visited. Before every step the walk orders the slots that
    remain. Then it calls the first slot that can be called without
    waiting, whatever its kind, and visits one slot per step until a slot
    answers, a visit stops the walk, or no slot remains.

    Two things end a walk early. A visit or [on_advance] answers [Stop],
    because masc failed to record its own fact. Or the fiber is cancelled.
    Every other failure of a slot moves on to the next slot. *)

type kind =
  | Http  (** A catalog slot: an AGENT_CORE flow sends it. *)
  | Cli  (** An official client slot: a one-shot runs it. *)

(** How a slot takes a seat. *)
type seats =
  | Seats_of of Llm_provider.Provider_admission.seat_source
      (** The visit holds one seat of this source while it runs. *)
  | Seatless
      (** The visit sends nothing, because the slot is refused before any
          request, so it needs no seat. The walk calls it when the order
          reaches it, as it calls a slot with a free seat. *)

(** How one visit ended. *)
type ('value, 'failure, 'stop) visit_end =
  | Answer of 'value  (** The slot answered and the lane accepted the value. *)
  | Advance of 'failure  (** The slot failed; the walk moves on. *)
  | Stop of 'stop  (** masc failed to record its own fact; the walk ends. *)

(** What happened to one slot the walk did not end on. *)
type ('slot, 'failure) passed =
  | Held of
      { slot : 'slot
      ; until : float
      }
      (** Not called: its provider stated a time, [until] in Unix epoch
          seconds, before which it is not to be called. *)
  | Seats_full of 'slot
      (** Not called: its seats were full and a later slot gave a seat
          first. *)
  | Failed of
      { slot : 'slot
      ; failure : 'failure
      }
      (** Called, and it failed. *)

type standing =
  | Every_slot_resting
      (** The walk passed at least one slot, and every slot it passed was
          held or failed on a refusal of its account's standing
          ([rests]). *)
  | Not_every_slot_resting

(** [passed] lists every slot the walk passed, in the order it passed
    them. *)
type ('slot, 'value, 'failure, 'stop) walk_result =
  | Answered of
      { slot : 'slot
      ; value : 'value
      ; passed : ('slot, 'failure) passed list
      }
  | Exhausted of
      { passed : ('slot, 'failure) passed list
      ; standing : standing
      }
  | Stopped of
      { slot : 'slot
      ; stop : 'stop
      ; passed : ('slot, 'failure) passed list
      }
      (** [slot] is the slot the walk stopped at: the one visited, or the
          one [on_advance] was about to move to. *)

(** Walk [slots] in the order given.

    {b Order.} Before every step the walk orders the slots that remain at
    [now ()] with {!Runtime_candidate_standing.order_exact}, reading each
    slot's [quota_scope_of] and [candidate_backpressure_of]. A slot the
    order holds is passed as [Held] and not called in this walk. Until the
    hard cut (RFC section 4) the registry lists HTTP slots before CLI
    slots, so the walk orders each kind apart and walks the HTTP slots
    first, as lanes do today.

    {b Seats.} The walk calls the first slot of the order that can be
    called without waiting: a [Seatless] slot, or one whose source gives a
    seat at once ({!Llm_provider.Provider_admission.try_first_seat}). When
    no slot can, it waits on the sources of all of them and calls the slot
    whose seat comes first
    ({!Llm_provider.Provider_admission.take_first_seat}). Either way the
    slots with seats ahead of the called one are passed as [Seats_full] and
    not called in this walk. Kind plays no part.

    {b Visit.} The seat goes to [visit] and is returned when the visit
    ends: answered, failed, stopped or raised. A visit may hand the seat on
    to a flow that returns it earlier; a seat returned twice is returned
    once. Before the walk calls a slot after a failed one,
    [on_advance ~failed ~next] records the move with the last failure and
    the slot about to be called, while that slot's seat is held. An
    [Error] ends the walk as [Stopped] at [next].

    {b Passes.} [on_pass] hears of each slot the walk passes when it
    passes it, in the order of [passed]: a held slot before the step that
    sets it aside, a full slot before the slot called in its place, a
    failed slot after its visit. A lane records its run there.

    Cancellation propagates, and a seat the walk holds is returned. *)
val walk
  :  now:(unit -> float)
  -> kind:('slot -> kind)
  -> quota_scope_of:('slot -> Runtime_quota_window.scope option)
  -> candidate_backpressure_of:('slot -> Runtime_candidate_backpressure.candidate option)
  -> seats:('slot -> seats)
  -> visit:
       ('slot
        -> Llm_provider.Provider_admission.seat option
        -> ('value, 'failure, 'stop) visit_end)
  -> on_advance:(failed:'failure -> next:'slot -> (unit, 'stop) result)
  -> on_pass:(('slot, 'failure) passed -> unit)
  -> rests:('failure -> bool)
  -> 'slot list
  -> ('slot, 'value, 'failure, 'stop) walk_result
