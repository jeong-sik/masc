(** What an answer does to Memory, as a pure function
    (RFC librarian-call-only-proposes §8.2, step 1, and §8.3).

    A flaw in one op leaves out that op and nothing else.

    {b Screening.} Each op is checked in the answer's order. The first reason
    that holds is recorded and the op is left out. The list below is that
    order, so an op with two flaws is recorded under the earlier one:

    - {!Librarian_effects.Not_valid_alone}: the question showed no Memory and
      the op is not an [Add].
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

    - [Add]: adds the claim. A claim Memory already holds is only seen again:
      its [last_seen] moves and nothing else of it changes. Its basis is not
      raised. A claim that matches a held one byte for byte may be the
      question's own text read back, so it is not counted as new grounds.
    - [Drop]: removes the fact.
    - [Merge], [Revise]: remove the named facts and state the new claim as
      [Add] does. A named fact whose claim is the new claim is kept. The new
      fact keeps the earliest [first_seen] of the facts it replaced.
    - [Seen]: the named fact is seen again, as a held claim's [Add] is: its
      [last_seen] moves and nothing else of it changes. Its units are
      recorded as its sources. The answer names the fact instead of copying
      its claim, so no near copy of the fact is added.

    A fact removed by one op and stated by another leaves and is added as a
    new fact.

    {b Support.} After the ops, a derived fact whose premises are gone is
    removed as [Support_lost]. If that takes away the fact an op stated or
    saw again, the op is withdrawn as [Successor_unsupported]: the facts it
    removed stay.
    This repeats until nothing changes. A withdrawn op is not tried again, and
    the claim it carried is not added. *)

open Keeper_memory_os_types

(** What the question showed, in the short names it gave. *)
type shown =
  { memory : (string * string) list option
  (** Short name and Memory id of every fact shown. [None] for a question that
      showed one item and no Memory. *)
  ; units : (string * int) list
  (** Short name of every unit shown and the offset of its line in the turn
      log. *)
  }

(** What becomes of the Keeper's working state. *)
type working_state =
  | Kept
  | Replaced of string (** [Replaced ""] clears it. *)
  | Not_valid_alone
  (** The answer replaced it, but the question had not shown it. It is kept:
      an answer that did not see the working state cannot replace it. The
      attempt is its own case so the commit line can record it. *)

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
