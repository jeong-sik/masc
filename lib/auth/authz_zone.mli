(* HIGH-RISK-UNREVIEWED: this module appends to the authorization log while masc
   runs. A record that it appends without the intent it needs, or a state that
   it publishes and the log does not hold, lets an event reach the log that the
   high-water mark does not guard against a rollback. *)

(** The writer zone of the authorization log (design 8.1, 8.2, plan B3b).

    {!open_at_start} opens both files and keeps their handles to itself, so
    nothing else writes through them. One zone covers both files: the zone of
    the external store, and inside it the zone of the log. A {!commit} does
    this in it, in order:
    + It judges what an earlier entry left with
      {!Authz_high_water.settle_on_entry}, the judgments a start makes. It does
      this on every entry, because an append that failed leaves the process
      running (design 8.2, item 1). A mismatch refuses the commit
      ({!Uncertain}), and so does a store that holds no answer
      ({!Store_holds_no_answer}). Nothing in the zone changes either, so every
      later commit is refused as well, until a restart reads the files again.
    + It reads the clock it was given, builds the record at the head of the
      log with that time, and runs {!Authz_state.apply} on it. The clock is
      read here, inside both locks, so a caller that waited for the lock cannot
      bring a time from before it, and no other commit appends between the read
      and the append. An admission is judged against the expiry of its
      invitation with that time, and {!Authz_state} refuses one before a record
      it has read ({!Authz_state.Admission_behind_log}). A reduction whose
      change the state holds a block of is a retry (design 8.3): the record is
      built again with those blocks in its [closes] ({!Authz_state.closable},
      {!Authz_record.closing}) and read again, so the intent and the hash cover
      them and a replay closes the same blocks. The caller does not fill
      [closes].
    + It writes the settlement of the first step: [Committed] for a promoted
      intent, [Aborted_intent] for an aborted one. Before an abort it asks
      {!Authz_log.confirm_end} whether the log still ends where the intent
      began.
    + It writes [Intent_pending] to the store, appends the record to the log,
      publishes the state with the record, and writes [Committed]. A record
      whose {!Authz_state.applied} has no change, the issue of an invitation
      for one or a cancel of a block, has no intent and no [Committed]: it is
      appended and published.
      Its settlement is still written before the append, because the append
      moves the head and an intent left behind it could no longer be aborted.
      A reduction that the settlement gives up blocks its subject in the state
      that reads the record ({!Authz_state.hold_revocations}, design 8.3). The
      block is published once the end of the log is confirmed, before the abort
      is written, because a write that fails may still have written the line.
      A commit that fails after that point leaves the block in place. A replay starts each block after the
      record its intent began at, as the writer did, and a block whose record
      the log no longer holds starts once the log is read. A replay closes a
      block at the record that names it, a retry or a cancel, so a log cut
      back to before that record holds the block again.

    Each step writes only when the steps before it passed, so a commit that is
    refused in the first two steps writes nothing, and the settlement waits for
    a commit that gets past them.

    {b Snapshot.} The state and the head it belongs to are one immutable value
    in an [Atomic.t], so a reader takes it without a lock. Once the append
    returns, the state with the record is published even if the [Committed]
    after it fails: the record is in the log, and the next {!Authz_state.apply}
    has to run on a state that holds it. The caller gets {!Answer_not_written}.
    The next commit promotes the intent, or, if the failure stopped the store,
    the next start does. A commit that gives up a reduction and fails after
    the end of the log was confirmed leaves the snapshot with the block of that
    reduction and nothing else of the commit. A commit that fails in any other
    way leaves the snapshot as it was. The snapshot does not say that a file
    stopped; {!read} does.

    {b Probe.} The zone keeps the probe of the high-water mark in step with
    both files without reading the log again: it feeds
    {!Authz_high_water.Probe.add} each record it appends, and
    {!Authz_high_water.Probe.store_moved} each entry it writes to the store,
    before the entry is written. This holds because nothing else writes through
    the handles of the zone. A write through another handle, or by another
    process, moves the end of the file, and the next write of the zone to that
    file fails with [Diverged] and stops it. A write that leaves the file on the
    same inode at the same size is not noticed ({!Authz_jsonl_file.Make}).

    An abort is the one settlement that no later judgment checks again. A
    [Committed] names a record that each later judgment looks for in the log
    ({!Authz_high_water.Commit_not_in_log}). An [Aborted_intent] says that the
    record of the intent is not in the log, and nothing reads that again. The
    append that the intent was for did not happen, and another process may
    have held the log then, so before an abort the zone asks the file with
    {!Authz_log.confirm_end}. The answer holds only while that read holds the
    lock. A record that another process appends after it is found by the next
    append of the zone, as [Diverged]. When no append follows, because the
    process ends or the intent is not written, the next start finds the files
    in agreement, and that record has no intent in the store.

    {b One record.} A commit appends one record. A list of records can land in
    part ({!Authz_log.append}), and which record the intent of a list names is
    for the layer that first needs one.

    {b Failed writes.} Of the append errors of either file, [Write_failed] may
    have written the lines, and every other one wrote nothing. [Write_failed]
    and [Diverged] stop the file, and later commits are refused with
    {!Store_stopped} or {!Log_stopped}. A write that raises stops its file as
    well, and the exception reaches the caller of {!commit}
    ({!Authz_log.append}). The next start reads what a stopped file holds. If
    the [Committed] raised, the snapshot already holds the record. The read of
    {!Authz_log.confirm_end} can raise too. It wrote nothing, so the log is not
    stopped, and the exception reaches the caller of {!commit}.

    {b Install.} {!install} writes the first record of a log, the
    [Fresh_bootstrap] of {!Authz_bootstrap}, with the steps of {!commit}. It
    enters a zone over handles that the caller opened, for that one call, and
    wants the store to hold no answer where {!commit} wants one.

    Every call runs in an Eio fiber. *)

