(* HIGH-RISK-UNREVIEWED: see the interface. *)

module H = Authz_high_water
module L = Authz_log
module R = Authz_record
module S = Authz_external_store

let ( let* ) = Result.bind

module Replay = struct
  type t =
    { state : Authz_state.t
    ; probe : H.Probe.t
    ; head : R.head
    }

  let init store = { state = Authz_state.empty; probe = H.Probe.create store; head = R.genesis }

  let step replay (record : R.t) =
    match Authz_state.step replay.state record with
    | Ok state -> Ok { state; probe = H.Probe.add replay.probe record; head = R.head_after record }
    | Error refusal -> Error refusal
  ;;
end

type snapshot =
  { state : Authz_state.t
  ; head : R.head
  }

(* [probe] changes only inside the zone of [store], which one fiber holds at a
   time. *)
type t =
  { log : L.t
  ; store : S.t
  ; current : snapshot Atomic.t
  ; mutable probe : H.Probe.t
  }

let create ~log ~store (replay : Replay.t) =
  { log
  ; store
  ; current = Atomic.make { state = replay.Replay.state; head = replay.Replay.head }
  ; probe = replay.Replay.probe
  }
;;

let snapshot t = Atomic.get t.current

type draft =
  { at_ms : int
  ; author : Authz_records.Author.t
  ; kind : R.Kind.t
  ; body : Authz_body.t
  }

type committed =
  { snapshot : snapshot
  ; record_hash : R.Hash.t
  ; settled : H.settlement
  }

type error =
  | Store_stopped of S.stop
  | Log_stopped of L.stop
  | Log_moved of
      { published : R.Hash.t
      ; found : R.Hash.t
      }
  | Uncertain of
      { first : H.reason
      ; rest : H.reason list
      }
  | Store_entry_refused of
      { entry : S.entry
      ; violation : S.violation
      }
  | Settlement_not_written of S.append_error
  | Record_not_built of R.make_error
  | Refused of Authz_state.refusal
  | Intent_not_written of S.append_error
  | Record_not_appended of L.append_error
  | Answer_not_written of
      { record_hash : R.Hash.t
      ; error : S.append_error
      }

let entry_label = function
  | S.Intent_pending _ -> "an intent"
  | S.Committed _ -> "a commit"
  | S.Aborted_intent _ -> "an aborted intent"
;;

let error_to_string = function
  | Store_stopped { S.path; reason } -> Printf.sprintf "the external store %s is stopped: %s" path reason
  | Log_stopped { L.path; reason } ->
    Printf.sprintf "the authorization log %s is stopped: %s" path reason
  | Log_moved { published; found } ->
    Printf.sprintf
      "the log ends at %s and the zone published %s: a record was appended outside the zone"
      (R.Hash.to_hex found)
      (R.Hash.to_hex published)
  | Uncertain { first; rest } ->
    "the external store and the log do not agree: "
    ^ String.concat "; " (List.map H.reason_to_string (first :: rest))
  | Store_entry_refused { entry; violation } ->
    Printf.sprintf
      "%s was not written to the external store: %s"
      (entry_label entry)
      (S.violation_to_string violation)
  | Settlement_not_written error ->
    "the intent that an earlier commit left was not closed: " ^ S.append_error_to_string error
  | Record_not_built (R.Author_not_admitted { kind; author = _ }) ->
    Printf.sprintf "the author may not write a %s record" (R.Kind.to_string kind)
  | Refused refusal -> "the record was refused: " ^ Authz_state.refusal_to_string refusal
  | Intent_not_written error -> "the intent was not written: " ^ S.append_error_to_string error
  | Record_not_appended error -> "the record was not appended: " ^ L.append_error_to_string error
  | Answer_not_written { record_hash; error } ->
    Printf.sprintf
      "the record %s is in the log and its answer was not written: %s"
      (R.Hash.to_hex record_hash)
      (S.append_error_to_string error)
;;

(* The probe takes the entry before the store does, so an entry that the probe
   refuses is not written, and the probe moves only once the store has it. *)
let write_entry t store_writer entry ~not_written =
  match H.Probe.store_moved t.probe entry with
  | Error violation -> Error (Store_entry_refused { entry; violation })
  | Ok probe ->
    (match S.append store_writer [ entry ] with
     | Error error -> Error (not_written error)
     | Ok (_ : S.State.t) ->
       t.probe <- probe;
       Ok ())
;;

(* Design 8.2-1: what an earlier entry left is judged before anything is
   written. *)
let settle t store_writer =
  match H.judge t.probe with
  | H.Mismatch (first, rest) -> Error (Uncertain { first; rest })
  | H.Absent | H.Matches ->
    (match H.settle t.probe with
     | Error first -> Error (Uncertain { first; rest = [] })
     | Ok settlement ->
       (match H.settlement_entry settlement with
        | None -> Ok settlement
        | Some entry ->
          let* () =
            write_entry t store_writer entry ~not_written:(fun error -> Settlement_not_written error)
          in
          Ok settlement))
;;

let append t log_writer (record : R.t) state =
  let* head =
    Result.map_error (fun error -> Record_not_appended error) (L.append log_writer [ record ])
  in
  t.probe <- H.Probe.add t.probe record;
  let snapshot = { state; head } in
  Atomic.set t.current snapshot;
  Ok snapshot
;;

let in_zone t draft store_writer log_writer head =
  let published = Atomic.get t.current in
  let found = R.head_hash head in
  if not (R.Hash.equal found (R.head_hash published.head))
  then Error (Log_moved { published = R.head_hash published.head; found })
  else
    let* settled = settle t store_writer in
    let* record =
      Result.map_error
        (fun error -> Record_not_built error)
        (R.make ~head ~at_ms:draft.at_ms ~author:draft.author ~kind:draft.kind ~body:draft.body)
    in
    let* { Authz_state.state; high_water } =
      Result.map_error (fun refusal -> Refused refusal) (Authz_state.apply published.state record)
    in
    let record_hash = record.R.hash in
    match high_water with
    | None ->
      let* snapshot = append t log_writer record state in
      Ok { snapshot; record_hash; settled }
    | Some change ->
      let intent =
        { S.previous_record_hash = found; intended_next_record_digest = record_hash; change }
      in
      let* () =
        write_entry t store_writer (S.Intent_pending intent) ~not_written:(fun error ->
          Intent_not_written error)
      in
      let* snapshot = append t log_writer record state in
      let* () =
        write_entry t store_writer (S.Committed { record_hash }) ~not_written:(fun error ->
          Answer_not_written { record_hash; error })
      in
      Ok { snapshot; record_hash; settled }
;;

let commit t draft =
  let in_store_zone store_writer (_ : S.State.t) =
    match L.with_writer t.log (in_zone t draft store_writer) with
    | Ok result -> result
    | Error stop -> Error (Log_stopped stop)
  in
  match S.with_writer t.store in_store_zone with
  | Ok result -> result
  | Error stop -> Error (Store_stopped stop)
;;
