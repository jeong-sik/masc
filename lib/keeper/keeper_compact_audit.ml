(** Compaction audit: Event_bus subscriber + paired JSONL persistence.
    See {!Keeper_compact_audit} for API docs. *)

(* tla-lint: file-scope: compaction audit subscriber. The store_ref
   cache and start/complete pair-grouping accumulators are
   observability bookkeeping for the JSONL flush layer; no value
   here feeds back into keeper FSM state. *)

(* ── Types ─────────────────────────────────────────────────────── *)

type trigger =
  | Proactive
  | Emergency
  | Operator
  | Unknown_trigger of string

let parse_trigger = function
  | "proactive"  -> Proactive
  | "emergency"  -> Emergency
  | "operator"   -> Operator
  | other        -> Unknown_trigger other

let trigger_to_string = function
  | Proactive          -> "proactive"
  | Emergency          -> "emergency"
  | Operator           -> "operator"
  | Unknown_trigger s  -> s

type start_record = {
  compaction_id : string;
  ts_unix : float;
  keeper_name : string;
  trigger : trigger;
  correlation_id : string;
  run_id : string;
}

type complete_record = {
  compaction_id : string;
  ts_unix : float;
  keeper_name : string;
  before_tokens : int;
  after_tokens : int;
  tokens_freed : int;
  phase_hint : string;
  correlation_id : string;
  run_id : string;
}

type write_error =
  | Io_failure        of string
  | Serialize_failure of string

type row =
  | Start    of start_record
  | Complete of complete_record

type pair_result =
  | Paired          of { start : start_record; complete : complete_record }
  | Orphan_start    of start_record
  | Orphan_complete of complete_record

(* ── Paths + store ─────────────────────────────────────────────── *)

let store_base_dir base_path =
  Filename.concat base_path "data/harness-compact"

(* One store per process. Keeps Dated_jsonl's mutex alive for append safety. *)
let store_ref : Dated_jsonl.t option ref = ref None

let get_store base_path =
  match !store_ref with
  | Some s when String.equal (Dated_jsonl.base_dir s) (store_base_dir base_path) -> s
  | _ ->
    let s = Dated_jsonl.create ~base_dir:(store_base_dir base_path) () in
    store_ref := Some s;
    s

(* ── ID synthesis ──────────────────────────────────────────────── *)

(* compaction_id = ulid-ish: ts_micros-hex ++ keeper ++ counter *)
let counter = Atomic.make 0

let synth_compaction_id ~ts_unix ~keeper_name =
  let ts_us = Int64.of_float (ts_unix *. 1_000_000.0) in
  let n = Atomic.fetch_and_add counter 1 in
  Printf.sprintf "%Lx-%s-%x" ts_us keeper_name n

(* ── JSON codecs ───────────────────────────────────────────────── *)

let start_to_json (r : start_record) : Yojson.Safe.t =
  `Assoc [
    ("record_type",    `String "compaction_start");
    ("compaction_id",  `String r.compaction_id);
    ("ts_unix",        `Float  r.ts_unix);
    ("keeper_name",    `String r.keeper_name);
    ("trigger",        `String (trigger_to_string r.trigger));
    ("correlation_id", `String r.correlation_id);
    ("run_id",         `String r.run_id);
  ]

let complete_to_json (r : complete_record) : Yojson.Safe.t =
  `Assoc [
    ("record_type",    `String "compaction_complete");
    ("compaction_id",  `String r.compaction_id);
    ("ts_unix",        `Float  r.ts_unix);
    ("keeper_name",    `String r.keeper_name);
    ("before_tokens",  `Int  r.before_tokens);
    ("after_tokens",   `Int  r.after_tokens);
    ("tokens_freed",   `Int  r.tokens_freed);
    ("phase_hint",     `String r.phase_hint);
    ("correlation_id", `String r.correlation_id);
    ("run_id",         `String r.run_id);
  ]

let row_to_json = function
  | Start r    -> start_to_json r
  | Complete r -> complete_to_json r

(* ── Persistence ───────────────────────────────────────────────── *)

let write_one store row =
  let json = row_to_json row in
  Dated_jsonl.append store (Yojson.Safe.to_string json)

(* ── Pairing ───────────────────────────────────────────────────── *)

(* In-memory pairing buffer. We group start/complete by compaction_id. *)
let pairing_buffer : (string, row) Hashtbl.t = Hashtbl.create 1024

let register_start store ~rec: (r : start_record) =
  Hashtbl.add pairing_buffer r.compaction_id (Start r);
  write_one store (Start r)

let register_complete store ~rec: (r : complete_record) =
  match Hashtbl.find_opt pairing_buffer r.compaction_id with
  | Some (Start s) ->
      Hashtbl.remove pairing_buffer r.compaction_id;
      write_one store (Complete r);
      Some (Paired { start = s; complete = r })
  | Some (Complete _) ->
      (* Duplicate complete — log but don't fail *)
      write_one store (Complete r);
      None
  | None ->
      (* Orphan complete — store for later pairing *)
      Hashtbl.add pairing_buffer r.compaction_id (Complete r);
      write_one store (Complete r);
      None

(* ── Flush + cleanup ───────────────────────────────────────────── *)

let flush_orphans store =
  Hashtbl.iter (fun _id row ->
    match row with
    | Start r -> write_one store (Start r)
    | Complete r -> write_one store (Complete r)
  ) pairing_buffer;
  Hashtbl.clear pairing_buffer

(* ── Public API ────────────────────────────────────────────────── *)

let start_compaction ~base_path ~keeper_name ~trigger ~correlation_id ~run_id =
  let ts = Unix.time () in
  let compaction_id = synth_compaction_id ~ts_unix:ts ~keeper_name in
  let store = get_store base_path in
  let rec = {
    compaction_id; ts_unix = ts; keeper_name; trigger;
    correlation_id; run_id;
  } in
  register_start store ~rec;
  compaction_id

let complete_compaction ~base_path ~keeper_name ~compaction_id
    ~before_tokens ~after_tokens ~phase_hint ~correlation_id ~run_id =
  let ts = Unix.time () in
  let tokens_freed = before_tokens - after_tokens in
  let store = get_store base_path in
  let rec = {
    compaction_id; ts_unix = ts; keeper_name;
    before_tokens; after_tokens; tokens_freed;
    phase_hint; correlation_id; run_id;
  } in
  register_complete store ~rec

(* ── Event Bus Integration (Phase 4) ───────────────────────────── *)

let () =
  (* Register compaction events as decay triggers for cognitive gravity *)
  let open Cognitive_gravity_event_bus in
  let handler (event : decay_event) =
    (* When compaction completes, emit decay events for stale facts *)
    List.iter (fun fact_id ->
      match event.trigger with
      | TurnElapsed { age; min_age } ->
          if age > min_age then
            (* Fact is stale, emit decay event *)
            ()
      | NoNewMentions { turns; min_idle } ->
          if turns > min_idle then
            (* Fact has no new mentions, emit decay event *)
            ()
      | _ -> ()
    ) event.target_fact_ids
  in
  register_trigger (TurnElapsed { age = 100; min_age = 50 }) ~handler