(** What the replay of the log adds up to for the zone. *)
module Replay : sig
  type t = private
    { state : Authz_state.t
    ; probe : Authz_high_water.Probe.t
    ; head : Authz_record.head
    ; unreached : (Authz_record.Hash.t * Authz_state.held) list
          (** The blocks of given-up reductions, each with the head its intent
              began at, that the replay has not reached yet. *)
    }

  (** Over an empty log, for a store in the given state. *)
  val init : Authz_external_store.State.t -> t

  (** The fold function for {!Authz_log.open_at_start}. A block that the
      replay has not reached starts before a record that closes or cancels it
      ({!Authz_state.closed_by}): the writer that wrote that record held the
      block from its start. *)
  val step : t -> Authz_record.t -> (t, Authz_state.refusal) result

  (** The replay once the log is read: the blocks it has not reached start
      too, and so does the block of a reduction whose intent is still pending
      and that the next entry gives up (design 8.2-3), as the writer held it
      when its append failed. A start reads the state of this. *)
  val finish : t -> t
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
      (** The log is not there, or holds no [Fresh_bootstrap]. The first record
          of a log is written by {!install}, which {!Authz_bootstrap} calls once
          the install record names the store, so a zone opened here never
          writes to a store that no install record names (design 8.4). A log
          that is not there is refused before either file is opened, so the
          refusal leaves nothing on disk. *)
  | Log_not_checked of
      { path : string
      ; detail : string
      }
      (** {!Authz_presence} cannot tell whether the log is there. Neither file
          was opened. *)
  | Store_not_there of { path : string }
      (** The log is there and the external store is not: a store on a volume
          that is not mounted, or a file that was removed. Neither file was
          opened, so nothing is made where the store was, not its directory
          and not its lock file. *)
  | Store_not_checked of
      { path : string
      ; detail : string
      }
      (** {!Authz_presence} cannot tell whether the store is there. Neither
          file was opened. *)

val open_error_to_string : open_error -> string

