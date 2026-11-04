(** Keeper Decision Audit — Forensics-only decision trail.

    Abstract record prevents trust calculations from consuming
    forensics data. Ring buffer + periodic JSONL flush.

    @since Decision Audit Phase A2 (#6232) *)

(* tla-lint: file-scope: forensics ring buffer + accumulator. The
   ring's pos/count/unflushed counters are observability bookkeeping
   for the JSONL flush, not state-machine state observed by the
   keeper FSM. The header explicitly notes the abstract record
   prevents trust calculations from consuming forensics data. *)

(* ================================================================ *)
(* Cached observability configuration                               *)
(* ================================================================ *)

(* These values are read from tests and module-init code that can run before an
   Eio scheduler exists, so they cannot depend on Eio.Lazy.  Use a
   cross-context Atomic+Stdlib.Mutex memo rather than Stdlib.Lazy.force. *)
let resolve_cached cache mu compute =
  match Atomic.get cache with
  | Some value -> value
  | None ->
      Mutex.protect mu (fun () ->
        match Atomic.get cache with
        | Some value -> value
        | None ->
            let value = compute () in
            Atomic.set cache (Some value);
            value)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type decision_record = {
  cycle_id : string;
  keeper_name : string;
  turn_verdict : Keeper_world_observation.turn_verdict;
  wall_clock : float;
  tool_diversity_entropy : float option;
}

let make ~cycle_id ~keeper_name
    ~turn_verdict ~wall_clock
    ?tool_diversity_entropy () =
  { cycle_id; keeper_name;
    turn_verdict; wall_clock;
    tool_diversity_entropy }

(* ================================================================ *)
(* Serialization                                                    *)
(* ================================================================ *)

let to_json (r : decision_record) : Yojson.Safe.t =
  `Assoc [
    "cycle_id", `String r.cycle_id;
    "keeper_name", `String r.keeper_name;
    "turn_verdict", `String
      (match r.turn_verdict with
       | Keeper_world_observation.Run _ -> "run"
       | Keeper_world_observation.Skip _ -> "skip");
    "turn_reasons", `List
      (List.map (fun s -> `String s)
         (Keeper_world_observation.verdict_reasons_to_strings r.turn_verdict));
    "wall_clock", `Float r.wall_clock;
    "tool_diversity_entropy", (match r.tool_diversity_entropy with
      | Some e -> `Float e
      | None -> `Null);
  ]

(* ================================================================ *)
(* Ring buffer                                                      *)
(* ================================================================ *)

let ring_capacity_cached : int option Atomic.t = Atomic.make None
let ring_capacity_mu = Mutex.create ()

let ring_capacity () =
  max 1
    (resolve_cached ring_capacity_cached ring_capacity_mu (fun () ->
         Env_config_core.get_int ~default:50
           "MASC_DECISION_AUDIT_RING_CAPACITY"))

type ring = {
  buf : decision_record option array;
  mutable pos : int;
  mutable count : int;
  mutable unflushed : int;
  mutable last_flush_ts : float;
}

let rings : (string, ring) Hashtbl.t = Hashtbl.create 8

let flush_interval_sec () = 60.0

let flush_batch_size () = 10

let get_or_create_ring name =
  match Hashtbl.find_opt rings name with
  | Some r -> r
  | None ->
    let cap = ring_capacity () in
    let r = { buf = Array.make cap None; pos = 0; count = 0;
              unflushed = 0; last_flush_ts = Time_compat.now () } in
    Hashtbl.replace rings name r;
    r

(* Observability for ring overflow.  When [ring.unflushed = cap] at
   append time, the slot we are about to write into already holds an
   unflushed decision_record — the flush loop has not kept up with
   the append rate and a forensic record is being silently dropped.
   Without this counter, ring overflow was invisible: [unflushed]
   stayed pegged at [cap] and no Otel_metric_store signal fired.  Closes
   the silent data-loss gap noted in
   .tmp/memory-compacting-analysis.html (decision_audit ring
   overflow). *)
let () =
  Otel_metric_store.register_counter
    ~name:Keeper_metrics.(to_string DecisionAuditRingOverflows)
    ~help:
      "Total [Keeper_decision_audit.append] events where the ring \
       buffer slot being overwritten still held an unflushed \
       record.  Each increment is one lost decision_record.  \
       Non-zero counts mean flush_batch_size / flush_interval_sec \
       is below the decision-emission rate."
    ()
;;

let append ~keeper_name (rec_ : decision_record) =
  let ring = get_or_create_ring keeper_name in
  let cap = Array.length ring.buf in
  if ring.unflushed >= cap then
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string DecisionAuditRingOverflows)
      ~labels:[("keeper", keeper_name)]
      ();
  ring.buf.(ring.pos mod cap) <- Some rec_;
  ring.pos <- (ring.pos + 1) mod cap;
  ring.count <- min (ring.count + 1) cap;
  ring.unflushed <- min (ring.unflushed + 1) cap

(* ================================================================ *)
(* JSONL flush                                                      *)
(* ================================================================ *)

(* The day-file layout ([<base_dir>/YYYY-MM/DD.jsonl]) belongs to
   [Dated_jsonl], and the same module prunes this store through
   [Server_runtime_startup_maintenance.prune_shared_jsonl_stores]. Writing
   through the store is what keeps the directory name and the pruner's cutoff
   on one calendar: both resolve the day from the same clock, so a name never
   denotes a different day to the reader than it did to the writer. *)
(* Keyed by resolved [base_dir]: a base_path or keeper-name change resolves to
   a different directory and therefore takes a distinct store rather than
   reusing one bound to the previous path. *)
let audit_stores : (string, Dated_jsonl.t) Hashtbl.t = Hashtbl.create 8

let store_for ~base_path ~keeper_name =
  let location =
    Dated_jsonl.Store.decision_audit
      (Dated_jsonl.Store.root_of_base_path ~base_path)
      ~keeper_dirname:(Keeper_alerting_path.sanitize_keeper_name keeper_name)
  in
  let base_dir = Dated_jsonl.Store.dir location in
  match Hashtbl.find_opt audit_stores base_dir with
  | Some store -> store
  | None ->
    let store = Dated_jsonl.open_store location in
    Hashtbl.replace audit_stores base_dir store;
    store

let flush_if_needed ~base_path ~keeper_name =
  match Hashtbl.find_opt rings keeper_name with
    | None -> ()
    | Some ring ->
      let now = Time_compat.now () in
      let should_flush =
        ring.unflushed >= flush_batch_size ()
        || (ring.unflushed > 0
            && now -. ring.last_flush_ts >= flush_interval_sec ())
      in
      if not should_flush then ()
      else begin
        let store = store_for ~base_path ~keeper_name in
        let cap = Array.length ring.buf in
        let start = ((ring.pos - ring.unflushed) mod cap + cap) mod cap in
        let pending =
          let rec gather i acc =
            if i >= ring.unflushed then List.rev acc
            else
              let idx = (start + i) mod cap in
              match ring.buf.(idx) with
              | Some r -> gather (i + 1) (to_json r :: acc)
              | None -> gather (i + 1) acc
          in
          gather 0 []
        in
        (try
          List.iter (Dated_jsonl.append store) pending;
          ring.unflushed <- 0
        with Eio.Cancel.Cancelled _ as e -> raise e
           | e ->
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string DecisionAuditFlushFailures)
               ~labels:[("keeper", keeper_name)]
               ();
             Log.Keeper.warn "decision_audit flush failed: %s" (Printexc.to_string e));
        ring.last_flush_ts <- now
      end
