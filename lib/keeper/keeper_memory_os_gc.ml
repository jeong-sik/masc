(** Keeper_memory_os_gc — deterministic garbage collection for stale facts.

    The GC reads all facts from a keeper's JSONL fact file, scores each
    fact using [Policy.score_fact], applies [Policy.decide_retention],
    filters TTL-expired facts, deduplicates by claim (keeping the
    highest-scored fact per cluster), and writes the surviving set
    back atomically.

    Design properties:
    - Deterministic: no LLM calls, no embeddings
    - Offline: runs locally in the keeper process
    - Safe: writes via temp-file + rename (write_file_atomically)
    - Idempotent: running twice produces the same result
    - No-force: only [Discard] and [ReferenceOnly] verdicts are evicted *)

open Keeper_memory_os_types
open Keeper_memory_os_policy
module Io = Keeper_memory_os_io

(** GC result statistics. *)
type gc_report = {
  total_input : int;        (** facts read from disk *)
  ttl_expired : int;        (** facts with valid_until < now *)
  verdict_discarded : int;   (** Decide_retention → Discard *)
  dedup_removed : int;      (** lower-scored duplicates *)
  written : int;            (** facts written back *)
}
[@@deriving yojson, show]

let empty_report = {
  total_input = 0; ttl_expired = 0; verdict_discarded = 0;
  dedup_removed = 0; written = 0;
}

(** Check if a fact's TTL has expired. *)
let ttl_expired ~now (f : fact) =
  match f.valid_until with
  | None -> false
  | Some t -> now > t

(** Score a fact and apply retention verdict. *)
let score_and_verdict ~now (f : fact) =
  let score = score_fact ~now f in
  let verdict = decide_retention score in
  (f, score, verdict)

(** Should this fact survive? *)
let should_keep (_, _, verdict) =
  match verdict with
  | KeepVerbatim | Summarize -> true
  | ReferenceOnly | Discard -> false

(** Deduplicate by claim (case-insensitive): keep highest-scored fact. *)
let dedup_by_claim scored =
  let tbl : (string, fact * float * retention_verdict) Hashtbl.t =
    Hashtbl.create 64
  in
  List.iter (fun item ->
    let (f, score, verdict) = item in
    let key = String.lowercase_ascii f.claim in
    match Hashtbl.find_opt tbl key with
    | None -> Hashtbl.add tbl key item
    | Some (_, existing_score, _) when score > existing_score ->
      Hashtbl.replace tbl key item
    | Some _ -> ()  (* keep existing higher-scored fact *)
  ) scored;
  Hashtbl.fold (fun _ v acc -> v :: acc) tbl []

(** Run GC on a single keeper's fact file.

    Returns [Some report] if GC ran (even if no facts were removed).
    Returns [None] if the fact file does not exist. *)
let run_gc ~keeper_id ~now =
  let path = Io.facts_path ~keeper_id in
  if not (Sys.file_exists path)
  then None
  else begin
    let lines = Io.read_all_jsonl path in
    (* Parse facts, skip malformed lines. *)
    let facts = List.filter_map (fun line ->
      match Yojson.Safe.from_string line with
      | json -> (
        match fact_of_json json with
        | Ok f -> Some f
        | Error _ -> None  (* skip malformed *)
      )
    ) lines in
    let total = List.length facts in
    (* Filter TTL-expired facts. *)
    let (live, expired) = List.partition (fun f -> not (ttl_expired ~now f)) facts in
    let n_expired = List.length expired in
    (* Score and apply retention verdict. *)
    let scored = List.map (score_and_verdict ~now) live in
    let (kept_by_verdict, discarded) = List.partition should_keep scored in
    let n_discarded = List.length discarded in
    (* Deduplicate by claim. *)
    let deduped = dedup_by_claim kept_by_verdict in
    let n_deduped = List.length kept_by_verdict - List.length deduped in
    (* Write back surviving facts atomically. *)
    let json_lines = List.map (fun (f, _, _) -> fact_to_json f) deduped in
    let content =
      json_lines
      |> List.map Yojson.Safe.to_string
      |> String.concat "\n"
    in
    Io.write_file_atomically path content;
    let report = {
      total_input = total;
      ttl_expired = n_expired;
      verdict_discarded = n_discarded;
      dedup_removed = n_deduped;
      written = List.length deduped;
    } in
    Some report
  end
;;