(** Asks {!Authz_presence} whether the log at [log_path] and the external
    store at [store_path] are there. If both are, opens the store, then the
    log, folded with {!Replay} from the state of the store. Opening a file
    makes its directory and its lock file, so a file that is not there is
    refused before either is opened. A store that goes away between the
    question and the open is opened as an empty one, with its directory and
    its lock file made. [now_ms] is the wall clock in
    milliseconds. A {!commit} that
    gets past the judgment of the entry reads it once, for the time of its
    record. *)
val open_at_start
  :  now_ms:(unit -> int)
  -> log_path:string
  -> store_path:string
  -> (t, open_error) result

(** What the zone last published, whatever the files say: the view of the
    writer. A caller that goes on to {!commit} may read it for a check that
    the commit makes again, because the commit judges the entry. A decision
    that allows something without a commit reads {!read}. *)
val snapshot : t -> snapshot

(** Why a decision cannot rest on the zone now ([AuthorizationUncertain],
    plan B2). In each case no commit runs until a restart reads the files
    again, so the zone can neither add nor close a block, and a session, a
    token or a membership that was to be ended stays in the published state. *)
type uncertain =
  | Log_is_stopped of Authz_log.stop
      (** The log is stopped: its head is not trusted. *)
  | Store_is_stopped of Authz_external_store.stop
  | Files_disagree of
      { first : Authz_high_water.reason
      ; rest : Authz_high_water.reason list
      }
      (** The store and the log disagree ({!Authz_high_water.Mismatch}): the
          log went back, or was replaced (design 8.2-4 and 8.2-5). *)
  | Store_answers_nothing
      (** The store holds no answer for a bootstrapped log: it was emptied, or
          is not the store of this log. *)

(** Which of the four it is, without the path of a file and without what a
    file error said. A caller whose text reaches a person gives this. *)
val uncertain_to_string : uncertain -> string

(** The reason in full, with the paths of the files: for the operator of the
    host, in a boot refusal, in the answer of a command, or in the log. *)
val uncertain_detail : uncertain -> string

(** A snapshot that {!read} took while the zone could be trusted. Only {!read}
    makes one, so a function that takes one cannot be handed the state of a
    zone whose files stopped or disagree. It is read as a snapshot:
    [(trusted :> snapshot).state]. *)
type trusted = private snapshot

(** The published state, for a decision. [Error] when a file of the zone is
    stopped, the files disagree, or the store holds no answer: the judgments
    of an entry of {!commit}, made on what the zone holds in memory, without a
    read of a file. A change that another process made to a file and that no
    write of the zone has met yet is not seen here either ({b Probe}).

    The gate reads [revocation_pending(subject)] (design 8.3) in this state
    with {!Authz_state.revocation}: a reduction whose record did not append
    is held in it from the failed commit on, not from the next entry, and
    from the start when the zone opens with its intent still pending. *)
val read : t -> (trusted, uncertain) result

(** The record to append. Its seq and previous hash come from the head, and its
    time from the clock of the zone. *)
type draft =
  { author : Authz_records.Author.t
  ; kind : Authz_record.Kind.t
  ; body : Authz_body.t
  }

type committed =
  { snapshot : snapshot  (** The state with the record. *)
  ; record_hash : Authz_record.Hash.t
  ; settled : Authz_high_water.settlement  (** What the zone closed before the record. *)
  }

(** What {!install} wrote. *)
type installed =
  { snapshot : snapshot  (** The state with the record. *)
  ; record_hash : Authz_record.Hash.t
  ; aborted : Authz_external_store.intent option
        (** The [Fresh_bootstrap] intent that the log never got, which the zone
            gave up before the record. *)
  }

