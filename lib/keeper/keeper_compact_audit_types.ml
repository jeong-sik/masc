(** Keeper_compact_audit_types — types, state, ID synthesis, and JSON
    codecs extracted from [Keeper_compact_audit] (609 LoC).
    Write API, retention, and subscriber logic remain in the parent.
    @since Keeper 500-line decomposition *)

(* tla-lint: file-scope: compaction audit types and JSON codecs.
   The store_ref cache and counter are observability bookkeeping
   for the JSONL flush layer; no value here feeds back into
   keeper FSM state. *)

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

