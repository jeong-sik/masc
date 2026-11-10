(* HIGH-RISK-UNREVIEWED: this module says whether the authorization log and the
   external store agree. A wrong answer starts a boot on a log that was rolled
   back, or turns away a boot that was clean. *)

module Hash = Authz_record.Hash
module Store = Authz_external_store

type settlement =
  | Nothing_to_settle
  | Promote of Store.intent
  | Abort of Store.intent

type reason =
  | Digest_differs of
      { intent : Store.intent
      ; found : Hash.t
      }
  | Commit_not_in_log of Hash.t
  | Intent_unplaced of Store.intent
  | Answers_differ of
      { asked : int
      ; answered : int
      }

type t =
  | Absent
  | Matches
  | Mismatch of reason * reason list

module Probe = struct
  type t =
    { state : Store.State.t
    ; head : Hash.t (* The last record seen. The genesis hash before the first. *)
    ; after_previous : Hash.t option
        (* The first record that follows the previous_record_hash of the pending
           intent. *)
    ; commit_seen : bool (* A record has the hash of the last [Committed]. *)
    ; asked : int (* The records seen that took an intent. *)
    }

  let create state =
    { state; head = Hash.genesis; after_previous = None; commit_seen = false; asked = 0 }
  ;;

  let add probe (record : Authz_record.t) ~high_water =
    let asked =
      match high_water with
      | Some (_ : Store.Change.t) -> probe.asked + 1
      | None -> probe.asked
    in
    let after_previous =
      match probe.after_previous with
      | Some _ as found -> found
      | None ->
        (match Store.State.pending probe.state with
         | Some intent
           when Hash.equal record.Authz_record.previous_hash intent.Store.previous_record_hash
           -> Some record.Authz_record.hash
         | Some _ | None -> None)
    in
    let commit_seen =
      probe.commit_seen
      ||
      match Store.State.last_committed probe.state with
      | Some committed -> Hash.equal record.Authz_record.hash committed
      | None -> false
    in
    { probe with head = record.Authz_record.hash; after_previous; commit_seen; asked }
  ;;

  (* No record follows the previous hash of a new intent when that hash is the
     head, as it is for the intent of a writer. An intent at an earlier record
     keeps [after_previous] at [None] with a head that differs, which [settle]
     reads as [Intent_unplaced], never as [Abort]. A [Committed] closes the
     pending intent with the hash it named, so it is in the log when the record
     after the previous hash of that intent was fed. *)
  let store_moved probe entry =
    match Store.apply probe.state entry with
    | Error violation -> Error violation
    | Ok state ->
      (match entry with
       | Store.Intent_pending _ | Store.Aborted_intent _ ->
         Ok { probe with state; after_previous = None }
       | Store.Committed { record_hash } ->
         let commit_seen =
           match probe.after_previous with
           | Some found -> Hash.equal found record_hash
           | None -> false
         in
         Ok { probe with state; after_previous = None; commit_seen })
  ;;
end

(* Items 3 and 5 of design 8.2, when no record follows the previous hash of the
   intent: the end of the log decides. *)
let at_end ~head intent =
  if Hash.equal head intent.Store.previous_record_hash
  then Ok intent
  else Error (Intent_unplaced intent)
;;

(* Items 2, 3 and 5 of design 8.2: the record after the previous hash of the
   intent decides, and the end of the log decides when there is none. *)
let settle (probe : Probe.t) =
  match Store.State.pending probe.Probe.state with
  | None -> Ok Nothing_to_settle
  | Some intent ->
    (match probe.Probe.after_previous with
     | Some found ->
       if Hash.equal found intent.Store.intended_next_record_digest
       then Ok (Promote intent)
       else Error (Digest_differs { intent; found })
     | None -> Result.map (fun intent -> Abort intent) (at_end ~head:probe.Probe.head intent))
;;

let settlement_entry = function
  | Nothing_to_settle -> None
  | Promote intent ->
    Some (Store.Committed { record_hash = intent.Store.intended_next_record_digest })
  | Abort intent -> Some (Store.Aborted_intent intent)
;;

