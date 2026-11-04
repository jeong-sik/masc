(* HIGH-RISK-UNREVIEWED: this module appends to the authorization log while masc
   runs. A record that it appends without the intent it needs, or a state that
   it publishes and the log does not hold, lets an event reach the log that the
   high-water mark does not guard against a rollback. *)

(** The writer zone of the authorization log (design 8.1, 8.2, plan B3b).

    {!open_at_start} opens both files and keeps their handles, so in this
    process every write to them goes through the zone. One zone covers both
    files: the zone of the external store, and inside it the zone of the log,
    the order of {!Authz_bootstrap}. A {!commit} does this in it, in order:
    + It judges what an earlier entry left with
      {!Authz_high_water.settle_on_entry}, the judgments a start makes. It does
      this on every entry, because an append that failed leaves the process
      running (design 8.2, item 1). A mismatch refuses the commit
      ({!Uncertain}). Nothing in the zone changes that, so every later commit is
      refused as well, until a restart reads the files again.
    + It builds the record at the head of the log and runs
      {!Authz_state.apply} on it.
    + It writes the settlement of the first step: [Committed] for a promoted
      intent, [Aborted_intent] for an aborted one.
    + It writes [Intent_pending] to the store, appends the record to the log,
      publishes the state with the record, and writes [Committed].

    Each step writes only when the steps before it passed, so a commit that is
    refused in the first two steps writes nothing, and the settlement waits for
    a commit that writes an intent after it.

    {b Snapshot.} The state and the head it belongs to are one immutable value
    in an [Atomic.t], so a reader takes it without a lock. Once the append
    returns, the state with the record is published even if the [Committed]
    after it fails: the record is in the log, and the next {!Authz_state.apply}
    has to run on a state that holds it. The caller gets {!Answer_not_written}.
    The next commit promotes the intent, or, if the failure stopped the store,
    the next start does. A commit that fails in any other way leaves the
    snapshot as it was. The snapshot does not say that a file stopped.

    {b Probe.} The zone keeps the probe of the high-water mark in step with
    both files without reading the log again: it feeds
    {!Authz_high_water.Probe.add} each record it appends, and
    {!Authz_high_water.Probe.store_moved} each entry it writes to the store,
    before the entry is written. This holds because nothing else in the process
    writes through the handles of the zone. A write through another handle, or
    by another process, moves the end of the file, and the next write of the
    zone to that file fails with [Diverged] and stops it.

    {b One record.} A commit appends one record. A list of records can land in
    part ({!Authz_log.append}), and which record the intent of a list names is
    for the layer that first needs one.

    {b Failed writes.} Of the append errors of either file, [Write_failed] may
    have written the lines, and every other one wrote nothing. [Write_failed]
    and [Diverged] stop the file, and later commits are refused with
    {!Store_stopped} or {!Log_stopped}. A write that raises stops its file as
    well, and the exception reaches the caller of {!commit}
    ({!Authz_log.append}). The next start reads what a stopped file holds. If
    the [Committed] raised, the snapshot already holds the record.

    Every call runs in an Eio fiber. *)

(** What the replay of the log adds up to for the zone. *)
module Replay : sig
  type t = private
    { state : Authz_state.t
    ; probe : Authz_high_water.Probe.t
    ; head : Authz_record.head
    }

  (** Over an empty log, for a store in the given state. *)
  val init : Authz_external_store.State.t -> t

  (** The fold function for {!Authz_log.open_at_start}. *)
  val step : t -> Authz_record.t -> (t, Authz_state.refusal) result
end

type snapshot =
  { state : Authz_state.t
  ; head : Authz_record.head
  }

type t

type open_error =
  | Store_not_opened of Authz_external_store.violation Authz_external_store.open_error
  | Log_not_opened of Authz_state.refusal Authz_log.open_error
  | Not_bootstrapped of { path : string }
      (** The log holds no [Fresh_bootstrap]. {!Authz_bootstrap} writes the
          first record of a log and the zone does not, so the zone never
          creates a store that no install record names (design 8.4). *)

val open_error_to_string : open_error -> string

(** Opens the external store at [store_path], then the log at [log_path],
    folded with {!Replay} from the state of the store. *)
val open_at_start : log_path:string -> store_path:string -> (t, open_error) result

val snapshot : t -> snapshot

(** The record to append. Its seq and previous hash come from the head. *)
type draft =
  { at_ms : int
  ; author : Authz_records.Author.t
  ; kind : Authz_record.Kind.t
  ; body : Authz_body.t
  }

type committed =
  { snapshot : snapshot  (** The state with the record. *)
  ; record_hash : Authz_record.Hash.t
  ; settled : Authz_high_water.settlement  (** What the zone closed before the record. *)
  }

(** Why a commit failed, and what it left in the files. *)
type error =
  | Store_stopped of Authz_external_store.stop  (** Nothing was written. *)
  | Log_stopped of Authz_log.stop  (** Nothing was written. *)
  | Uncertain of
      { first : Authz_high_water.reason
      ; rest : Authz_high_water.reason list
      }
      (** The store and the log do not agree (design 8.2, items 2 to 5). Nothing
          was written. *)
  | Record_not_built of Authz_record.make_error  (** Nothing was written. *)
  | Refused of Authz_state.refusal  (** Nothing was written. *)
  | Store_entry_refused of
      { entry : Authz_external_store.entry
      ; violation : Authz_external_store.violation
      }
      (** The probe refused the entry, so it was not written. A settlement
          before it is in the store. *)
  | Settlement_not_written of Authz_external_store.append_error
      (** The commit stopped at the settlement, and nothing of the record was
          written. *)
  | Intent_not_written of Authz_external_store.append_error
      (** The commit stopped at the intent. A settlement before it is in the
          store, and nothing of the record is in the log. *)
  | Record_not_appended of Authz_log.append_error
      (** The intent is in the store. When the error stopped the log, the next
          start reads whether the record is in it. Otherwise it is not, and the
          next commit aborts the intent. *)
  | Answer_not_written of
      { record_hash : Authz_record.Hash.t
      ; error : Authz_external_store.append_error
      }
      (** The commit stopped at the [Committed]. The record is in the log and in
          the snapshot. *)

val error_to_string : error -> string

(** Appends one record, as the module text says. *)
val commit : t -> draft -> (committed, error) result
