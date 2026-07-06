(** Keeper Transition Audit — Structured audit trail (RFC-0002).

    Types and JSON serialization extracted to [Keeper_transition_audit_types].
    This module retains ring buffer, store, recording, and query operations. *)

(* tla-lint: file-scope: structured audit trail for FSM transitions.
   The ring buffer (pos/count) and result accumulators here record
   what the FSM did; they do not influence what it does next.
   Mutations are bookkeeping for the JSONL flush layer. *)

include Keeper_transition_audit_types

(* ================================================================ *)

(** Per-keeper ring buffer: stores the last N transition records.
    Thread-safe via non-yielding StringMap + Array mutation in single-domain Eio. *)

type ring =
  { buf : transition_record option array
  ; mutable pos : int
  ; mutable count : int
  }

let ring_capacity = 50
let rings : (string, ring) Hashtbl.t = Hashtbl.create 16

type completed_turn_ring =
  { buf : completed_turn_record option array
  ; mutable pos : int
  ; mutable count : int
  }

let completed_turn_rings : (string, completed_turn_ring) Hashtbl.t = Hashtbl.create 16

let get_or_create_ring name =
  match Hashtbl.find_opt rings name with
  | Some r -> r
  | None ->
    let r : ring = { buf = Array.make ring_capacity None; pos = 0; count = 0 } in
    Hashtbl.replace rings name r;
    r
;;

let get_or_create_completed_turn_ring name =
  match Hashtbl.find_opt completed_turn_rings name with
  | Some r -> r
  | None ->
    let r : completed_turn_ring =
      { buf = Array.make ring_capacity None; pos = 0; count = 0 }
    in
    Hashtbl.replace completed_turn_rings name r;
    r
;;

(* ================================================================ *)
(* Optional file sink — best-effort jsonl append                    *)
(* ================================================================ *)

(** Path of the explicit transition log sink, configured via the
    [MASC_KEEPER_TRANSITION_LOG] env var. When unset or empty, records still
    fall back to the default dated-jsonl transition-audit store. Reading the
    env on each call keeps the surface tiny — one keeper transition per
    second is the upper bound, so the cost is negligible. *)
let sink_path () =
  match Sys.getenv_opt "MASC_KEEPER_TRANSITION_LOG" with
  | Some path when String.trim path <> "" -> Some path
  | _ -> None
;;

let default_store_ref : Dated_jsonl.t option ref = ref None

let get_default_store () =
  match !default_store_ref with
  | Some store -> Some store
  | None ->
    (try
       let dir =
         Filename.concat
           (Common.masc_dir_from_base_path ~base_path:(Env_config_core.base_path ()))
           "transition-audit"
       in
       let store = Dated_jsonl.create ~base_dir:dir () in
       default_store_ref := Some store;
       Some store
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string TransitionAuditFailures)
         ~labels:[ "site", "default_store" ]
         ();
       Log.Keeper.warn
         "transition_audit default store failed: %s"
         (Printexc.to_string exn);
       None)
;;

let observe_append_failure ~site exn =
  match exn with
  | Eio.Cancel.Cancelled _ as e ->
    let bt = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace e bt
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string TransitionAuditFailures)
      ~labels:[ "site", site ]
      ();
    Log.Keeper.warn "transition_audit %s failed: %s" site (Printexc.to_string exn)
;;

