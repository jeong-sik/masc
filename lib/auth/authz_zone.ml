(* HIGH-RISK-UNREVIEWED: see the interface. *)

module H = Authz_high_water
module L = Authz_log
module P = Authz_presence
module R = Authz_record
module S = Authz_external_store

let ( let* ) = Result.bind

(* A writer that gives a reduction up blocks its subject in the state that reads
   the next record (design 8.3). The intent began where the log ended, so the
   block starts after the record at [previous_record_hash]. *)
let reduction_hold (intent : S.intent) =
  Option.map (fun held -> intent.S.previous_record_hash, held) (Authz_state.held_of_intent intent)
;;

let helds holds = List.map snd holds

module Replay = struct
  type t =
    { state : Authz_state.t
    ; probe : H.Probe.t
    ; head : R.head
    ; unreached : (R.Hash.t * Authz_state.held) list
    }

  (* The blocks of the reductions whose intent began at this head. *)
  let reach replay =
    let here, unreached =
      List.partition (fun (hash, _) -> R.Hash.equal hash (R.head_hash replay.head)) replay.unreached
    in
    { replay with state = Authz_state.hold_revocations replay.state (helds here); unreached }
  ;;

  let init store =
    reach
      { state = Authz_state.empty
      ; probe = H.Probe.create store
      ; head = R.genesis
      ; unreached = List.filter_map reduction_hold (S.State.aborted store)
      }
  ;;

  (* A block whose head the log no longer holds started when a writer opened
     the log ([finish]), so a record written after that may close or cancel
     it, and the block starts before that record. A record cannot name an
     intent that begins after it: the digest of the intent covers the hash of
     the record the intent began at, and so the record itself. *)
  let step replay (record : R.t) =
    let closed = Authz_state.closed_by record in
    let named, unreached =
      List.partition
        (fun ((_ : R.Hash.t), (held : Authz_state.held)) ->
          List.exists (R.Hash.equal held.Authz_state.aborted) closed)
        replay.unreached
    in
    match Authz_state.apply (Authz_state.hold_revocations replay.state (helds named)) record with
    | Ok { Authz_state.state; high_water } ->
      Ok
        (reach
           { state
           ; unreached
           ; probe = H.Probe.add replay.probe record ~high_water
           ; head = R.head_after record
           })
    | Error refusal -> Error refusal
  ;;

  (* A log that no longer reaches the head of a reduction still had it given up.
     A reduction whose intent is pending and that the next entry gives up
     (design 8.2-3) is blocked from the start, as the writer blocked it when
     its append failed, and not from that entry. *)
  let finish replay =
    let pending =
      match H.settle_on_entry replay.probe with
      | Ok (H.Answered (H.Abort intent)) -> Option.to_list (Authz_state.held_of_intent intent)
      | Ok (H.Answered (H.Nothing_to_settle | H.Promote (_ : S.intent))) | Ok H.Nothing_answered | Error _ ->
        []
    in
    { replay with
      state = Authz_state.hold_revocations replay.state (helds replay.unreached @ pending)
    ; unreached = []
    }
  ;;
end

type snapshot =
  { state : Authz_state.t
  ; head : R.head
  }

(* [probe] is set only inside the zone of [store], which one fiber holds at a
   time. The gate reads it outside, and each value it reads is one the files
   held, as a value is set whole. *)
type t =
  { log : L.t
  ; store : S.t
  ; now_ms : unit -> int
  ; current : snapshot Atomic.t
  ; probe : H.Probe.t Atomic.t
  }

type open_error =
  | Store_not_opened of S.violation S.open_error
  | Log_not_opened of Authz_state.refusal L.open_error
  | Not_bootstrapped of { path : string }
  | Log_not_checked of
      { path : string
      ; detail : string
      }
  | Store_not_there of { path : string }
  | Store_not_checked of
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
  | Store_not_there { path } ->
    Printf.sprintf
      "the authorization log is there and the external store %s is not, so neither is opened"
      path
  | Store_not_checked { path; detail } ->
    Printf.sprintf "whether the external store %s is there cannot be told: %s" path detail
;;

