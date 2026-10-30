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
    Each raw row carries the {!Keeper_spend_observation} its execution handed
    {!Keeper_turn_spend}. Those observations are handed to it again, attempt
    by attempt and in the order they were written, resolved, and written as
    attempt readings of their own turn. A row without one is not settled.

    A conversation-cumulative report is not settled: it is read against the
    Keeper's committed cursor, so the next count of the same conversation
    already covers it, and settling it here as well would count it twice. *)

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

(** Read the ledger newest first down to the Keeper's newest resolved row and
    settle what lies above it. *)
val settle
  :  masc_root:string
  -> agent_name:string
  -> observed_at:float
  -> (outcome, Dated_jsonl.read_error) result

(** {!settle} before an execution starts. Failures are logged and the
    execution goes on: what could not be settled stays in the ledger as raw
    rows and is settled before a later execution. Rows that do not decode
    are logged as a warning with the oldest one's reason. *)
val settle_before_execution : masc_root:string -> agent_name:string -> unit