(* ================================================================ *)
(* Async default-store append queue                                  *)
(*                                                                   *)
(* Every FSM transition used to run [Dated_jsonl.append] inline on   *)
(* the keeper fiber: fd_accountant Log_writer semaphore -> per-store *)
(* Eio.Mutex shared by ALL keepers -> blocking write+flush. The      *)
(* 2026-06-10 fleet-freeze capture shows 12 keepers whose last       *)
(* observable event was the [fsm:transition] log line emitted        *)
(* immediately before this append — turn liveness was coupled to     *)
(* forensics durability through untimed shared locks. Per the module *)
(* contract (see [append_to_sink] doc) the in-memory ring is the     *)
(* authoritative live trail and the JSONL store is restart           *)
(* forensics, so the store write must never park a turn: recorders   *)
(* enqueue here and a maintenance fiber drains the queue off the     *)
(* keeper hot path (same shape as [Keeper_tool_call_log]'s async     *)
(* append).                                                          *)
(*                                                                   *)
(* The queue is bounded so a stalled drain cannot grow memory        *)
(* without limit; an overflow drops the incoming record, counts it   *)
(* under the existing TransitionAuditFailures metric, and warns.     *)
(* By contract a drop loses forensics rows only, never ring (live)   *)
(* state. Until [start_flush_fiber] runs (tests, non-server          *)
(* embedders) appends stay synchronous.                              *)
(* ================================================================ *)

type pending_append =
  { pending_site : string
  ; pending_json : Yojson.Safe.t
  }

let append_queue_capacity = 4096
let append_flush_interval_s = 0.5
let append_queue_mu = Stdlib.Mutex.create ()
let append_queue : pending_append Stdlib.Queue.t = Stdlib.Queue.create ()
let async_append_active = Atomic.make false
let append_queue_dropped = Atomic.make 0

let with_append_queue_lock f =
  Stdlib.Mutex.lock append_queue_mu;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock append_queue_mu) f
;;

let queued_count_for_testing () =
  with_append_queue_lock (fun () -> Stdlib.Queue.length append_queue)

let queue_depth = queued_count_for_testing
;;

let dropped_count_for_testing () = Atomic.get append_queue_dropped

let append_now ~site json =
  match get_default_store () with
  | None -> ()
  | Some store ->
    (match Dated_jsonl.append_result store json with
     | Ok () -> ()
     | Error msg -> observe_append_failure ~site (Sys_error msg))
;;

let flush_pending () =
  let batch =
    with_append_queue_lock (fun () ->
      let drained = Stdlib.Queue.create () in
      Stdlib.Queue.transfer append_queue drained;
      drained)
  in
  let n = Stdlib.Queue.length batch in
  Stdlib.Queue.iter
    (fun { pending_site; pending_json } -> append_now ~site:pending_site pending_json)
    batch;
  n
;;

let enqueue_or_append ~site json =
  if not (Atomic.get async_append_active)
  then append_now ~site json
  else begin
    let dropped =
      with_append_queue_lock (fun () ->
        if Stdlib.Queue.length append_queue >= append_queue_capacity
        then true
        else begin
          Stdlib.Queue.add { pending_site = site; pending_json = json } append_queue;
          false
        end)
    in
    if dropped
    then begin
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string TransitionAuditFailures)
        ~labels:[ "site", "async_queue_overflow" ]
        ();
      let dropped_count = Atomic.fetch_and_add append_queue_dropped 1 + 1 in
      Log.Keeper.warn
        "transition_audit: dropped %d forensics record(s) — async append queue \
         full (drain fiber stalled or store unavailable)"
        dropped_count
    end
  end
;;

