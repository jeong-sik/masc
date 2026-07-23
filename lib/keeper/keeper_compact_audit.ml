(** MASC compaction audit: paired JSONL persistence.
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

(* One store per process. Keeps Dated_jsonl's mutex alive for append safety.
   Stored under Atomic.t so concurrent fibers/domains do not race on the lazy
   initialisation of the store handle. *)
let store_ref : Dated_jsonl.t option Atomic.t = Atomic.make None

let get_store base_path =
  let expected_dir = store_base_dir base_path in
  let rec ensure () =
    match Atomic.get store_ref with
    | Some s when String.equal (Dated_jsonl.base_dir s) expected_dir -> s
    | old ->
      let s = Dated_jsonl.create ~base_dir:expected_dir () in
      if Atomic.compare_and_set store_ref old (Some s) then s else ensure ()
  in
  ensure ()

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
  | "compaction_start" ->
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
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string CompactAuditFailures)
      ~labels:[("keeper", "global"); ("site", Keeper_compact_audit_failure_site.(to_label Retention_prune))]
      ();
    Log.Keeper.warn
      "keeper_compact_audit: retention prune failed: %s"
      (Printexc.to_string e)

(* Resolve effective retention from env (override) falling back to default.
   Env var [MASC_COMPACTION_AUDIT_RETENTION_DAYS] is accepted iff parsed
   as integer in [1, 3650] (1 day .. ~10 years). The returned variant
   discriminates between the four resolution outcomes so the caller can
   emit a Otel_metric_store counter + warn log on operator misconfiguration.
   See {!Keeper_compact_audit_retention_outcome}. *)
let retention_min_days = 1
let retention_max_days = 3650

let resolve_retention_outcome ~default :
  Keeper_compact_audit_retention_outcome.t =
  let open Keeper_compact_audit_retention_outcome in
  match Sys.getenv_opt "MASC_COMPACTION_AUDIT_RETENTION_DAYS" with
  | None -> Unset_default default
  | Some raw ->
    (match int_of_string_opt (String.trim raw) with
     | None -> Parse_error { raw; default_used = default }
     | Some n when n >= retention_min_days && n <= retention_max_days ->
       Parsed_ok n
     | Some n -> Out_of_range { raw; parsed = n; default_used = default })
;;

(* Extract the effective retention day count from an outcome — the
   default is substituted on every non-[Parsed_ok] variant, so the
   runtime behaviour matches the legacy [resolve_retention_days]. *)
let effective_days_of_outcome
    (outcome : Keeper_compact_audit_retention_outcome.t) =
  let open Keeper_compact_audit_retention_outcome in
  match outcome with
  | Parsed_ok n -> n
  | Unset_default n -> n
  | Parse_error { default_used; _ } -> default_used
  | Out_of_range { default_used; _ } -> default_used
;;

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
    let all = List.filter_map classify (read_dir (store_base_dir base_path)) in
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
      let existing = Hashtbl.find_opt tbl id |> Option.value ~default:[] in
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

module For_testing = struct
  let resolve_retention_outcome = resolve_retention_outcome
end
