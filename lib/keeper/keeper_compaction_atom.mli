(** Names for the atoms of a conversation, and the part of a conversation a
    compaction anchor covers.

    An atom is the unit {!Runtime_model_input_tail_window.annotate} cuts on: a
    [User] or [Assistant] message together with the [Tool] results that answer
    it. Its name is the Keeper turn it belongs to and its place inside that
    turn, read from {!Keeper_turn_ref_metadata} on the message that opens it.

    Each compaction producer names the atoms of its own list: the Agent Core
    history, an official client's start seed, the ACP list rebuilt from the
    canonical turn store. The per-turn consumer names the checkpoint history
    the same way. A name one of them writes is looked up in another list by
    equality, so finding an anchor's boundary reads metadata only; nothing is
    serialized or hashed. See RFC compaction-anchor-names-a-turn-atom. *)

type name =
  | Leading of int
      (** An atom before the first atom that names a turn: history written
          before turn ids were stamped. Counted from the front of the list. *)
  | In_turn of
      { turn : Ids.Turn_id.t
      ; ordinal : int
      }
      (** The [ordinal]-th atom (from 0) of [turn] in this list. An atom whose
          opening message names no turn belongs to the turn of the atom before
          it. Ordinals count per turn across the whole list, so a turn that
          shows up again later continues its count and no two atoms of one
          list share a name. *)

val equal_name : name -> name -> bool
val name_to_string : name -> string
val name_to_json : name -> Yojson.Safe.t
val name_of_json : Yojson.Safe.t -> (name, string) result

(** How much of the boundary turn an anchor covers. *)
type extent =
  | Whole_turn
      (** Every atom of the turn. Written only when the atom after the
          boundary belongs to another turn and every earlier turn is
          covered too. *)
  | Up_to of
      { ordinal : int
      ; settled : Ids.Turn_id.t option
      }
      (** The turn's atoms through [ordinal]; the turn may continue past it.
          [settled] is the last turn every atom of which is covered, the turn
          the canonical turn store may prune through. *)

(** The front of a list an anchor covers without a gap. *)
type through =
  | Through_leading of int  (** Leading atoms [0..k]. *)
  | Through_turn of
      { turn : Ids.Turn_id.t
      ; extent : extent
      }
      (** Everything before [turn]'s first atom, and [turn] as far as
          [extent] says. *)

type coverage =
  { through : through option
  ; beyond : name list
      (** Atoms past [through] that are already archived: completed tool
          rounds the Agent Core window dropped from the middle of a turn. *)
  }

val settled_turn : coverage -> Ids.Turn_id.t option
(** The last turn every atom of which is covered: the boundary turn under
    {!Whole_turn}, [settled] under {!Up_to}, none before any turn. *)

val coverage_to_string : coverage -> string
(** Short display form for logs, the anchor text and the dashboard. *)

val coverage_to_json : coverage -> Yojson.Safe.t
val coverage_of_json : Yojson.Safe.t -> (coverage, string) result

type atom =
  { name : name
  ; messages : Agent_core.Types.message list
  ; last_position : int  (** Index in the input list of the atom's last message. *)
  }

val atoms_of_messages : Agent_core.Types.message list -> atom array
(** Name every atom of the list, in order. Pinned messages belong to no atom. *)

val covered_end : through option -> atom array -> int
(** Index of the last atom [through] covers in [atoms], or [-1] when it covers
    none of them.

    - {!Through_leading} [k] covers the leading atoms through [k].
    - {!Through_turn} covers nothing when no atom names its turn. Otherwise it
      covers every atom before the turn's first atom, then under {!Whole_turn}
      the turn's first run of atoms, and under {!Up_to} the turn's atoms
      through the one with the largest ordinal not above [ordinal].

    A boundary that is missing from the list covers nothing rather than a
    guessed span, so a list that does not hold the boundary is never cut
    past what the anchor summarized. *)

(** Atoms a producer dropped from its list: every atom before [prefix], and
    [later] atoms at or past [prefix]. *)
type eviction =
  { prefix : int
  ; later : int list
  }

type advance =
  { coverage : coverage
  ; fresh : int list  (** Evicted atoms the previous coverage did not hold, ascending. *)
  }

val advance
  :  previous:coverage option
  -> atom array
  -> eviction
  -> (advance option, string) result
(** Extend [previous] by [eviction] over [atoms]. [Ok None] when every evicted
    atom is already covered. [Error] when an index lies outside [atoms] or a
    [later] index lies before [prefix].

    The new boundary is the later of [previous]'s covered end in [atoms] and
    the end of the evicted prefix; when the prefix ends no later, [previous]'s
    boundary is kept as written. [beyond] keeps the [later] atoms and
    [previous]'s still-present [beyond] atoms that lie past the new boundary. *)