let open_files ~now_ms ~log_path ~store_path =
  match S.open_at_start ~path:store_path ~init:S.State.empty ~step:S.apply with
  | Error error -> Error (Store_not_opened error)
  | Ok (store, store_state, (_ : S.recovered)) ->
    (match L.open_at_start ~path:log_path ~init:(Replay.init store_state) ~step:Replay.step with
     | Error error -> Error (Log_not_opened error)
     | Ok (log, (replay : Replay.t), (_ : L.recovered)) ->
       (match replay.state.Authz_state.mode with
        | Authz_mode_state.Not_bootstrapped -> Error (Not_bootstrapped { path = log_path })
        | Authz_mode_state.Multi_account _ | Authz_mode_state.Off _ ->
          let replay = Replay.finish replay in
          Ok
            { log
            ; store
            ; now_ms
            ; current = Atomic.make { state = replay.state; head = replay.head }
            ; probe = Atomic.make replay.probe
            }))
;;

(* Opening a file makes its directory and its lock file, so a log or a store
   that is not there is refused before either file is opened. *)
let open_at_start ~now_ms ~log_path ~store_path =
  match P.of_path log_path with
  | P.Not_there -> Error (Not_bootstrapped { path = log_path })
  | P.Cannot_check detail -> Error (Log_not_checked { path = log_path; detail })
  | P.There ->
    (match P.of_path store_path with
     | P.Not_there -> Error (Store_not_there { path = store_path })
     | P.Cannot_check detail -> Error (Store_not_checked { path = store_path; detail })
     | P.There -> open_files ~now_ms ~log_path ~store_path)
;;

let snapshot t = Atomic.get t.current

type uncertain =
  | Log_is_stopped of L.stop
  | Store_is_stopped of S.stop
  | Files_disagree of
      { first : H.reason
      ; rest : H.reason list
      }
  | Store_answers_nothing

let uncertain_to_string = function
  | Log_is_stopped { L.path; reason } ->
    Printf.sprintf "the authorization log %s is stopped: %s" path reason
  | Store_is_stopped { S.path; reason } ->
    Printf.sprintf "the external store %s is stopped: %s" path reason
  | Files_disagree { first; rest } ->
    "the external store and the log do not agree: "
    ^ String.concat "; " (List.map H.reason_to_string (first :: rest))
  | Store_answers_nothing ->
    "the external store holds no answer, and the authorization log holds a Fresh_bootstrap"
;;

type trusted = snapshot

(* A stopped file is not in the published state (plan B3b), and a zone that
   cannot write cannot close or add a block either, so a decision asks the
   files first. A zone whose files disagree, or whose store holds no answer,
   refuses every commit, so it cannot close or add a block either (design
   8.2-4 and 8.2-5). The probe is read first and the state after it, each as
   the zone set it whole, so the state is the one published when the probe was
   read, or a later one. *)
let read t =
  match L.stopped t.log, S.stopped t.store with
  | Some stop, (_ : S.stop option) -> Error (Log_is_stopped stop)
  | None, Some stop -> Error (Store_is_stopped stop)
  | None, None ->
    (match H.settle_on_entry (Atomic.get t.probe) with
     | Error (first, rest) -> Error (Files_disagree { first; rest })
     | Ok H.Nothing_answered -> Error Store_answers_nothing
     | Ok (H.Answered (_ : H.settlement)) -> Ok (Atomic.get t.current))
;;

