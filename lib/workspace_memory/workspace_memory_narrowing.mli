(** What the workspace memory curator asks next after a walk, which fact it
    sets aside, and what it remembers between passes (RFC
    curator-narrows-a-refused-batch-and-sets-a-refused-fact-aside §4.1 to
    §4.4, §5). The names follow the model
    [specs/bug-models/CuratorNarrow.tla]; each function below names the
    model action it carries out.

    This module decides only. It reads no store, ledger or lane, calls no
    provider, takes no lock and writes no log. The owner holds one {!memory}
    per workspace, runs one {!pass} at a time, prepares each request with
    {!Workspace_memory_request.prepare} and walks the slots {!next} names.

    Nothing here ends a state because time passed, and nothing holds an act
    back by a count. A fact waits for an event: the next tick pass, a new
    generation, or a change of the pending facts. *)

type fact = Workspace_memory_ledger.fact_ref

type slot = string
(** The id the lane declares a slot by ({!Exact_lane_slots.id}). *)

(** What the memory rests on. Calls of one generation fill it; a new
    generation starts it empty (model [Reset]). [lane] is the lane
    generation ([Runtime_exact_output_registry.catalog_generation_fingerprint]).
    [requests] counts the asks to start over that the owner took: a prompt
    change and an operator's request (RFC §4.3). *)
type generation =
  { lane : string
  ; requests : int
  }

(** Why the owner runs a pass (RFC §4.4). *)
type wake =
  | Commit
  (** A Keeper Memory commit, a lane change or a prompt change: only the new
      facts are asked. *)
  | Tick  (** The maintenance tick: the waiting facts are asked again too. *)

val combine_wake : wake -> wake -> wake
(** Two wakes before one pass: [Tick] wins, since a tick pass asks the new
    facts as well. *)

(** How a batch came down to its size (model [chain]). *)
type chain =
  | Fresh  (** No batch holding these facts was narrowed in this pass. *)
  | Sized_only
  (** Every narrowing above it had size refusals and silent slots only. *)
  | Other
  (** Some narrowing above it had a refusal with no size, an unusable answer
      or a missed deadline. *)

(** What one slot said to one request, as the curator reads the slot outcome
    table (RFC §4.1). *)
type word =
  | Sized  (** Refused, and said the request did not fit. *)
  | Unsized  (** Refused, and gave no size. *)
  | Unusable  (** A body came and the lane cannot use it. *)
  | Overdue  (** Sent, and a deadline on the request's own work passed. *)
  | Quiet  (** Said nothing about this request, or was not called. *)

(** The owner's memory: the narrowed places, the bottom memory (which slot
    refused which fact alone), the waiting facts of fresh batches that met
    only silent slots, and the kept size. *)
type memory

val empty : generation -> slots:slot list -> memory
(** Nothing remembered. [slots] are the lane's slots in walk order. *)

val restart : memory -> requests:int -> memory
(** An ask to start over (model [Reset]): nothing remembered, in the
    generation of the same lane and slots with [requests]. A pass that
    started before it writes nothing, and {!next} ends it. *)

val size : memory -> Workspace_memory_request.size
(** The kept size (model [size]): [Up_to n] after a batch of [n] facts was
    answered that came down by size refusals only, [Fill_frame] otherwise. *)

val set_aside : memory -> fact list
(** The facts every slot of the lane refused alone (model [SetAside]). They
    are not asked again in this generation unless they leave the pending
    facts and come back. *)

val waiting : memory -> bool
(** Whether a tick pass has something to ask (model [Waiting]): a waiting
    fact, or a place that is not set aside. *)

(** One pass's work list. *)
type pass

val start
  :  memory
  -> generation:generation
  -> slots:slot list
  -> wake:wake
  -> pending:fact list
  -> memory * pass
(** Model [StartPass]. [pending] is the facts the ledger holds no disposition
    for, oldest first (the [new_facts] of
    {!Workspace_memory_ledger.reconcile}).
    A [generation] or [slots] unlike the memory's empties the memory first.
    The memory keeps only the pending facts: a fact that left them is
    forgotten, and asked as a new fact if it comes back (RFC §4.3).

    [Commit]: one batch of the facts that are in no place and do not wait.
    [Tick]: one batch of those facts and the waiting ones together, then each
    place that is not set aside as it is, oldest first. The waiting facts are
    taken out of the memory. *)

(** The next request of a pass. [facts] in pending order; prepare at most
    [size] of them. [slots] are the slots to walk: for one fact, those that
    have not refused it. *)
type request =
  { facts : fact list
  ; size : Workspace_memory_request.size
  ; slots : slot list
  }

val next : memory -> pass -> request option
(** [None] when the pass is over: its list is empty, or the memory moved to
    another generation since the pass started. A batch kept as it is asks
    for all its facts; any other asks for the kept size (model [Cut] and
    [CanAsk]). *)

type error =
  | No_item  (** The pass has no request out. *)
  | Not_a_prefix_of_the_request
  (** The facts sent are empty or not the first facts of {!next}'s
      request. *)

val error_to_string : error -> string

val answered : memory -> pass -> sent:fact list -> (memory * pass, error) result
(** Model [Commit]. A slot answered the batch of [sent], and the ledger took
    the answer. [sent] is the first facts of the request {!next} gave: the
    frame or the kept size may have held fewer. The facts not sent stay next
    in the list. The answered facts leave the memory. When the batch came down
    by size refusals only, its size is kept.

    A pass whose generation is not the memory's writes nothing and ends. *)

val unanswered
  :  memory
  -> pass
  -> sent:fact list
  -> heard:(slot * word) list
  -> (memory * pass, error) result
(** No slot answered the batch of [sent]. [heard] is what the walked slots
    said. A slot of the request with no entry was not called: [Quiet].

    - Two facts or more, and a slot had a word (model [Narrow]): the older
      half is asked next as it is, then the newer half is made again on its
      own. Neither half takes in facts that come after it in the list.
    - Two facts or more, and every slot was quiet (model [AllQuiet]): a fresh
      batch leaves its facts waiting for the tick; a narrowed one is kept as
      a place and asked as it is on the tick.
    - One fact (model [Bottom]): the slots that refused it are remembered and
      the fact stays a place; it is set aside when every slot refused it. A
      fresh fact that met only quiet slots waits for the tick instead.

    A pass whose generation is not the memory's writes nothing and ends. *)
