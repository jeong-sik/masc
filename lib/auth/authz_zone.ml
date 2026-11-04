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

type open_error =
  | Store_not_opened of S.violation S.open_error
  | Log_not_opened of Authz_state.refusal L.open_error
  | Not_bootstrapped of { path : string }

let open_error_to_string = function
  | Store_not_opened error -> S.open_error_to_string S.violation_to_string error
  | Log_not_opened error -> L.open_error_to_string Authz_state.refusal_to_string error
  | Not_bootstrapped { path } ->
    Printf.sprintf "the authorization log %s holds no Fresh_bootstrap" path
;;

let open_at_start ~log_path ~store_path =
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
  | Uncertain of
      { first : H.reason
      ; rest : H.reason list
      }
  | Record_not_built of R.make_error
  | Refused of Authz_state.refusal
  | Store_entry_refused of
      { entry : S.entry
      ; violation : S.violation
      }
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
  | Record_not_built (R.Author_not_admitted { kind; author = _ }) ->
    Printf.sprintf "the author may not write a %s record" (R.Kind.to_string kind)
  | Refused refusal -> "the record was refused: " ^ Authz_state.refusal_to_string refusal
  | Store_entry_refused { entry; violation } ->
    Printf.sprintf
      "%s was not written to the external store: %s"
      (entry_label entry)
      (S.violation_to_string violation)
  | Settlement_not_written error ->
    "the intent that an earlier commit left was not closed: " ^ S.append_error_to_string error
  | Intent_not_written error -> "the intent was not written: " ^ S.append_error_to_string error
  | Record_not_appended error ->
    "the record was not appended and its intent is in the external store: "
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

let write_settlement t store_writer settlement =
  match H.settlement_entry settlement with
  | None -> Ok ()
  | Some entry ->
    write_entry t store_writer entry ~not_written:(fun error -> Settlement_not_written error)
;;

(* Only the zone writes through [t.log], so [head] is the head of the published
   snapshot. *)
let in_zone t draft store_writer log_writer head =
  let published = Atomic.get t.current in
  match H.settle_on_entry t.probe with
  | Error (first, rest) -> Error (Uncertain { first; rest })
  | Ok settled ->
    let* record =
      Result.map_error
        (fun error -> Record_not_built error)
        (R.make ~head ~at_ms:draft.at_ms ~author:draft.author ~kind:draft.kind ~body:draft.body)
    in
    let* { Authz_state.state; high_water = change } =
      Result.map_error (fun refusal -> Refused refusal) (Authz_state.apply published.state record)
    in
    let* () = write_settlement t store_writer settled in
    let record_hash = record.R.hash in
    let intent =
      { S.previous_record_hash = R.head_hash head; intended_next_record_digest = record_hash; change }
    in
    let* () =
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
