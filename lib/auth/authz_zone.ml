(* HIGH-RISK-UNREVIEWED: see the interface. *)

module H = Authz_high_water
module L = Authz_log
module P = Authz_presence
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

type open_error =
  | Store_not_opened of S.violation S.open_error
  | Log_not_opened of Authz_state.refusal L.open_error
  | Not_bootstrapped of { path : string }
  | Log_not_checked of
      { path : string
      ; detail : string
      }

let open_error_to_string = function
  | Store_not_opened error -> S.open_error_to_string S.violation_to_string error
  | Log_not_opened error -> L.open_error_to_string Authz_state.refusal_to_string error
  | Not_bootstrapped { path } ->
    Printf.sprintf "the authorization log %s is not there or holds no Fresh_bootstrap" path
  | Log_not_checked { path; detail } ->
    Printf.sprintf "whether the authorization log %s is there cannot be told: %s" path detail
;;

let open_files ~log_path ~store_path =
  match S.open_at_start ~path:store_path ~init:S.State.empty ~step:S.apply with
  | Error error -> Error (Store_not_opened error)
  | Ok (store, store_state, (_ : S.recovered)) ->
    (match L.open_at_start ~path:log_path ~init:(Replay.init store_state) ~step:Replay.step with
     | Error error -> Error (Log_not_opened error)
     | Ok (log, (replay : Replay.t), (_ : L.recovered)) ->
       (match replay.state.Authz_state.mode with
        | Authz_mode_state.Not_bootstrapped -> Error (Not_bootstrapped { path = log_path })
        | Authz_mode_state.Multi_account _ | Authz_mode_state.Off _ ->
          Ok
            { log
            ; store
            ; current = Atomic.make { state = replay.state; head = replay.head }
            ; probe = replay.probe
            }))
;;

(* Opening a file makes its directory and its lock file, so a log that is not
   there is refused before either file is opened. *)
let open_at_start ~log_path ~store_path =
  match P.of_path log_path with
  | P.Not_there -> Error (Not_bootstrapped { path = log_path })
  | P.Cannot_check detail -> Error (Log_not_checked { path = log_path; detail })
  | P.There -> open_files ~log_path ~store_path
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

type installed =
  { snapshot : snapshot
  ; record_hash : R.Hash.t
  ; aborted : S.intent option
  }

type error =
  | Store_stopped of S.stop
  | Log_stopped of L.stop
  | Uncertain of
      { first : H.reason
      ; rest : H.reason list
      }
  | Store_holds_no_answer
  | Log_holds_records of { next_seq : int }
  | Record_not_built of R.make_error
  | Refused of Authz_state.refusal
  | Store_entry_refused of
      { entry : S.entry
      ; violation : S.violation
      }
  | Abort_not_confirmed of L.end_error
  | Settlement_not_written of S.append_error
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
  | Uncertain { first; rest } ->
    "the external store and the log do not agree: "
    ^ String.concat "; " (List.map H.reason_to_string (first :: rest))
  | Store_holds_no_answer ->
    "the external store holds no answer, and the authorization log holds a Fresh_bootstrap"
  | Log_holds_records { next_seq } ->
    Printf.sprintf
      "the authorization log is to be installed and holds records: the next one is %d"
      next_seq
  | Record_not_built (R.Author_not_admitted { kind; author = _ }) ->
    Printf.sprintf "the author may not write a %s record" (R.Kind.to_string kind)
  | Refused refusal -> "the record was refused: " ^ Authz_state.refusal_to_string refusal
  | Store_entry_refused { entry; violation } ->
    Printf.sprintf
      "%s was not written to the external store: %s"
      (entry_label entry)
      (S.violation_to_string violation)
  | Abort_not_confirmed error ->
    "the intent that an earlier writer left was not aborted, because the end of the log was not \
     confirmed: "
    ^ L.end_error_to_string error
  | Settlement_not_written error ->
    "the intent that an earlier writer left was not closed: " ^ S.append_error_to_string error
  | Intent_not_written error -> "the intent was not written: " ^ S.append_error_to_string error
  | Record_not_appended error ->
    "the record was not appended, and an intent written for it stays in the external store \
     until the next entry settles it: "
    ^ L.append_error_to_string error
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

(* An abort says that the log ends where the intent began. The probe says so
   from what this process saw, and the append that the intent was for failed,
   which is when another process may have held the log, so the file is asked. *)
