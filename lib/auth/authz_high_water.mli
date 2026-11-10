(* HIGH-RISK-UNREVIEWED: this module says whether the authorization log and the
   external store agree. A wrong answer starts a boot on a log that was rolled
   back, or turns away a boot that was clean. *)

(** The judgments of design 8.2, items 2 to 5, and the value of the external
    high-water mark of design 5.1 that they give.

    The external store ({!Authz_external_store}) gets the intent of an event
    before the event is appended to the authorization log, and the answer after
    it. After a crash, a restore of the base path, or an append that failed, the
    store and the log can disagree. This module says how, from two things: what
    the store adds up to ({!Authz_external_store.State.t}) and what a few
    records of the log say.

    It reads no file and writes none.

    {b What it looks at in the log.} Three facts: the hash of the last record,
    the hash of the record that follows the [previous_record_hash] of the pending
    intent, and whether a record has the hash of the last [Committed]. A
    {!Probe} collects them while the log is replayed, so its memory does not grow
    with the log. The probe is built from the store, because it has to know
    which hashes to look for, so the store is opened first.

    {b Two answers.} Design 5.1 runs the judgments first and reads the value
    after them, so the answers are separate and neither waits for the other.
    - {!settle} says what closes the pending intent, or why nothing does (items
      2, 3 and 5). It does not look at the last [Committed].
    - {!judge} says whether the store and the log agree (items 2 to 5 together).

    The value does not carry the write. Read {!settle} for every value,
    [Mismatch] included: the judgment of item 3 stands the block of design 8.3
    as soon as it is made, and an intent that nobody closes keeps the store from
    taking a new one (the rules of {!Authz_external_store}). A write moves the
    store, and the next boot reads the store after it: a {!Promote} makes the
    promoted record the last [Committed]. Which writes the layer above makes
    while the value is [Mismatch] is for it to decide, and whether a write
    succeeds does not change the value (design 5.1).

    {b What an intent names.} The judgment compares the first record after
    [previous_record_hash] with the digest of the intent, so an intent names the
    first record that its event appends. Design 10.1 applies the intent rules to
    a batch of appends. Which record the intent of a batch names is for the layer
    that writes batches.

    {b While no record follows.} An {!Abort} holds only while no record follows
    [previous_record_hash]. If a record other than the one that the intent named
    lands there (a lease, for example), the same intent reads {!Digest_differs}
    for good. The layer that owns the zone judges on every entry into the zone,
    before anything is appended (design 8.2-1), so that no record follows an
    intent that was not judged.

    {b The judgments.} With an intent pending, the record after its
    [previous_record_hash] decides:
    - it is the record that the intent named: the event reached the log and only
      the answer is missing ({!Promote}, item 2);
    - it is another record: the log holds something else where the event was
      to go ({!Digest_differs}, items 2 and 5);
    - there is no such record and the log ends at [previous_record_hash]: the
      append never happened ({!Abort}, item 3);
    - there is no such record and the log ends elsewhere: [previous_record_hash]
      is not in the log ({!Intent_unplaced}, item 5).

    The record is found by its place, after [previous_record_hash]. A record hash
    covers its seq and its previous hash, so for an intent that a writer made
    right, the record found by its place and the record found by its hash are the
    same one. They differ only for an intent whose digest is not the hash of a
    record that can stand in that place, and this module reads that as
    {!Digest_differs}. The head may have moved on since the event, because
    records that only the log holds (leases) are appended after the record of
    the event; the intent is still settled by the record after its
    [previous_record_hash].

    Whatever the pending intent says, the last [Committed] has to be in the log.
    If it is not, an event that was answered is gone from the log
    ({!Commit_not_in_log}, item 4). The last [Committed] is the one the store
    holds before any write. A promoted intent does not stand in for it.

    {b The epochs.} Design 5.1 also wants the epochs of the replay to be the
    ones the store holds. The store keeps no epoch value. An epoch rises, a
    credential generation changes and the mode changes only by a record that
    takes an intent ({!Authz_state.apply} says which), and the last [Committed]
    fixes every record before it, as a record hash covers the hash before it.
    So the epochs agree exactly when the log holds as many records that take an
    intent as the store answers, a promoted intent counted as answered. A
    record that takes an intent and was appended outside the zone breaks this
    ({!Answers_differ}), whatever was appended after it. A record that takes no
    intent (a lease, the issue of an invitation, an enable) is not counted, so
    one appended outside the zone is not seen here. *)

(** What closes the pending intent. *)
type settlement =
  | Nothing_to_settle  (** No intent is pending. *)
  | Promote of Authz_external_store.intent
      (** The record that the intent named is in the log. Write [Committed] with
          its hash. The event is not run again (design 8.2, item 2). *)
  | Abort of Authz_external_store.intent
      (** The log ends where the intent began and the record is not in it. Write
          [Aborted_intent] with this intent (design 8.2, item 3). *)