type draft =
  { author : Authz_records.Author.t
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
  | Store_stopped stop -> uncertain_to_string (Store_is_stopped stop)
  | Log_stopped stop -> uncertain_to_string (Log_is_stopped stop)
  | Uncertain { first; rest } -> uncertain_to_string (Files_disagree { first; rest })
  | Store_holds_no_answer -> uncertain_to_string Store_answers_nothing
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
  match H.Probe.store_moved (Atomic.get t.probe) entry with
  | Error violation -> Error (Store_entry_refused { entry; violation })
  | Ok probe ->
    (match S.append store_writer [ entry ] with
     | Error error -> Error (not_written error)
     | Ok (_ : S.State.t) ->
       Atomic.set t.probe probe;
       Ok ())
;;

(* An abort says that the log ends where the intent began. The probe says so
   from what this process saw, and the append that the intent was for failed,
   which is when another process may have held the log, so the file is asked. *)
let confirm_settlement log_writer = function
  | H.Nothing_to_settle | H.Promote (_ : S.intent) -> Ok ()
  | H.Abort (_ : S.intent) ->
    Result.map_error (fun error -> Abort_not_confirmed error) (L.confirm_end log_writer)
;;

let write_settlement t store_writer settlement =
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
  (* A reduction that this entry gives up blocks its subject before the record
     is read, so the record cannot spend what the reduction was about. *)
  let base =
    match settlement with
    | H.Abort intent ->
      Authz_state.hold_revocations published.state (Option.to_list (Authz_state.held_of_intent intent))
    | H.Nothing_to_settle | H.Promote (_ : S.intent) -> published.state
  in
  (* The clock is read inside both locks, so no other commit writes between the
     read and the append, and the time is the one the record is written at. *)
  let at_ms = t.now_ms () in
  let* record =
    Result.map_error
      (fun error -> Record_not_built error)
      (R.make ~head ~at_ms ~author:draft.author ~kind:draft.kind ~body:draft.body)
  in
  let apply record =
    Result.map_error (fun refusal -> Refused refusal) (Authz_state.apply base record)
  in
  let* applied = apply record in
  (* A reduction that was given up and is made again closes its block (design
     8.3). The record names the blocks it closes, so the hash and the intent
     cover them: the record is built again with them and read again. *)
  let* record, { Authz_state.state; high_water } =
    match Option.map (Authz_state.closable base) applied.Authz_state.high_water with
    | None | Some [] -> Ok (record, applied)
    | Some closes ->
      let record = R.closing record ~closes in
      Result.map (fun applied -> record, applied) (apply record)
  in
  (* The settlement comes first even for a record with no intent: the append
     moves the head, and an intent left pending behind it could no longer be
     aborted (design 8.2-1 and 8.2-5). *)
  let* () = confirm_settlement log_writer settlement in
  (* Once the end is confirmed the intent is given up, whatever the write of
     the abort does: a write that fails may still have put the line in the
     store. So the block is published before that write, and a commit that
     fails from here on leaves it in place. *)
  Atomic.set t.current { published with state = base };
  let* () = write_settlement t store_writer settlement in
  let record_hash = record.R.hash in
  let intent =
    Option.map
      (fun change ->
        { S.previous_record_hash = R.head_hash head; intended_next_record_digest = record_hash; change })
      high_water
  in
  let* () =
    match intent with
    | None -> Ok ()
    | Some intent ->
      write_entry t store_writer (S.Intent_pending intent) ~not_written:(fun error ->
        Intent_not_written error)
  in
  let* head =
    match L.append log_writer [ record ] with
    | Ok head -> Ok head
    | Error error ->
      (* The intent is in the store and the append failed, so the next entry
         gives the intent up (design 8.2-3), and the block of a reduction
         stands from now (design 8.3), not from that entry: a gate that reads
         the published state in between must not find the subject clear. If
         the failed append left the record in the log, the log is stopped and
         the gate answers that it does not know. *)
      Option.iter
        (fun held ->
          Atomic.set t.current { published with state = Authz_state.hold_revocations base [ held ] })
        (Option.bind intent Authz_state.held_of_intent);
      Error (Record_not_appended error)
  in
  Atomic.set t.probe (H.Probe.add (Atomic.get t.probe) record ~high_water);
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
    let* settled = entered_to_add (H.settle_on_entry (Atomic.get t.probe)) in
    let* snapshot, record_hash = in_zone t draft store_writer log_writer head settled in
    Ok { snapshot; record_hash; settled })
;;

(* The handles are the caller's, and the log they show holds no record, so the
   replay of the log is the empty one, over the store as its handle has it. The
   zone lives for this one call. *)
let install ~now_ms ~log ~store draft =
  in_both_zones ~store ~log (fun store_writer store_state log_writer head ->
    if Int.equal (R.next_seq head) (R.next_seq R.genesis)
    then (
      let* aborted = Result.map_error uncertain (H.settle_over_empty_log store_state) in
      (* The state a start would read over this store and the empty log. *)
      let replay = Replay.finish (Replay.init store_state) in
      let t =
        { log
        ; store
        ; now_ms
        ; current = Atomic.make { state = replay.state; head }
        ; probe = Atomic.make replay.probe
        }
      in
      let* snapshot, record_hash =
        in_zone t draft store_writer log_writer head (abort_settlement aborted)
      in
      Ok { snapshot; record_hash; aborted })
    else Error (Log_holds_records { next_seq = R.next_seq head }))
;;