(* Item 4 of design 8.2: the last [Committed] has to be in the log. *)
let check_commit (probe : Probe.t) =
  match Store.State.last_committed probe.Probe.state with
  | Some committed when not probe.Probe.commit_seen -> Error (Commit_not_in_log committed)
  | Some _ | None -> Ok ()
;;

type agreement =
  | Nothing_answered
  | Answered of settlement

(* How many records the store answers once the settlement is written. A
   promoted intent is a [Committed] that the store has not written yet (design
   5.1). *)
let answered_after (probe : Probe.t) = function
  | Promote (_ : Store.intent) -> Store.State.answered probe.Probe.state + 1
  | Nothing_to_settle | Abort (_ : Store.intent) -> Store.State.answered probe.Probe.state
;;

(* The third condition of design 5.1: the epochs of the replay are the ones
   the store holds. Only a record that takes an intent raises an epoch or
   changes the mode, and the last [Committed] fixes every record before it, as
   a record hash covers the hash before it. So the two agree exactly when the
   log holds as many records that take an intent as the store answers. *)
let check_answers (probe : Probe.t) settlement =
  let answered = answered_after probe settlement in
  if Int.equal probe.Probe.asked answered
  then Ok (Answered settlement)
  else Error (Answers_differ { asked = probe.Probe.asked; answered }, [])
;;

let settle_on_entry (probe : Probe.t) =
  match check_commit probe, settle probe with
  | Error first, Error second -> Error (first, [ second ])
  | Error reason, Ok _ | Ok (), Error reason -> Error (reason, [])
  | Ok (), Ok settlement ->
    (* The rules of the store let an intent come before the first [Committed]
       only if it is a [Fresh_bootstrap], so with no [Committed] there is no
       event that was answered, and an intent that the log never got is the
       bootstrap that did not happen (design 5.1, 없음). A promoted intent is a
       [Committed] that the store has not written yet. *)
    (match Store.State.last_committed probe.Probe.state, settlement with
     | None, (Nothing_to_settle | Abort _) -> Ok Nothing_answered
     | None, Promote _ | Some _, (Nothing_to_settle | Promote _ | Abort _) ->
       check_answers probe settlement)
;;

(* Over a log with no record, no record follows the previous hash of an intent
   and the head is the genesis hash, so nothing can be promoted and the last
   [Committed] is never in the log. *)
let settle_over_empty_log state =
  let probe = Probe.create state in
  let pending =
    match Store.State.pending state with
    | None -> Ok None
    | Some intent -> Result.map Option.some (at_end ~head:probe.Probe.head intent)
  in
  match check_commit probe, pending with
  | Error first, Error second -> Error (first, [ second ])
  | Error reason, Ok (_ : Store.intent option) | Ok (), Error reason -> Error (reason, [])
  | Ok (), Ok abort -> Ok abort
;;

let judge (probe : Probe.t) =
  match settle_on_entry probe with
  | Error (first, rest) -> Mismatch (first, rest)
  | Ok Nothing_answered -> Absent
  | Ok (Answered (_ : settlement)) -> Matches
;;

let reason_to_string = function
  | Digest_differs { intent; found } ->
    Printf.sprintf
      "the log has record %s after the record that the intent for %s followed, and the intent named %s"
      (Hash.to_hex found)
      (Store.Change.to_string intent.Store.change)
      (Hash.to_hex intent.Store.intended_next_record_digest)
  | Commit_not_in_log committed ->
    Printf.sprintf
      "the last answered record %s is not in the log, so the log went back"
      (Hash.to_hex committed)
  | Intent_unplaced intent ->
    Printf.sprintf
      "the intent for %s has no record after %s in the log, and the log does not end there"
      (Store.Change.to_string intent.Store.change)
      (Hash.to_hex intent.Store.previous_record_hash)
  | Answers_differ { asked; answered } ->
    Printf.sprintf
      "the log holds %d records that take an answer of the external store, and the store answers \
       %d: a record that changes a permission or the mode was appended outside masc, or was \
       written by a build that asks the store for other records"
      asked
      answered
;;