(** Why the log and the store do not agree. *)
type reason =
  | Digest_differs of
      { intent : Authz_external_store.intent
      ; found : Authz_record.Hash.t
      }
      (** The log has a record after the [previous_record_hash] of the intent,
          and its hash is [found], not the one the intent named (items 2 and 5).
          A record appended outside the zone, or a lease that landed after a
          failed append, reads this way. *)
  | Commit_not_in_log of Authz_record.Hash.t
      (** The last [Committed] names a record that the log does not hold. The
          log went back to before an event that was answered (item 4). *)
  | Intent_unplaced of Authz_external_store.intent
      (** The log has no record after the [previous_record_hash] of the intent
          and does not end there either: [previous_record_hash] is not in the
          log. The log was rewound to before it, or replaced (item 5). *)
  | Answers_differ of
      { asked : int  (** The records of the log that take an intent. *)
      ; answered : int
          (** The [Committed] of the store, and one more for a promoted
              intent. *)
      }
      (** Every other judgment passes and the two numbers differ: the epochs of
          the replay are not the ones the store holds (design 5.1). A mode
          event or a revocation appended outside the zone reads this way. It is
          judged only when the store holds an answer and nothing else is
          wrong, so it comes alone. *)

(** The value of the external high-water mark (design 5.1), apart from the one
    that comes from not opening the store at all. *)
type t =
  | Absent
      (** Nothing has been answered and nothing is in the way: the store is
          empty, or holds only a [Fresh_bootstrap] intent that the log never
          got ({!Abort}), or only intents that were given up. The rules of the
          store let an intent come before the first [Committed] only if it is a
          [Fresh_bootstrap]. *)
  | Matches
      (** Every judgment passes, and something was answered or is promoted: the
          last [Committed] is in the log, {!settle} is [Ok], and the log holds
          as many records that take an intent as the store answers. A store with no
          [Committed] whose [Fresh_bootstrap] intent is a {!Promote} is
          [Matches], because design 5.1 counts a promoted intent as a
          [Committed]. Without a [Committed] and a {!Promote} the value is
          [Absent]. *)
  | Mismatch of reason * reason list
      (** The store can be read and does not agree with the log. Every reason is
          listed. {!Commit_not_in_log} comes first, then the reason of the
          intent. {!Answers_differ} comes alone. *)

(** What a few records of the log say, as far as the store needs. *)
module Probe : sig
  type t

  (** A probe for a store in the given state, over an empty log. *)
  val create : Authz_external_store.State.t -> t

  (** The probe after the next record of the log. Feed the records in file
      order, for instance from the fold function of {!Authz_log.open_at_start}.
      The records are those that {!Authz_log} has checked, so their hashes and
      links are not checked again. [high_water] is what {!Authz_state.apply}
      gives for the record: the change it takes an intent for, or [None]. *)
  val add
    :  t
    -> Authz_record.t
    -> high_water:Authz_external_store.Change.t option
    -> t

  (** The probe after the external store took [entry], for a writer that keeps
      one probe while it writes both files, so that it does not read the log
      again. [Error] is the violation the store refuses [entry] with
      ({!Authz_external_store.apply}): the writer asks here before it writes
      the entry.

      An [Intent_pending] is taken to have no record after its previous hash.
      That holds for an intent at the last record fed to the probe, as the
      intent of a writer is. An intent at an earlier record reads as
      {!Intent_unplaced}, and never as {!Abort}. A [Committed] counts as in the
      log when the record after the previous hash of the intent it closes was
      fed. *)
  val store_moved
    :  t
    -> Authz_external_store.entry
    -> (t, Authz_external_store.violation) result
end

(** Items 2, 3 and 5: what closes the pending intent. [Error] holds the reason
    of the intent ({!Digest_differs} or {!Intent_unplaced}), and the intent stays
    pending. *)
val settle : Probe.t -> (settlement, reason) result

(** The entry that carries out a settlement: [Committed] with the digest that a
    promoted intent named, [Aborted_intent] with an aborted one, and none for
    {!Nothing_to_settle}. The store takes it as the next entry and has no intent
    pending after it. {!Authz_external_store.apply} gives the state after it,
    and after a promoted [Fresh_bootstrap] that state holds the workspace. *)
val settlement_entry : settlement -> Authz_external_store.entry option

(** Whether a store and a log that agree hold an answer, and for one that
    does, what settles the intent that an earlier writer left. *)
type agreement =
  | Nothing_answered  (** The value is {!Absent}: the store holds no [Committed]. *)
  | Answered of settlement  (** The value is {!Matches}. *)

(** Items 2 to 5 and the epochs, as a writer reads them each time it enters its
    zone (design 8.2, item 1). When every judgment passes, whether the store
    holds an answer, with the settlement. Otherwise every reason, in the order
    of {!Mismatch}.
    A writer that adds to an installed log wants {!Answered}. A writer that
    installs one reads {!settle_over_empty_log}. *)
val settle_on_entry : Probe.t -> (agreement, reason * reason list) result

(** Items 2 to 5 for a store in the given state over a log with no record, as a
    writer that installs a log reads them on entry. No record follows the
    previous hash of an intent there, so nothing is promoted, and a [Committed]
    names a record that the log does not hold ({!Commit_not_in_log}). [Ok] is
    the [Fresh_bootstrap] intent that the log never got ({!Abort}), when one is
    pending. For {!Probe.create} of the same state, {!settle_on_entry} gives
    the same reasons, and {!Nothing_answered} where this gives [Ok]. *)
val settle_over_empty_log
  :  Authz_external_store.State.t
  -> (Authz_external_store.intent option, reason * reason list) result

(** The value for the store the probe was built from, and the log it was fed:
    [Mismatch] with the reasons of {!settle_on_entry} when it is [Error],
    [Absent] for {!Nothing_answered}, and [Matches] for {!Answered}. *)
val judge : Probe.t -> t

val reason_to_string : reason -> string
