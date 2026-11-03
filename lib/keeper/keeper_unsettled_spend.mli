(** Spend a cancelled execution left out of its turn.

    A turn's spend stays in memory until the turn commits, and the commit is
    what writes the turn's resolved cost rows. A cancelled execution -- a
    server stopping, a Keeper stopped mid-turn -- ends before it commits, so
    the raw rows its requests wrote stay in the cost ledger with no resolved
    rows beside them. The Keeper's next execution starts from an empty spend,
    under the same turn id or a later one.

    A Keeper runs one execution at a time, so before an execution starts,
    every raw row the Keeper wrote after its newest resolved row belongs to an
    execution that ended without committing: a commit writes a resolved row
    for every reading its attempts read, after the raw rows they came from.
    A row lands in the day file of the moment it is appended, so the Keeper's
    rows are in the day files from the day it was created on. Older day files
    hold other Keepers' rows only and are not opened.
    Each raw row carries the {!Keeper_spend_observation} its execution handed
    {!Keeper_turn_spend}. Those observations are handed to it again, attempt
    by attempt and in the order they were written, resolved, and written as
    attempt readings of their own turn. A row without one is not settled.

    A conversation-cumulative report is not settled: it is read against the
    Keeper's committed cursor, so the next count of the same conversation
    already covers it, and settling it here as well would count it twice.

    An execution whose commit holds and writes every resolved row leaves no
    raw row of its Keeper that is not settled, so the Keeper's next execution
    in the same process has nothing to read the ledger for.
    {!settle_before_execution} hands an execution a {!settled_start} when it
    starts from a settled ledger, and the commit hands it back through
    {!record_committed} once every row it wrote is in the file. The next
    execution then starts without reading the ledger. An execution that ends
    any other way -- cancelled, raised, its commit rejected, a row not in the
    file -- hands nothing back, and the next one reads the ledger as before.
    So does the first execution of every Keeper in a process: nothing of this
    is stored. *)

type outcome =
  { scanned_rows : int
        (** Ledger rows read, newest first, down to the newest resolved row. *)
  ; settled_turns : int
  ; settled_readings : int
  ; unplaced_rows : int
        (** Raw rows after the newest resolved row that name no attempt or
            carry no observation to settle. *)
  ; undecodable : string list
        (** Why each raw row after the newest resolved row that does not
            decode -- as a cost row or as its observation -- was not settled,
            oldest first. *)
  ; unwritten_turns : int
        (** Settled turns with a resolved row that is not in the file. *)
  }

(** The Keeper's raw rows after its newest resolved row, oldest first, from
    rows given newest first. *)
val unsettled_rows : agent_name:string -> Yojson.Safe.t list -> Yojson.Safe.t list

(** Observe [rows] (oldest first) again and write their resolved readings.
    Writes nothing when no row can be observed. *)
val settle_rows
  :  masc_root:string
  -> agent_name:string
  -> observed_at:float
  -> Yojson.Safe.t list
  -> outcome

(** Read the day files from [born_at]'s day to [observed_at]'s day newest
    first, down to the Keeper's newest resolved row, and settle what lies above
    it. [born_at] is when the Keeper was created. *)
val settle
  :  masc_root:string
  -> agent_name:string
  -> born_at:float
  -> observed_at:float
  -> (outcome, Dated_jsonl.read_error) result

(** An execution that started with nothing of its Keeper left to settle in
    the ledger. Only {!settle_before_execution} makes one. *)
type settled_start

(** Before an execution starts. When the Keeper's previous execution in this
    process handed its {!settled_start} back, nothing is read. Otherwise
    {!settle} runs from the Keeper's [created_at] (ISO 8601), and the result is
    [Some] when it read the ledger and every row it settled is in the file.

    Failures are logged and the execution goes on with [None]: what could not
    be settled stays in the ledger as raw rows, and the next execution reads
    the ledger again. Rows that do not decode or name no attempt cannot be
    settled by reading again, so they do not withhold the result; they are
    logged, the undecodable ones with the oldest one's reason. *)
val settle_before_execution
  :  masc_root:string
  -> agent_name:string
  -> created_at:string
  -> settled_start option

(** The execution that [settled_start] started committed its spend and every
    resolved row it wrote is in the file, so its Keeper's next execution in
    this process starts without reading the ledger. *)
val record_committed : settled_start -> unit