let start_flush_fiber ~sw ~clock =
  Atomic.set async_append_active true;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Log.Keeper.info
      "transition_audit: async flush fiber started (interval=%.1fs, capacity=%d)"
      append_flush_interval_s
      append_queue_capacity;
    let rec loop () =
      match Eio.Time.sleep clock append_flush_interval_s with
      | exception Eio.Cancel.Cancelled _ -> `Stop_daemon
      | () ->
        (match flush_pending () with
         | (_ : int) -> ()
         | exception Eio.Cancel.Cancelled _ -> ()
         | exception exn ->
           Log.Keeper.warn
             "transition_audit: async flush iteration failed: %s"
             (Printexc.to_string exn));
        loop ()
    in
    loop ());
  Shutdown.register ~name:"keeper_transition_audit_flush" ~priority:24 (fun () ->
    try
      let n = flush_pending () in
      if n > 0
      then Log.Keeper.info "transition_audit: shutdown flush wrote %d records" n
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Keeper.warn
        "transition_audit: shutdown flush failed: %s"
        (Printexc.to_string exn))
;;

(** Append a single jsonl line for the given transition. Wraps the record
    json with the keeper name so a single sink file can mux multiple
    keepers. Any IO error is observed and suppressed: the in-memory ring is
    the authoritative trail for live dashboards, the sink is for restart
    forensics only. *)
let append_to_sink ~keeper_name (rec_ : transition_record) =
  match sink_path () with
  | None -> ()
  | Some path ->
    (try
       let line =
         Yojson.Safe.to_string
           (`Assoc [ "keeper", `String keeper_name; "record", to_json rec_ ])
       in
       let oc = open_out_gen [ Open_wronly; Open_append; Open_creat ] 0o644 path in
       Eio_guard.protect
         ~finally:(fun () -> close_out_noerr oc)
         (fun () -> output_string oc (line ^ "\n"))
     with
     | exn -> observe_append_failure ~site:"sink_append" exn)
;;

let append_to_default_store ~keeper_name (rec_ : transition_record) =
  let json = `Assoc [ "keeper", `String keeper_name; "record", to_json rec_ ] in
  enqueue_or_append ~site:"default_transition_append" json
;;

let append_completed_turn_to_default_store ~keeper_name (rec_ : completed_turn_record) =
  let json =
    `Assoc
      [ "keeper", `String keeper_name; "completed_turn", completed_turn_to_json rec_ ]
  in
  enqueue_or_append ~site:"default_completed_append" json
;;

let append_turn_fsm_transition_to_default_store
      ~keeper_name
      (rec_ : turn_fsm_transition_record)
  =
  let json =
    `Assoc
      [ "keeper", `String keeper_name
      ; "turn_fsm_transition", turn_fsm_transition_to_json rec_
      ]
  in
  enqueue_or_append ~site:"default_turn_fsm_append" json
;;

let record_transition ~keeper_name (rec_ : transition_record) =
  let ring = get_or_create_ring keeper_name in
  ring.buf.(ring.pos) <- Some rec_;
  ring.pos <- (ring.pos + 1) mod ring_capacity;
  ring.count <- ring.count + 1;
  match sink_path () with
  | Some _ -> append_to_sink ~keeper_name rec_
  | None -> append_to_default_store ~keeper_name rec_
;;

let recent_transitions ~keeper_name ~limit : transition_record list =
  match Hashtbl.find_opt rings keeper_name with
  | None -> []
  | Some ring ->
    let n = min limit (min ring.count ring_capacity) in
    let result = ref [] in
    for i = 0 to n - 1 do
      let idx = (ring.pos - 1 - i + ring_capacity) mod ring_capacity in
      match ring.buf.(idx) with
      | Some r -> result := r :: !result
      | None -> ()
    done;
    !result
;;

let recent_transitions_json ~keeper_name ~limit : Yojson.Safe.t =
  let recent = recent_transitions ~keeper_name ~limit in
  if recent <> []
  then `List (List.map to_json recent)
  else (
    match sink_path (), get_default_store () with
    | Some _, _ | _, None -> `List []
    | None, Some store ->
      (* Store readers run on dashboard fibers, not keeper turns: draining
         the async queue here is a cheap way to keep store-backed reads
         consistent with just-recorded transitions. *)
      let (_ : int) = flush_pending () in
      let items =
        Dated_jsonl.read_recent store (max limit 1 * 8)
        |> List.filter_map (function
          | `Assoc fields ->
            (match List.assoc_opt "keeper" fields, List.assoc_opt "record" fields with
             | Some (`String name), Some record when String.equal name keeper_name ->
               Some record
             | _ -> None)
          | _ -> None)
        |> List.filteri (fun idx _ -> idx < limit)
      in
      `List items)
;;

let record_completed_turn ~keeper_name (rec_ : completed_turn_record) =
  let ring = get_or_create_completed_turn_ring keeper_name in
  ring.buf.(ring.pos) <- Some rec_;
  ring.pos <- (ring.pos + 1) mod ring_capacity;
  ring.count <- ring.count + 1;
  match sink_path () with
  | None -> append_completed_turn_to_default_store ~keeper_name rec_
  | Some path ->
    (try
       let line =
         Yojson.Safe.to_string
           (`Assoc
               [ "keeper", `String keeper_name
               ; "completed_turn", completed_turn_to_json rec_
               ])
       in
       let oc = open_out_gen [ Open_wronly; Open_append; Open_creat ] 0o644 path in
       Eio_guard.protect
         ~finally:(fun () -> close_out_noerr oc)
         (fun () -> output_string oc (line ^ "\n"))
     with
     | exn -> observe_append_failure ~site:"sink_completed_append" exn)
;;

let record_turn_fsm_transition ~keeper_name (rec_ : turn_fsm_transition_record) =
  match sink_path () with
  | None -> append_turn_fsm_transition_to_default_store ~keeper_name rec_
  | Some path ->
    (try
       let line =
         Yojson.Safe.to_string
           (`Assoc
               [ "keeper", `String keeper_name
               ; "turn_fsm_transition", turn_fsm_transition_to_json rec_
               ])
       in
       let oc = open_out_gen [ Open_wronly; Open_append; Open_creat ] 0o644 path in
       Eio_guard.protect
         ~finally:(fun () -> close_out_noerr oc)
         (fun () -> output_string oc (line ^ "\n"))
     with
     | exn -> observe_append_failure ~site:"sink_turn_fsm_append" exn)
;;

let recent_completed_turns_from_store ~keeper_name ~limit =
  match sink_path (), get_default_store () with
  | Some _, _ | _, None -> []
  | None, Some store ->
    let (_ : int) = flush_pending () in
    Dated_jsonl.read_recent store (max limit 1 * 8)
    |> List.filter_map (function
      | `Assoc fields ->
        (match List.assoc_opt "keeper" fields, List.assoc_opt "completed_turn" fields with
         | Some (`String name), Some record when String.equal name keeper_name ->
           completed_turn_of_json record
         | _ -> None)
      | _ -> None)
    |> List.rev
    |> List.filteri (fun idx _ -> idx < limit)
;;

let recent_completed_turns ~keeper_name ~limit : completed_turn_record list =
  match Hashtbl.find_opt completed_turn_rings keeper_name with
  | None -> recent_completed_turns_from_store ~keeper_name ~limit
  | Some ring ->
    let n = min limit (min ring.count ring_capacity) in
    let result = ref [] in
    for i = 0 to n - 1 do
      let idx = (ring.pos - 1 - i + ring_capacity) mod ring_capacity in
      match ring.buf.(idx) with
      | Some r -> result := !result @ [ r ]
      | None -> ()
    done;
    (match !result with
     | [] -> recent_completed_turns_from_store ~keeper_name ~limit
     | turns -> turns)
;;

module For_testing = struct
  let reset_state () =
    Hashtbl.clear rings;
    Hashtbl.clear completed_turn_rings;
    with_append_queue_lock (fun () -> Stdlib.Queue.clear append_queue);
    Atomic.set async_append_active false;
    Atomic.set append_queue_dropped 0;
    default_store_ref := None
  ;;

  let queued_count = queued_count_for_testing
  let dropped_count = dropped_count_for_testing
  let set_async_append_active v = Atomic.set async_append_active v

  let clear_completed_turn_ring ~keeper_name =
    Hashtbl.remove completed_turn_rings keeper_name
  ;;

  let observe_append_failure = observe_append_failure
end
