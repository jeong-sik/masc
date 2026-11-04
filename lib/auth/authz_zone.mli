(* HIGH-RISK-UNREVIEWED: this module appends to the authorization log while masc
   runs. A record that it appends without the intent it needs, or a state that
   it publishes and the log does not hold, lets an event reach the log that the
   high-water mark does not guard against a rollback. *)

(** The writer zone of the authorization log (design 8.1, 8.2, plan B3b).

    One zone covers both files: the zone of the external store, and inside it
    the zone of the log, the order of {!Authz_bootstrap}. A {!commit} does this
    in it, in order:
    + It judges what an earlier entry left (design 8.2-1). The judgment is
      {!Authz_high_water.judge} and {!Authz_high_water.settle}, the ones a
      start makes, and it runs on every entry, because an append that failed
      leaves the process running. A [Promote] or an [Abort] writes its entry
      to the store. A [Mismatch] writes nothing and refuses the commit
      ({!Uncertain}). Nothing in the zone changes that value, so every later
      commit is refused as well, until a restart reads the files again.
    + It builds the record at the head of the log and runs
      {!Authz_state.apply} on it. A record that it refuses is not written.
    + For a record with a high-water change: [Intent_pending] in the store, the
      append to the log, [Committed] in the store. For a record without one:
      the append.
    + It publishes the state with the record.

    {b Snapshot.} The state and the head it belongs to are one immutable value
    in an [Atomic.t], so a reader takes it without a lock. Once the append
    returns, the state with the record is published even if the [Committed]
    after it fails: the record is in the log, and the next {!Authz_state.apply}
    has to run on a state that holds it. The caller gets
    {!Answer_not_written}, and the next entry promotes the intent.

    {b Probe.} The zone keeps the probe of the high-water mark in step with
    both files without reading the log again: it feeds
    {!Authz_high_water.Probe.add} each record it appends, and
    {!Authz_high_water.Probe.store_moved} each entry it writes to the store,
    before the entry is written. The probe follows only what goes through the
    zone, so after {!create} the log and the store are written through the
    zone and nothing else. A head of the log that is not the published one is
    refused ({!Log_moved}).

    {b One record.} A commit appends one record. A list of records can land in
    part ({!Authz_log.append}), and which record the intent of a list names is
    for the layer that first needs one.

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

(** The zone over a log and a store that were opened with {!Replay}: [replay]
    is what the log folded to from {!Replay.init} of the state the store was
    opened with. *)
val create : log:Authz_log.t -> store:Authz_external_store.t -> Replay.t -> t

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

type error =
  | Store_stopped of Authz_external_store.stop
  | Log_stopped of Authz_log.stop
  | Log_moved of
      { published : Authz_record.Hash.t
      ; found : Authz_record.Hash.t
      }  (** The log has a record that did not go through the zone. *)
  | Uncertain of
      { first : Authz_high_water.reason
      ; rest : Authz_high_water.reason list
      }  (** The store and the log do not agree (design 8.2, items 2 to 5). *)
  | Store_entry_refused of
      { entry : Authz_external_store.entry
      ; violation : Authz_external_store.violation
      }  (** The probe refused the entry, so it was not written. *)
  | Settlement_not_written of Authz_external_store.append_error
  | Record_not_built of Authz_record.make_error
  | Refused of Authz_state.refusal
  | Intent_not_written of Authz_external_store.append_error
  | Record_not_appended of Authz_log.append_error
  | Answer_not_written of
      { record_hash : Authz_record.Hash.t
      ; error : Authz_external_store.append_error
      }  (** The record is in the log and in the snapshot, and its [Committed] is not. *)

val error_to_string : error -> string

(** Appends one record, as the module text says. *)
val commit : t -> draft -> (committed, error) result