let write_settlement t store_writer log_writer settlement =
  let* () =
    match settlement with
    | H.Nothing_to_settle | H.Promote _ -> Ok ()
    | H.Abort _ ->
      Result.map_error (fun error -> Abort_not_confirmed error) (L.confirm_end log_writer)
  in
  match H.settlement_entry settlement with
  | None -> Ok ()
  | Some entry ->
    write_entry t store_writer entry ~not_written:(fun error -> Settlement_not_written error)
;;

let uncertain (first, rest) = Uncertain { first; rest }

(* What the entry of a zone lets through: the settlement of what an earlier
   writer left, which the zone writes before its intent. A commit adds to an
   installed log, so the store must hold an answer. *)
let entered_to_add = function
  | Error reasons -> Error (uncertain reasons)
  | Ok H.Nothing_answered -> Error Store_holds_no_answer
  | Ok (H.Answered settled) -> Ok settled
;;

let abort_settlement = function
  | None -> H.Nothing_to_settle
  | Some intent -> H.Abort intent
;;

(* Only the zone writes through [t.log], so [head] is the head of the published
   snapshot. *)
let in_zone t draft store_writer log_writer head settlement =
  let published = Atomic.get t.current in
  let* record =
    Result.map_error
      (fun error -> Record_not_built error)
      (R.make ~head ~at_ms:draft.at_ms ~author:draft.author ~kind:draft.kind ~body:draft.body)
  in
  let* { Authz_state.state; high_water } =
    Result.map_error (fun refusal -> Refused refusal) (Authz_state.apply published.state record)
  in
  (* The settlement comes first even for a record with no intent: the append
     moves the head, and an intent left pending behind it could no longer be
     aborted (design 8.2-1 and 8.2-5). *)
  let* () = write_settlement t store_writer log_writer settlement in
  let record_hash = record.R.hash in
  let* () =
    match high_water with
    | None -> Ok ()
    | Some change ->
      let intent =
        { S.previous_record_hash = R.head_hash head
        ; intended_next_record_digest = record_hash
        ; change
        }
      in
      write_entry t store_writer (S.Intent_pending intent) ~not_written:(fun error ->
        Intent_not_written error)
  in
  let* head =
    Result.map_error (fun error -> Record_not_appended error) (L.append log_writer [ record ])
  in
  t.probe <- H.Probe.add t.probe record;
  let snapshot = { state; head } in
  Atomic.set t.current snapshot;
  let* () =
    match high_water with
    | None -> Ok ()
    | Some (_ : S.Change.t) ->
      write_entry t store_writer (S.Committed { record_hash }) ~not_written:(fun error ->
        Answer_not_written { record_hash; error })
  in
  Ok (snapshot, record_hash)
;;

(* The zone of the store, and inside it the zone of the log. *)
let in_both_zones ~store ~log f =
  let in_store_zone store_writer store_state =
    match L.with_writer log (f store_writer store_state) with
    | Ok result -> result
    | Error stop -> Error (Log_stopped stop)
  in
  match S.with_writer store in_store_zone with
  | Ok result -> result
  | Error stop -> Error (Store_stopped stop)
;;

let commit t draft =
  in_both_zones ~store:t.store ~log:t.log (fun store_writer (_ : S.State.t) log_writer head ->
    let* settled = entered_to_add (H.settle_on_entry t.probe) in
    let* snapshot, record_hash = in_zone t draft store_writer log_writer head settled in
    Ok { snapshot; record_hash; settled })
;;

(* The handles are the caller's, and the log they show holds no record, so the
   replay of the log is the empty one, over the store as its handle has it. The
   zone lives for this one call. *)
let install ~log ~store draft =
  in_both_zones ~store ~log (fun store_writer store_state log_writer head ->
    if Int.equal (R.next_seq head) (R.next_seq R.genesis)
    then (
      let* aborted = Result.map_error uncertain (H.settle_over_empty_log store_state) in
      let t =
        { log
        ; store
        ; current = Atomic.make { state = Authz_state.empty; head }
        ; probe = H.Probe.create store_state
        }
      in
      let* snapshot, record_hash =
        in_zone t draft store_writer log_writer head (abort_settlement aborted)
      in
      Ok { snapshot; record_hash; aborted })
    else Error (Log_holds_records { next_seq = R.next_seq head }))
;;
