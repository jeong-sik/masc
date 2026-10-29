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
    }

  let create state =
    { state; head = Hash.genesis; after_previous = None; commit_seen = false }
  ;;

  let add probe (record : Authz_record.t) =
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
    { probe with head = record.Authz_record.hash; after_previous; commit_seen }
  ;;
end

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
     | None ->
       if Hash.equal probe.Probe.head intent.Store.previous_record_hash
       then Ok (Abort intent)
       else Error (Intent_unplaced intent))
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

let judge (probe : Probe.t) =
  match check_commit probe, settle probe with
  | Error first, Error second -> Mismatch (first, [ second ])
  | Error reason, Ok _ | Ok (), Error reason -> Mismatch (reason, [])
  | Ok (), Ok settlement ->
    (* The rules of the store let an intent come before the first [Committed]
       only if it is a [Fresh_bootstrap], so with no [Committed] there is no
       event that was answered, and an intent that the log never got is the
       bootstrap that did not happen (design 5.1, 없음). A promoted intent is a
       [Committed] that the store has not written yet. *)
    (match Store.State.last_committed probe.Probe.state, settlement with
     | None, (Nothing_to_settle | Abort _) -> Absent
     | None, Promote _ | Some _, (Nothing_to_settle | Promote _ | Abort _) -> Matches)
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
;;
