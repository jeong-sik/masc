(** Compaction audit: Event_bus subscriber + paired JSONL persistence.
    See {!Keeper_compact_audit} for API docs. *)

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

let legacy_base_dir base_path =
  Filename.concat base_path "data/harness-pre-compact"

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
    ("before_tokens",  `Int    r.before_tokens);
    ("after_tokens",   `Int    r.after_tokens);
    ("tokens_freed",   `Int    r.tokens_freed);
    ("phase_hint",     `String r.phase_hint);
    ("correlation_id", `String r.correlation_id);
    ("run_id",         `String r.run_id);
  ]

let str_field json key =
  match json with
  | `Assoc fs ->
    (match List.assoc_opt key fs with
     | Some (`String s) -> s
     | _ -> "")
  | _ -> ""

let float_field json key =
  match json with
  | `Assoc fs ->
    (match List.assoc_opt key fs with
     | Some (`Float f) -> f
     | Some (`Int n) -> float_of_int n
     | _ -> 0.0)
  | _ -> 0.0

let int_field json key =
  match json with
  | `Assoc fs ->
    (match List.assoc_opt key fs with
     | Some (`Int n) -> n
     | Some (`Float f) -> int_of_float f
     | _ -> 0)
  | _ -> 0

let start_of_json json : start_record option =
  match str_field json "record_type" with
  | "compaction_start" | "pre_compact"  (* legacy support *) ->
    Some {
      compaction_id  = str_field   json "compaction_id";
      ts_unix        = float_field json "ts_unix";
      keeper_name    = str_field   json "keeper_name";
      trigger        = parse_trigger (str_field json "trigger");
      correlation_id = str_field   json "correlation_id";
      run_id         = str_field   json "run_id";
    }
  | _ -> None

let complete_of_json json : complete_record option =
  match str_field json "record_type" with
  | "compaction_complete" ->
    Some {
      compaction_id  = str_field   json "compaction_id";
      ts_unix        = float_field json "ts_unix";
      keeper_name    = str_field   json "keeper_name";
      before_tokens  = int_field   json "before_tokens";
      after_tokens   = int_field   json "after_tokens";
      tokens_freed   = int_field   json "tokens_freed";
      phase_hint     = str_field   json "phase_hint";
      correlation_id = str_field   json "correlation_id";
      run_id         = str_field   json "run_id";
    }
  | _ -> None

(* ── Write API ─────────────────────────────────────────────────── *)

(* Rolling retention: called after each append. Failures are logged
   but do not fail the write. *)
let prune_best_effort base_path ~retention_days =
  match
    Dated_jsonl.prune (get_store base_path) ~days:retention_days
  with
  | _n -> ()
  | exception e ->
    Printf.eprintf
      "keeper_compact_audit: retention prune failed: %s\n%!"
      (Printexc.to_string e)

(* Resolve effective retention from env (override) falling back to default.
   Env var [MASC_COMPACTION_AUDIT_RETENTION_DAYS] is clamped to [1, 365]. *)
let resolve_retention_days ~default =
  match Sys.getenv_opt "MASC_COMPACTION_AUDIT_RETENTION_DAYS" with
  | Some s ->
    (match int_of_string_opt s with
     | Some n when n >= 1 && n <= 365 -> n
     | _ -> default)
  | None -> default

let persist_start ~base_path ~retention_days (r : start_record) :
  (unit, write_error) result =
  let json =
    try Ok (start_to_json r)
    with e -> Error (Serialize_failure (Printexc.to_string e))
  in
  match json with
  | Error _ as e -> e
  | Ok j ->
    (try
       Dated_jsonl.append (get_store base_path) j;
       prune_best_effort base_path ~retention_days;
       Ok ()
     with e -> Error (Io_failure (Printexc.to_string e)))

let persist_complete ~base_path ~retention_days (r : complete_record) :
  (unit, write_error) result =
  let json =
    try Ok (complete_to_json r)
    with e -> Error (Serialize_failure (Printexc.to_string e))
  in
  match json with
  | Error _ as e -> e
  | Ok j ->
    (try
       Dated_jsonl.append (get_store base_path) j;
       prune_best_effort base_path ~retention_days;
       Ok ()
     with e -> Error (Io_failure (Printexc.to_string e)))

(* ── Retention ─────────────────────────────────────────────────── *)

let prune_older_than ~base_path ~retention_days =
  Dated_jsonl.prune (get_store base_path) ~days:retention_days

(* ── Read ──────────────────────────────────────────────────────── *)

let iso_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02d"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday

let read_events ~base_path ~since ~until ?keeper () :
  (row list, write_error) result =
  let filter_keeper rec_keeper =
    match keeper with
    | None -> true
    | Some k -> String.equal rec_keeper k
  in
  let classify json =
    match start_of_json json with
    | Some r when filter_keeper r.keeper_name -> Some (Start r)
    | _ ->
      match complete_of_json json with
      | Some r when filter_keeper r.keeper_name -> Some (Complete r)
      | _ -> None
  in
  let read_dir base_dir =
    let store = Dated_jsonl.create ~base_dir () in
    Dated_jsonl.read_range store
      ~since:(iso_of_unix since) ~until:(iso_of_unix until)
  in
  try
    let new_rows  = List.filter_map classify (read_dir (store_base_dir base_path))  in
    let legacy    =
      if Sys.file_exists (legacy_base_dir base_path)
      then List.filter_map classify (read_dir (legacy_base_dir base_path))
      else []
    in
    let all = new_rows @ legacy in
    let sort_ts = function Start r -> r.ts_unix | Complete r -> r.ts_unix in
    let sorted = List.sort (fun a b -> compare (sort_ts a) (sort_ts b)) all in
    Ok sorted
  with e -> Error (Io_failure (Printexc.to_string e))

(* ── Pairing ───────────────────────────────────────────────────── *)

let pair_events rows : pair_result list =
  (* Group by compaction_id. Pair starts with completes by matching id. *)
  let tbl : (string, row list) Hashtbl.t = Hashtbl.create 32 in
  List.iter
    (fun r ->
      let id = match r with
        | Start s -> s.compaction_id
        | Complete c -> c.compaction_id
      in
      let existing = try Hashtbl.find tbl id with Not_found -> [] in
      Hashtbl.replace tbl id (r :: existing))
    rows;
  let out = ref [] in
  Hashtbl.iter
    (fun _id group ->
      let starts, completes =
        List.partition_map
          (function Start s -> Left s | Complete c -> Right c)
          group
      in
      match starts, completes with
      | [s], [c] -> out := Paired { start = s; complete = c } :: !out
      | [s], []  -> out := Orphan_start s :: !out
      | [],  [c] -> out := Orphan_complete c :: !out
      | _ ->
        (* Shouldn't happen: multiple with same id = ID collision.
           Treat each as individual orphan for visibility. *)
        List.iter (fun s -> out := Orphan_start s    :: !out) starts;
        List.iter (fun c -> out := Orphan_complete c :: !out) completes)
    tbl;
  List.sort
    (fun a b ->
      let ts = function
        | Paired { start; _ } -> start.ts_unix
        | Orphan_start s -> s.ts_unix
        | Orphan_complete c -> c.ts_unix
      in
      compare (ts a) (ts b))
    !out

(* ── Subscriber ────────────────────────────────────────────────── *)

(* Per-keeper pending start: maps keeper_name → (compaction_id, ts_start).
   Needed because OAS events don't carry a compaction-scoped correlation. *)
module Pending = struct
  let tbl : (string, string * float) Hashtbl.t = Hashtbl.create 16
  let mu = Mutex.create ()

  let stash ~keeper_name ~compaction_id ~ts =
    Mutex.lock mu;
    Hashtbl.replace tbl keeper_name (compaction_id, ts);
    Mutex.unlock mu

  let take ~keeper_name =
    Mutex.lock mu;
    let r = Hashtbl.find_opt tbl keeper_name in
    (match r with Some _ -> Hashtbl.remove tbl keeper_name | None -> ());
    Mutex.unlock mu;
    r
end

(* Translate one OAS event into zero or one persist_* effect. *)
let handle_event ~base_path ~retention_days (evt : Agent_sdk.Event_bus.event)
  : unit =
  let { Agent_sdk.Event_bus.correlation_id; run_id; ts } = evt.meta in
  match evt.payload with
  | Agent_sdk.Event_bus.ContextCompactStarted { agent_name; trigger } ->
    let compaction_id = synth_compaction_id ~ts_unix:ts ~keeper_name:agent_name in
    Pending.stash ~keeper_name:agent_name ~compaction_id ~ts;
    let r = {
      compaction_id;
      ts_unix = ts;
      keeper_name = agent_name;
      trigger = parse_trigger trigger;
      correlation_id;
      run_id;
    } in
    (match persist_start ~base_path ~retention_days r with
     | Ok () -> ()
     | Error (Io_failure m | Serialize_failure m) ->
       Printf.eprintf "keeper_compact_audit: persist_start failed: %s\n%!" m)
  | Agent_sdk.Event_bus.ContextCompacted
      { agent_name; before_tokens; after_tokens; phase } ->
    let compaction_id =
      match Pending.take ~keeper_name:agent_name with
      | Some (id, _) -> id
      | None ->
        (* Orphan complete: start was missed (server restart?). Synthesize a
           fresh id so the row is still visible; pairing will flag it. *)
        synth_compaction_id ~ts_unix:ts ~keeper_name:agent_name
    in
    let tokens_freed = Int.max 0 (before_tokens - after_tokens) in
    let r = {
      compaction_id;
      ts_unix = ts;
      keeper_name = agent_name;
      before_tokens;
      after_tokens;
      tokens_freed;
      phase_hint = phase;
      correlation_id;
      run_id;
    } in
    (match persist_complete ~base_path ~retention_days r with
     | Ok () -> ()
     | Error (Io_failure m | Serialize_failure m) ->
       Printf.eprintf "keeper_compact_audit: persist_complete failed: %s\n%!" m)
  | _ -> ()  (* Not a compaction event — ignore. *)

(* Filter: accept only the two compaction payload variants. Keeps
   subscriber's stream tight. *)
let compaction_filter : Agent_sdk.Event_bus.filter = fun evt ->
  match evt.payload with
  | Agent_sdk.Event_bus.ContextCompactStarted _
  | Agent_sdk.Event_bus.ContextCompacted _ -> true
  | _ -> false

let spawn_subscriber
    ~sw ~clock ~base_path ~retention_days
    ?(drain_interval_s = 0.25)
    (bus : Agent_sdk.Event_bus.t) : unit =
  (* Env override of retention_days; default is the caller-supplied value. *)
  let effective_retention =
    resolve_retention_days ~default:retention_days
  in
  let sub =
    Agent_sdk.Event_bus.subscribe ~filter:compaction_filter bus
  in
  Eio.Switch.on_release sw (fun () ->
    Agent_sdk.Event_bus.unsubscribe bus sub);
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      let batch = Agent_sdk.Event_bus.drain sub in
      List.iter
        (handle_event ~base_path ~retention_days:effective_retention)
        batch;
      Eio.Time.sleep clock drain_interval_s;
      loop ()
    in
    loop ())