(** Why a commit or an install failed, and what it left in the files. *)
type error =
  | Store_stopped of Authz_external_store.stop  (** Nothing was written. *)
  | Log_stopped of Authz_log.stop  (** Nothing was written. *)
  | Uncertain of
      { first : Authz_high_water.reason
      ; rest : Authz_high_water.reason list
      }
      (** The store and the log do not agree (design 8.2, items 2 to 5). Nothing
          was written. *)
  | Store_holds_no_answer
      (** {!commit}: the store and the log agree, and the store holds no answer
          ({!Authz_high_water.Nothing_answered}), while the log holds a
          [Fresh_bootstrap]: the store was emptied, or is not the store of this
          log (design 5.1, 8.4). Nothing was written. *)
  | Log_holds_records of { next_seq : int }
      (** {!install}: the log, as its handle has it, holds records, and
          [next_seq] is the seq of the next one. Nothing was written. *)
  | Record_not_built of Authz_record.make_error  (** Nothing was written. *)
  | Refused of Authz_state.refusal  (** Nothing was written. *)
  | Store_entry_refused of
      { entry : Authz_external_store.entry
      ; violation : Authz_external_store.violation
      }
      (** The probe refused [entry], so it was not written. This means a bug in
          the zone. When [entry] is the settlement, nothing was written. When it
          is the intent, the settlement was. When it is the [Committed], the
          record is in the log and in the snapshot as well. When the settlement
          gives up a reduction, the snapshot holds its block in every case. *)
  | Abort_not_confirmed of Authz_log.end_error
      (** An earlier writer left an intent to abort, and the end of the log was
          not confirmed. Nothing was written. [End_moved] and
          [End_not_one_file] stop the log, and the next start judges the intent
          from the file. After [End_locked] or [End_unread] the log is not
          stopped, and the next commit or install asks again. *)
  | Settlement_not_written of Authz_external_store.append_error
      (** The call stopped at the settlement, and nothing of the record was
          written. *)
  | Intent_not_written of Authz_external_store.append_error
      (** The call stopped at the intent. A settlement before it is in the
          store, and nothing of the record is in the log. *)
  | Record_not_appended of Authz_log.append_error
      (** The intent, when the record has one, is in the store. When the error
          stopped the log, the next start reads whether the record is in it.
          Otherwise it is not, and the next commit or install aborts the
          intent. The subject of a reduction is blocked in the published state
          from this failure on (design 8.3). *)
  | Answer_not_written of
      { record_hash : Authz_record.Hash.t
      ; error : Authz_external_store.append_error
      }
      (** The call stopped at the [Committed]. The record is in the log and in
          the snapshot. *)

(** What a caller that answers a person gives. A record that was turned down
    ({!Refused}, {!Record_not_built}, {!Log_holds_records}) says why, as
    {!error_detail} does. Every other error is a failure of the zone: its
    reason names paths of the server, so the text is one fixed sentence. *)
val error_to_string : error -> string

(** The reason in full, with the paths of the files: for the operator of the
    host. *)
val error_detail : error -> string

(** Appends one record, as the module text says. A failure of the zone is
    written to the log with {!error_detail}, so the operator has the reason
    that {!error_to_string} leaves out. A record that was turned down is not
    written to the log. *)
val commit : t -> draft -> (committed, error) result

(** Appends the first record of a log with the steps of {!commit}, for
    {!Authz_bootstrap}. [log] and [store] are handles that the caller opened
    and does not write through while the call runs. The call takes the lock of
    each handle ({!Authz_external_store.with_writer}, {!Authz_log.with_writer}),
    which is not reentrant, so it is not made from inside a zone of either
    handle: it would wait on itself. Two things differ from {!commit}:
    - The log, as its handle has it, holds no record ({!Log_holds_records}).
      The replay is the empty one, over the store as its handle has it, so
      {!Authz_state.apply} takes a [Fresh_bootstrap] and refuses every other
      record.
    - The store is judged with {!Authz_high_water.settle_over_empty_log}, which
      holds no answer. The intent of a [Fresh_bootstrap] that the log never got
      is aborted, after {!Authz_log.confirm_end}, and {!installed} names it.

    The zone lives for this call, reads [now_ms] for the time of the record,
    and its snapshot is the one in {!installed}. *)
val install
  :  now_ms:(unit -> int)
  -> log:Authz_log.t
  -> store:Authz_external_store.t
  -> draft
  -> (installed, error) result
