(** What an answer does to Memory, as a pure function
    (RFC librarian-call-only-proposes §8.2, step 1, and §8.3).

    A flaw in one op leaves out that op and nothing else.

    {b Screening.} Each op is checked in the answer's order. The first reason
    that holds is recorded and the op is left out. The list below is that
    order, so an op with two flaws is recorded under the earlier one:

    - {!Librarian_effects.Not_valid_alone}: the question showed one item and
      no Memory, and the op is not an [Add].
    - {!Librarian_effects.Not_valid_in_room}: the question showed Memory and
      no unit, and the op is an [Add] or a [Seen]: both need a unit.
    - [Unknown_ref]: a fact name the question did not give.
    - [Removed_during_flight]: a fact the op names, or the claim it states, was
      removed by a direct write after the question was made. An answer cannot
      bring back what was retracted while it was being written.
    - [Unknown_ref]: a named fact that is not in Memory and was not removed
      during the flight.
    - [Ref_used_twice]: an earlier op that passed screening named the fact.
    - [Source_outside_question]: a unit name the question did not give.

    A [Seen] names one fact and at least one unit, so it is screened as the
    ops that name a fact are, its units as a stated claim's are.

    {b What a screened op does.}

    - [Add]: adds the claim. A claim Memory already holds is only seen again,
      and only when the op names a unit: its [last_seen] moves and nothing
      else of it changes. Its basis is not raised. A claim that matches a
      held one byte for byte may be the question's own text read back, so it
      is not counted as new grounds. Written again without a unit, it changes
      nothing.
    - [Drop]: removes the fact.
    - [Merge], [Revise]: remove the named facts and state the new claim as
      [Add] does. A named fact whose claim is the new claim is kept. The new
      fact keeps the earliest [first_seen] of the facts it replaced. Its
      [last_seen] is the commit time when the op names a unit, and otherwise
      the latest [last_seen] of the facts it replaced: saying again what
      Memory held is no newer evidence.
    - [Seen]: the named fact is seen again, as a held claim's [Add] with a
      unit is: its [last_seen] moves and nothing else of it changes. Its
      units are recorded as its sources. The answer names the fact instead of
      copying its claim, so no near copy of the fact is added.

    So [last_seen] moves only on evidence: an op that names a unit.

    A fact removed by one op and stated by another leaves and is added as a
    new fact.

    {b Support.} After the ops, a derived fact whose premises are gone is
    removed as [Support_lost]. If that takes away the fact an op stated or
    saw again, the op is withdrawn as [Successor_unsupported]: the facts it
    removed stay.
    This repeats until nothing changes. A withdrawn op is not tried again, and
    the claim it carried is not added. *)

open Keeper_memory_os_types

(** What a reading question showed, in the short names it gave. [memory] is
    the short name and Memory id of every fact shown; [units] the short name
    of every unit shown and the offset of its line in the turn log. *)
type read =
  | Range of
      { memory : (string * string) list
      ; units : (string * int) list
      } (** [Read_range]: Memory, the working state and units. *)
  | Item_alone of { units : (string * int) list }
  (** [Read_item_alone]: the head item, with no Memory and no working
      state. *)

(** What a question showed, one constructor for each kind of question (RFC
    §6.1). *)
type shown =
  | Read of read
  | Room of { memory : (string * string) list }
  (** [Make_room]: Memory and the working state, with no unit. *)

(** What becomes of the Keeper's working state. *)
type working_state =
  | Kept (** The question showed it ([Range], [Room]), and the answer kept it. *)
  | Replaced of string
  (** The question showed it, and the answer replaced it. [Replaced ""]
      clears it. *)
  | Alone of Librarian_log.alone_working_state
  (** The question showed one item and not the working state, so it is
      kept: an answer that did not see it cannot replace it. Which of the
      two the answer did is what the commit line records. *)

type t =
  { facts : fact list (** [Librarian_effects.apply ~at] of [effects]. *)
  ; effects : Librarian_effects.t
  ; working_state : working_state
  }

(** [facts] is Memory now, which may differ from what the question showed.
    [removed_since] names every fact removed since the question was made, with
    the number of the commit that removed it. A fact that was written again
    after it was removed stays listed: an op that names it, or states its
    claim, is left out. New facts are last seen at [at] and carry [trace_id]
    as their origin. A new fact that replaces facts by a merge or a revision
    is first seen when the earliest of them was, and never after [at]:
    folding what Memory knew into fewer facts does not make it younger. Any
    other new fact is first seen at [at]. *)
val of_answer
  :  shown:shown
  -> facts:fact list
  -> removed_since:(string * int) list
  -> at:float
  -> trace_id:string
  -> Librarian_answer.t
  -> t
