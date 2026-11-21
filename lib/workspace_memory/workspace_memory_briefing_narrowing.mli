(** What the workspace memory curator asks next after a briefing walk, and
    the request the briefing waits at (RFC
    curator-narrows-a-refused-batch-and-sets-a-refused-fact-aside §4.5, §5).

    The briefing reads the entries of its pass in order. Each request is the
    first entries the pass has not read ({!Workspace_memory_briefing.prepare}),
    so the briefing waits at one request at most: one no slot answered, held
    with the slots that refused it. While it waits, the last complete
    briefing stays the one Keepers read (RFC §10 D4).

    This module decides only. It reads no store, ledger or lane, calls no
    provider and takes no lock. Nothing here ends a state because time
    passed. A held request a slot has not refused is asked again on the
    tick. One every slot refused is asked again in a new generation, or when
    the pass no longer starts with it (RFC §4.3). *)

type slot = string
(** The id the lane declares a slot by ({!Exact_lane_slots.id}). *)

(** What one slot said to one briefing request, as the curator reads the
    slot outcome table (RFC §4.1, §4.5). *)
type word =
  | Refused  (** Refused short of the output limit, with a size or without. *)
  | Output_limit
  (** Stopped at the output limit. A request of fewer entries is not known
      to give a shorter briefing, so this word does not narrow. *)
  | Unusable  (** A body came and the lane cannot use it. *)
  | Overdue  (** Sent, and a deadline on the request's own work passed. *)
  | Quiet  (** Said nothing about this request, or was not called. *)

type memory

val empty : Workspace_memory_narrowing.generation -> slots:slot list -> memory
(** Nothing held. [slots] are the lane's slots in walk order. *)

val restart : memory -> requests:int -> memory
(** An ask to start over: nothing held, in the generation of the same lane
    and slots with [requests]. A pass that started before it writes
    nothing. *)

(** What the briefing does with the batch it prepared. *)
type start =
  | Ask of
      { count : int
      ; slots : slot list
      }  (** Ask the first [count] entries of the batch, of [slots]. *)
  | Wait  (** The held request is asked on the tick. *)
  | Stand  (** Every slot refused the held request. *)

val start
  :  memory
  -> generation:Workspace_memory_narrowing.generation
  -> slots:slot list
  -> wake:Workspace_memory_narrowing.wake
  -> keys:Workspace_memory_briefing.key list
  -> memory * start
(** [keys] are the entries of the prepared batch, in order. A [generation]
    or [slots] unlike the memory's empties the memory first. A held request
    that is not the first entries of [keys] is let go: the pass read past it
    or was made again without it.

    With nothing held, every entry is asked of every slot. A held request
    stands when every slot refused it. Otherwise [Commit] waits, and [Tick]
    asks it of the slots that have not refused it. *)

(** What follows a walk no slot answered. *)
type unanswered =
  | Narrow
  (** Ask the older half, of every slot, in this pass. Nothing is held. *)
  | Waits
  (** The request is held, and the tick asks it of the slots that have not
      refused it. *)
  | Stands  (** The request is held, and every slot refused it. *)
  | Moved
  (** The memory moved to another generation since the pass started.
      Nothing is written, and the pass ends. *)

type error = No_entry  (** The request sent held no entry. *)

val error_to_string : error -> string

val unanswered
  :  memory
  -> generation:Workspace_memory_narrowing.generation
  -> sent:Workspace_memory_briefing.key list
  -> heard:(slot * word) list
  -> (memory * unanswered, error) result
(** No slot answered the request of [sent]. [heard] is what the walked
    slots said; a slot with no entry was not called.

    - Two entries or more, and a slot refused short of the output limit,
      sent a body the lane cannot use, or missed a deadline: [Narrow].
    - Otherwise the request is held. The slots that refused it, at the
      output limit or short of it, join those that refused the same request
      before. It [Stands] when every slot of the lane has refused it, and
      [Waits] otherwise. *)

val answered : memory -> generation:Workspace_memory_narrowing.generation -> memory
(** A slot answered: nothing is held. In another generation nothing is
    written. *)
