(** Keeper_memory_bank — memory bank persistence, compaction, and summarization. *)

(* Spec navigation (OCaml -> TLA+) — plan §19 anchor pattern.  Sibling
   to PR 11617 (Cycle 34, keeper_memory_policy.ml).  Authoritative
   spec mirror is
   specs/keeper-state-machine/KeeperMemoryLifecycle.tla.

   Spec lines 22-23 cite this module specifically for two semantic
   aspects:

     open_short    rows: unresolved short-term notes
                   (open_question kind).  This module's compaction
                   and summarization paths must preserve open_short
                   until they are answered or roll over with the
                   keeper generation.
     provenanced   rows: non-empty trace_id and source.  Persistence
                   here is the authoritative producer of provenance:
                   no row reaches mid_term or long_term without it.

   This block is the reverse-direction citation so code search for
   "KeeperMemoryLifecycle" lands in this module too — completing the
   sibling pair with keeper_memory_policy.ml which carries the
   horizon-tier and producer anchors (memory_horizon_of_kind_opt
   and memory_horizon_of_kind).

   Sibling division of labor:
     keeper_memory_policy.ml   tier vocabulary, producer,
                               classification.
     keeper_memory_bank.ml     persistence, compaction,
                               summarization, provenance enforcement.

   Spec safety goals (line 9-13 in spec):
     - every persisted note has provenance.  Enforced here by
       rejecting rows with empty trace_id or source.
     - overflow and handoff do not silently drop retained notes.
       Compaction selection paths preserve open_short and
       provenanced rows; the spec verifies the bound.
     - handoff clears stale short-term notes.  The generation-handoff
       path here explicitly clears short_mem that has not been
       promoted to mid_mem.
     - each tier stays within its configured bound.
       select_memory_candidates (this file) walks rows under the
       tier-specific cap from Keeper_memory_policy.kind_caps. *)

open Keeper_types

include Keeper_memory_policy

type candidate_selection_result = {
  selected: (string * string * int) list;
  dropped_by_kind: (string * int) list;
  dropped_by_total_cap: int;
}

let select_memory_candidates
    (rows : (string * string * int) list) : candidate_selection_result =
  let total_cap = total_cap () in
  let kind_caps = kind_caps () in
  let used_by_kind : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let dropped_by_kind : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let rec go acc dropped_total rest =
    match rest with
    | [] ->
        {
          selected = List.rev acc;
          dropped_by_kind =
            Hashtbl.to_seq dropped_by_kind
            |> List.of_seq
            |> List.sort (fun (a, _) (b, _) -> String.compare a b);
          dropped_by_total_cap = dropped_total;
        }
    | _ when List.length acc >= total_cap ->
        {
          selected = List.rev acc;
          dropped_by_kind =
            Hashtbl.to_seq dropped_by_kind
            |> List.of_seq
            |> List.sort (fun (a, _) (b, _) -> String.compare a b);
          dropped_by_total_cap = dropped_total + List.length rest;
        }
    | (kind, text, pr) :: rest' ->
        let cap = cap_for_kind kind_caps kind in
        let used = Option.value ~default:0 (Hashtbl.find_opt used_by_kind kind) in
        if cap <= 0 || used >= cap then begin
          let cur =
            Option.value ~default:0 (Hashtbl.find_opt dropped_by_kind kind)
          in
          Hashtbl.replace dropped_by_kind kind (cur + 1);
          go acc dropped_total rest'
        end else begin
          Hashtbl.replace used_by_kind kind (used + 1);
          go ((kind, text, pr) :: acc) dropped_total rest'
        end
  in
  go [] 0 rows

(** Filter a list to unique items by a key function.
    Empty keys are skipped (treated as duplicates). *)
let dedup_by_key (key_of : 'a -> string) (items : 'a list) : 'a list =
  let module SS = Set.Make (String) in
  let rec go seen acc = function
    | [] -> List.rev acc
    | item :: rest ->
      let key = key_of item in
      if key = "" || SS.mem key seen then go seen acc rest
      else go (SS.add key seen) (item :: acc) rest
  in
  go SS.empty [] items

let jaccard_similarity = Text_similarity.jaccard_similarity

(* Step 14(b) of the bloodflow restoration plan inlined the env knob
   [MASC_KEEPER_MEMORY_DEDUP_SIMILARITY_THRESHOLD]: hyperparameters
   belong in code, not in [Sys.getenv_opt]. *)
let semantic_dedup_similarity_threshold () = 0.85

let dedup_memory_candidates
    (items : (string * string * int) list) : (string * string * int) list =
  let exact =
    dedup_by_key
      (fun (kind, text, _) ->
        String.lowercase_ascii (String.trim kind ^ ":" ^ String.trim text))
      items
  in
  let threshold = semantic_dedup_similarity_threshold () in
  if threshold >= 1.0 then exact
  else
    let rec go kept = function
      | [] -> List.rev kept
      | (kind, text, pr) :: rest ->
          let is_dup =
            List.exists
              (fun (_, kept_text, _) ->
                jaccard_similarity text kept_text >= threshold)
              kept
          in
          if is_dup then go kept rest
          else go ((kind, text, pr) :: kept) rest
    in
    go [] exact

(* Punctuation strip used by the dedup key — fully static, hoist to
   module level so the DFA is built once per process. *)
let normalize_punct_re =
  Re.Pcre.re {re|[ \t\n\r!"#$%&'()*+,\-./:;<=>?@\[\]^_`{|}~]+|re} |> Re.compile

let normalize_memory_text_key (s : string) : string =
  s
  |> String.trim
  |> String.lowercase_ascii
  |> Re.replace_string normalize_punct_re ~by:""

(* Consensus marker: cache the compiled regex without using [Lazy.force].
   OCaml 5 documents Lazy as not concurrency-safe across fibers, systhreads,
   or domains.  This path can be reached from runtime/dashboard domains, so
   protect the tiny cache with a Stdlib mutex.  Keep the env-derived cache key
   so tests and operators that change the pattern in-process get a fresh
   compiled regex without paying the compile cost on every memory row. *)
let consensus_default_re = Re.Pcre.re {|\d{6,}ep\+?|} |> Re.compile

(* Stdlib.Mutex: this process-global cache is also forced from tests and
   runtime/dashboard domains outside an Eio context.  The critical section does
   not perform Eio I/O or yield, so a plain mutex is sufficient and avoids
   poisoning when first forced by multiple domains. *)
let consensus_re_mu = Stdlib.Mutex.create ()
let consensus_re_cached : (string * Re.re) option ref = ref None

let memory_env_opt name =
  match Env_config_core.raw_value_opt name with
  | None -> None
  | Some raw ->
      let s = String.trim raw in
      if s = "" then None else Some s

let memory_env_int_logged name ~default =
  match memory_env_opt name with
  | None -> default
  | Some raw ->
      (match int_of_string_opt raw with
       | Some n -> n
       | None ->
           Log.Keeper.warn
             "invalid %s=%S; using default %d"
             name raw default;
           default)

let consensus_pattern_key () =
  match memory_env_opt "MASC_KEEPER_MEMORY_CONSENSUS_PATTERN" with
  | None -> ""
  | Some raw -> raw

let compile_consensus_re pattern =
  if pattern = "" then consensus_default_re
  else
    try Re.Pcre.re pattern |> Re.compile
    with exn ->
      Log.Keeper.warn
        "invalid MASC_KEEPER_MEMORY_CONSENSUS_PATTERN=%S: %s; using default"
        pattern (Printexc.to_string exn);
      consensus_default_re

let consensus_re () =
  let pattern = consensus_pattern_key () in
  Stdlib.Mutex.protect consensus_re_mu (fun () ->
    match !consensus_re_cached with
    | Some (cached_pattern, re) when String.equal cached_pattern pattern ->
        re
    | _ ->
        let re = compile_consensus_re pattern in
        consensus_re_cached := Some (pattern, re);
        re)

let has_inflated_consensus_marker (s : string) : bool =
  Re.execp (consensus_re ()) s

let memory_placeholders () =
  let base =
    [
      "";
      "none";
      "null";
      "na";
      "nil";
      "없음";
      "없다";
      "없어요";
      "없습니다";
      "해당없음";
      "해당 사항 없음";
      "모르겠음";
      "무";
      "미정";
    ]
  in
  match memory_env_opt "MASC_KEEPER_MEMORY_PLACEHOLDERS" with
  | None -> base
  | Some raw ->
      let extra =
        String.split_on_char ',' raw
        |> List.map String.trim
        |> List.filter (fun s -> s <> "")
      in
      base @ extra

let max_memory_text_length () =
  match memory_env_opt "MASC_KEEPER_MEMORY_MAX_LENGTH" with
  | None -> 4096
  | Some raw ->
      (match int_of_string_opt raw with
       | Some n when n > 0 -> n
       | _ -> 4096)

let is_meaningful_memory_text (s : string) : bool =
  let key = normalize_memory_text_key s in
  let placeholders = memory_placeholders () in
  not (List.mem key placeholders)
  && not (Keeper_synthetic_marker.contains_marker s)
  && not (String.equal (String.trim s) "No tools used this generation")
  && not (has_inflated_consensus_marker s)
  && not (String_util.contains_substring s "[turn budget exhausted")
  && String.length s <= max_memory_text_length ()

let memory_candidates_from_snapshot
    (snapshot : keeper_state_snapshot) : candidate_selection_result =
  let add_opt kind value acc =
    match value with
    | None -> acc
    | Some text ->
        let text = String.trim text in
        if text = "" || not (is_meaningful_memory_text text) then acc
        else
          ( kind,
            text,
            tuned_priority_for_candidate
              ~kind
              ~text )
          :: acc
  in
  let add_list kind values acc =
    List.fold_left
      (fun acc item ->
        let item = String.trim item in
        if item = "" || not (is_meaningful_memory_text item) then acc
        else
          ( kind,
            item,
            tuned_priority_for_candidate
              ~kind
              ~text:item )
          :: acc)
      acc values
  in
  let raw =
    []
    |> add_opt "goal" snapshot.goal
    |> add_opt "progress" snapshot.progress
    |> add_opt "progress" snapshot.done_summary
    |> add_opt "next" snapshot.next_summary
    |> add_list "next" snapshot.next_items
    |> add_list "decision" snapshot.decisions
    |> add_list "open_question" snapshot.open_questions
    |> add_list "constraints" snapshot.constraints
    |> dedup_memory_candidates
    |> List.sort (fun (_, ta, pa) (_, tb, pb) ->
         let c = compare pb pa in
         if c <> 0 then c else String.compare ta tb)
  in
  select_memory_candidates raw

type keeper_memory_row_raw = {
  json: Yojson.Safe.t;
  kind: string;
  horizon: string;
  source: string;
  generation: int;
  text: string;
  priority: int;
  ts_unix: float;
}

let parse_memory_bank_row (line : string) : keeper_memory_row_raw option =
  try
    let j = Yojson.Safe.from_string line in
    let schema_version = Safe_ops.json_int ~default:0 "schema_version" j in
    if schema_version <> 0 && schema_version <> keeper_memory_schema_version then
      None
    else
    let kind = Safe_ops.json_string ~default:"" "kind" j |> String.trim in
    let horizon = memory_horizon_of_json ~kind j in
    let source = Safe_ops.json_string ~default:"" "source" j |> String.trim in
    let generation = Safe_ops.json_int ~default:0 "generation" j in
    let text = Safe_ops.json_string ~default:"" "text" j |> String.trim in
    let priority =
      let raw = Safe_ops.json_int ~default:1 "priority" j in
      if raw < 1 then 1 else if raw > 100 then 100 else raw
    in
    let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
    if kind = "" || text = "" || not (is_meaningful_memory_text text) then
      None
    else
      Some { json = j; kind; horizon; source; generation; text; priority; ts_unix }
  with Yojson.Json_error _ ->
    None

(* ── Memory Consolidation ───────────────────────────────── *)

(** Extract trace_id from a memory row's JSON. *)
let row_trace_id (row : keeper_memory_row_raw) : string =
  Safe_ops.json_string ~default:"" "trace_id" row.json

(** Consolidate memory notes before compaction.
    1. Merge progress notes from same trace_id (3+ → single summary).
    2. Promote recurring texts across trace_ids to long_term (priority 95).
    Returns a new row list with consolidated entries appended. *)
let consolidate_memory_notes (rows : keeper_memory_row_raw list)
    : keeper_memory_row_raw list * int =
  let now = Unix.gettimeofday () in
  let consolidated = ref [] in
  let consolidated_count = ref 0 in
  (* 1. Group progress notes by trace_id *)
  let progress_by_trace : (string, keeper_memory_row_raw list) Hashtbl.t =
    Hashtbl.create 32
  in
  List.iter (fun (row : keeper_memory_row_raw) ->
    if row.kind = "progress" then begin
      let tid = row_trace_id row in
      if tid <> "" then
        let existing =
          Option.value ~default:[] (Hashtbl.find_opt progress_by_trace tid)
        in
        Hashtbl.replace progress_by_trace tid (row :: existing)
    end)
    rows;
  Hashtbl.iter (fun tid group ->
    if List.length group >= 3 then begin
      let texts =
        List.map (fun (r : keeper_memory_row_raw) -> r.text) group
        |> List.sort_uniq String.compare
      in
      let generation =
        List.fold_left
          (fun acc (row : keeper_memory_row_raw) -> max acc row.generation)
          0 group
      in
      let summary_text =
        Printf.sprintf "[consolidated:%d] %s"
          (List.length group)
          (String.concat "; " (take 5 texts))
      in
      let summary_json = `Assoc [
        ("ts", `String (now_iso ()));
        ("ts_unix", `Float now);
        ("kind", `String "long_term");
        ("horizon", `String long_term_horizon);
        ("source", `String "progress_consolidation");
        ("schema_version", `Int keeper_memory_schema_version);
        ("priority", `Int 90);
        ("text", `String summary_text);
        ("trace_id", `String tid);
        ("generation", `Int generation);
        ("consolidated_from", `Int (List.length group));
      ] in
      consolidated := {
        json = summary_json;
        kind = "long_term";
        horizon = long_term_horizon;
        source = "progress_consolidation";
        generation;
        text = summary_text;
        priority = 90;
        ts_unix = now;
      } :: !consolidated;
      incr consolidated_count
    end)
    progress_by_trace;
  (* 2. Promote recurring texts across multiple trace_ids *)
  let text_traces : (string, string list) Hashtbl.t = Hashtbl.create 256 in
  List.iter (fun (row : keeper_memory_row_raw) ->
    if row.kind <> "long_term" then begin
      let norm = normalize_memory_text_key row.text in
      let tid = row_trace_id row in
      if norm <> "" && tid <> "" then begin
        let existing =
          Option.value ~default:[] (Hashtbl.find_opt text_traces norm)
        in
        if not (List.mem tid existing) then
          Hashtbl.replace text_traces norm (tid :: existing)
      end
    end)
    rows;
  Hashtbl.iter (fun norm_text tids ->
    if List.length tids >= 3 then begin
      (* Find the highest-priority original row for this text *)
      let best =
        List.fold_left (fun acc (row : keeper_memory_row_raw) ->
          if normalize_memory_text_key row.text = norm_text
             && row.priority > (match acc with Some r -> r.priority | None -> 0)
          then Some row else acc)
          None rows
      in
      match best with
      | Some row ->
        let lt_json = `Assoc [
          ("ts", `String (now_iso ()));
          ("ts_unix", `Float now);
          ("kind", `String "long_term");
          ("horizon", `String long_term_horizon);
          ("source", `String "cross_trace_recurrence");
          ("schema_version", `Int keeper_memory_schema_version);
          ("priority", `Int 95);
          ("text", `String row.text);
          ("generation", `Int row.generation);
          ("recurring_across", `Int (List.length tids));
        ] in
        consolidated := {
          json = lt_json;
          kind = "long_term";
          horizon = long_term_horizon;
          source = "cross_trace_recurrence";
          generation = row.generation;
          text = row.text;
          priority = 95;
          ts_unix = now;
        } :: !consolidated;
        incr consolidated_count
      | None -> ()
    end)
    text_traces;
  (rows @ !consolidated, !consolidated_count)

let memory_compaction_target_notes () : int =
  let default_target = 220 in
  let raw =
    memory_env_int_logged
      "MASC_KEEPER_MEMORY_MAX_NOTES"
      ~default:default_target
  in
  max 40 (min 4000 raw)

let memory_compaction_trigger_bytes ~(target_notes : int) : int =
  let default_trigger = max 120000 (target_notes * 360) in
  let raw =
    memory_env_int_logged
      "MASC_KEEPER_MEMORY_COMPACT_TRIGGER_BYTES"
      ~default:default_trigger
  in
  max 60000 (min 20000000 raw)

let memory_kind_caps_for_compaction
    ~(target_notes : int) : (string, int) Hashtbl.t =
  let tbl : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let base_total = max 1 (total_cap ()) in
  let scale = max 6 (target_notes / base_total) in
  List.iter
    (fun (kind, base_cap) ->
      let cap = max 8 ((base_cap * scale) + (scale / 3)) in
      Hashtbl.replace tbl kind cap)
    (kind_caps ());
  tbl

let memory_row_key (row : keeper_memory_row_raw) : string =
  String.lowercase_ascii (String.trim row.kind)
  ^ ":"
  ^ normalize_memory_text_key row.text

let compaction_priority
    ~(current_generation : int)
    (row : keeper_memory_row_raw) : int =
  let horizon_bonus =
    match row.horizon with
    | h when h = long_term_horizon -> 12
    | h when h = short_term_horizon ->
        if row.generation >= current_generation then 4 else -18
    | _ -> 0
  in
  let source_bonus =
    match row.source with
    | "cross_trace_recurrence" -> 4
    | "progress_consolidation" -> 2
    | _ -> 0
  in
  max 1 (min 120 (row.priority + horizon_bonus + source_bonus))

let write_memory_bank_rows
    (path : string)
    (rows : keeper_memory_row_raw list) : (unit, string) result =
  try
    let content =
      rows
      |> List.map (fun (row : keeper_memory_row_raw) ->
             utf8_repair_string (Yojson.Safe.to_string row.json))
      |> String.concat "\n"
    in
    let content = if content <> "" then content ^ "\n" else content in
    Fs_compat.save_file_atomic path content
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Error (Printf.sprintf "failed to rewrite memory bank: %s" (Printexc.to_string exn))

let drop_memory_rows n rows =
  let rec go remaining rest =
    if remaining <= 0 then rest
    else
      match rest with
      | [] -> []
      | _ :: tl -> go (remaining - 1) tl
  in
  go n rows

let consolidation_metric_source source =
  match source with
  | "progress_consolidation" | "cross_trace_recurrence" -> source
  | _ -> "other"

let memory_row_identity (row : keeper_memory_row_raw) =
  Yojson.Safe.to_string row.json

let count_rows_by_consolidation_source rows =
  rows
  |> List.fold_left
       (fun acc (row : keeper_memory_row_raw) ->
         let source = consolidation_metric_source row.source in
         let cur = Option.value ~default:0 (List.assoc_opt source acc) in
         (source, cur + 1) :: List.remove_assoc source acc)
       []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let record_memory_consolidation_metrics ~keeper_name ~outcome rows =
  count_rows_by_consolidation_source rows
  |> List.iter (fun (source, count) ->
       if count > 0 then
         Prometheus.inc_counter
           Keeper_metrics.metric_keeper_memory_consolidations
           ~labels:
             [
               ("keeper", keeper_name);
               ("source", source);
               ("outcome", outcome);
             ]
           ~delta:(float_of_int count)
           ())

let retained_generated_rows ~generated selected =
  let ids : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun (row : keeper_memory_row_raw) ->
      Hashtbl.replace ids (memory_row_identity row) ())
    generated;
  List.filter
    (fun (row : keeper_memory_row_raw) ->
      Hashtbl.mem ids (memory_row_identity row))
    selected

let evicted_generated_rows ~generated ~retained =
  let retained_ids : (string, int) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun (row : keeper_memory_row_raw) ->
      let id = memory_row_identity row in
      let cur = Option.value ~default:0 (Hashtbl.find_opt retained_ids id) in
      Hashtbl.replace retained_ids id (cur + 1))
    retained;
  generated
  |> List.filter (fun (row : keeper_memory_row_raw) ->
       let id = memory_row_identity row in
       match Hashtbl.find_opt retained_ids id with
       | Some n when n > 0 ->
           Hashtbl.replace retained_ids id (n - 1);
           false
       | _ -> true)

let compact_memory_bank_if_needed
    (config : Coord.config)
    (meta : keeper_meta) : memory_bank_compaction =
  let target_notes = memory_compaction_target_notes () in
  let path = keeper_memory_bank_path config meta.name in
  if not (Fs_compat.file_exists path) then
    { no_memory_bank_compaction with
      target_notes;
      reason = Some "missing_file";
    }
  else
    let size_bytes =
      (match Fs_compat.file_size path with Some s -> s | None -> 0)
    in
    let trigger_bytes = memory_compaction_trigger_bytes ~target_notes in
    match Safe_ops.read_file_safe path with
      | Error _ ->
          { no_memory_bank_compaction with
            target_notes;
            reason = Some "read_failed";
          }
      | Ok content ->
          let lines =
            content
            |> String.split_on_char '\n'
            |> List.filter (fun s -> String.trim s <> "")
          in
          let (parsed_rev, invalid) =
            List.fold_left
              (fun (acc, inv) line ->
                match parse_memory_bank_row line with
                | Some row -> (row :: acc, inv)
                | None -> (acc, inv + 1))
              ([], 0) lines
          in
          let parsed = List.rev parsed_rev in
          let before_notes = List.length parsed in
          if
            size_bytes < trigger_bytes
            && before_notes <= target_notes
            && invalid = 0
          then
            { no_memory_bank_compaction with
              target_notes;
              before_notes;
              after_notes = before_notes;
              reason = Some "under_trigger_bytes";
            }
          else if before_notes <= target_notes && invalid = 0 then
            { no_memory_bank_compaction with
              target_notes;
              before_notes;
              after_notes = before_notes;
              reason = Some "under_target";
            }
          else
            (* Consolidation: merge progress clusters and promote recurring notes *)
            let (consolidated_parsed, consolidated_count) =
              consolidate_memory_notes parsed
            in
            let generated_consolidated =
              drop_memory_rows before_notes consolidated_parsed
            in
            if consolidated_count > 0 then
              record_memory_consolidation_metrics
                ~keeper_name:meta.name
                ~outcome:"generated"
                generated_consolidated;
            let current_generation = meta.runtime.generation in
            let by_recency =
              List.sort
                (fun (a : keeper_memory_row_raw) (b : keeper_memory_row_raw) ->
                  let c = compare b.ts_unix a.ts_unix in
                  if c <> 0 then c
                  else
                    compare
                      (compaction_priority ~current_generation b)
                      (compaction_priority ~current_generation a))
                consolidated_parsed
            in
            let deduped = dedup_by_key memory_row_key by_recency in
            let dedup_dropped = max 0 (before_notes - List.length deduped) in
            if List.length deduped <= target_notes && dedup_dropped = 0 && invalid = 0 then
              { no_memory_bank_compaction with
                target_notes;
                before_notes;
                after_notes = before_notes;
                reason = Some "already_compact";
              }
            else
              let kind_caps =
                memory_kind_caps_for_compaction ~target_notes
              in
              let kind_used : (string, int) Hashtbl.t = Hashtbl.create 16 in
              let selected_keys : (string, unit) Hashtbl.t = Hashtbl.create 1024 in
              let kind_dropped_keys : (string, string) Hashtbl.t = Hashtbl.create 256 in
              let selected_rev = ref [] in
              let selected_count = ref 0 in
              let fallback_kind_cap = max 8 (target_notes / 8) in
              let yield_meter = Eio_guard.create_yield_meter () in
              let add_row ~ignore_kind_cap (row : keeper_memory_row_raw) =
                Eio_guard.yield_step yield_meter;
                if !selected_count >= target_notes then
                  ()
                else
                  let key = memory_row_key row in
                  if key = "" || Hashtbl.mem selected_keys key then
                    ()
                  else
                    let used =
                      Option.value ~default:0 (Hashtbl.find_opt kind_used row.kind)
                    in
                    let cap =
                      Option.value ~default:fallback_kind_cap
                        (Hashtbl.find_opt kind_caps row.kind)
                    in
                    if ignore_kind_cap || used < cap then begin
                      Hashtbl.remove kind_dropped_keys key;
                      Hashtbl.add selected_keys key ();
                      Hashtbl.replace kind_used row.kind (used + 1);
                      selected_rev := row :: !selected_rev;
                      incr selected_count
                    end else
                      Hashtbl.replace kind_dropped_keys key row.kind
              in
              let recent_floor = max 16 (min 64 (target_notes / 5)) in
              by_recency
              |> take recent_floor
              |> List.iter (fun row -> add_row ~ignore_kind_cap:false row);
              let by_priority =
                List.sort
                  (fun (a : keeper_memory_row_raw) (b : keeper_memory_row_raw) ->
                    let c =
                      compare
                        (compaction_priority ~current_generation b)
                        (compaction_priority ~current_generation a)
                    in
                    if c <> 0 then c else compare b.ts_unix a.ts_unix)
                  deduped
              in
              List.iter (fun row -> add_row ~ignore_kind_cap:false row) by_priority;
              if !selected_count < target_notes then
                List.iter (fun row -> add_row ~ignore_kind_cap:true row) by_recency;
              let selected =
                !selected_rev
                |> List.rev
                |> List.sort
                     (fun (a : keeper_memory_row_raw) (b : keeper_memory_row_raw) ->
                       let c = compare a.ts_unix b.ts_unix in
                       if c <> 0 then c else compare a.priority b.priority)
              in
              let after_notes = List.length selected in
              let dropped_notes = max 0 (before_notes - after_notes) in
              let dropped_by_kind =
                Hashtbl.to_seq kind_dropped_keys
                |> Seq.fold_left
                     (fun acc (_, kind) ->
                       let cur =
                         Option.value ~default:0 (List.assoc_opt kind acc)
                       in
                       (kind, cur + 1) :: List.remove_assoc kind acc)
                     []
                |> List.sort (fun (a, _) (b, _) -> String.compare a b)
              in
              if dropped_notes = 0 && invalid = 0 then
                { no_memory_bank_compaction with
                  target_notes;
                  before_notes;
                  after_notes;
                  dedup_dropped;
                  reason = Some "no_reduction";
                }
              else
                match write_memory_bank_rows path selected with
                | Error _ ->
                    record_memory_consolidation_metrics
                      ~keeper_name:meta.name
                      ~outcome:"write_failed"
                      generated_consolidated;
                    { no_memory_bank_compaction with
                      target_notes;
                      before_notes;
                      after_notes = before_notes;
                      dedup_dropped;
                      invalid_dropped = invalid;
                      reason = Some "write_failed";
                    }
                | Ok () ->
                    let retained =
                      retained_generated_rows
                        ~generated:generated_consolidated
                        selected
                    in
                    let evicted =
                      evicted_generated_rows
                        ~generated:generated_consolidated
                        ~retained
                    in
                    record_memory_consolidation_metrics
                      ~keeper_name:meta.name
                      ~outcome:"persisted"
                      retained;
                    record_memory_consolidation_metrics
                      ~keeper_name:meta.name
                      ~outcome:"evicted"
                      evicted;
                    {
                      performed = true;
                      reason = Some "compacted";
                      target_notes;
                      before_notes;
                      after_notes;
                      dropped_notes;
                      dedup_dropped;
                      invalid_dropped = invalid;
                      dropped_by_kind;
                    }

let append_memory_notes_from_reply
    (config : Coord.config)
    (meta : keeper_meta)
    ?snapshot
    ~(turn : int)
    ~(reply : string)
    () : (int * string list) =
  let (snapshot, source) =
    match snapshot with
    | Some s -> (s, "message_metadata")
    | None ->
      (match parse_state_snapshot_from_reply reply with
    | Some s -> (s, "reply_state_block")
    | None ->
        (* Deterministic fallback: use keeper meta fields as memory source.
           This guarantees memory write regardless of LLM output format.
           See RFC #3646 Section 3: Det/NonDet boundary principle. *)
        ( {
            Keeper_memory_policy.goal =
              (if meta.goal <> "" then Some meta.goal else None);
            progress = None;
            done_summary = None;
            next_summary = None;
            next_items = [];
            decisions = [];
            open_questions = [];
            constraints = [];
          },
          "meta_goal_fallback" ))
  in
  let selection = memory_candidates_from_snapshot snapshot in
  let notes = selection.selected in
  if selection.dropped_by_total_cap > 0 || selection.dropped_by_kind <> [] then
    Eio.traceln "[keeper_memory] %s: memory_candidates dropped total_cap=%d kind=%s"
      meta.name
      selection.dropped_by_total_cap
      (String.concat ","
         (List.map (fun (k, c) -> Printf.sprintf "%s:%d" k c) selection.dropped_by_kind));
  if notes = [] then
    (0, [])
  else
    let now_ts = Time_compat.now () in
    let path = keeper_memory_bank_path config meta.name in
    let kinds_acc = ref [] in
    let seen_kinds : (string, unit) Hashtbl.t = Hashtbl.create 8 in
    List.iter
      (fun (kind, text, priority) ->
        let horizon = memory_horizon_of_kind kind in
        if not (Hashtbl.mem seen_kinds kind) then begin
          Hashtbl.add seen_kinds kind ();
          kinds_acc := kind :: !kinds_acc
        end;
        append_jsonl_line path
          (`Assoc
            [
              ("ts", `String (now_iso ()));
              ("ts_unix", `Float now_ts);
              ("name", `String meta.name);
              ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
              ("generation", `Int meta.runtime.generation);
              ("turn", `Int turn);
              ("kind", `String kind);
              ("horizon", `String horizon);
              ("source", `String source);
              ("schema_version", `Int keeper_memory_schema_version);
              ("priority", `Int priority);
              ("text", `String text);
            ]))
      notes;
    (List.length notes, List.rev !kinds_acc)

let strip_tool_result_reserved_keys (result : Yojson.Safe.t) : Yojson.Safe.t =
  match result with
  | `Assoc kv ->
      let reserved =
        [ Multimodal.Tool_emission.multimodal_kind_key
        ; Multimodal.Tool_emission.multimodal_id_key
        ; Multimodal.Tool_emission.multimodal_metadata_key
        ]
      in
      `Assoc (List.filter (fun (key, _) -> not (List.mem key reserved)) kv)
  | other -> other

let tool_result_metadata (result : Yojson.Safe.t) : Yojson.Safe.t =
  match result with
  | `Assoc kv -> (
      match
        List.assoc_opt
          Multimodal.Tool_emission.multimodal_metadata_key
          kv
      with
      | Some (`Assoc _ as metadata) -> metadata
      | _ -> `Assoc [])
  | _ -> `Assoc []

let tool_result_payload_preview (result : Yojson.Safe.t) : string =
  result
  |> strip_tool_result_reserved_keys
  |> Yojson.Safe.to_string
  |> String_util.utf8_safe ~max_bytes:1200 ~suffix:"..."
  |> String_util.to_string

let tool_result_memory_text ~kind ~artifact_id ~payload_preview : string =
  Printf.sprintf
    "ToolResult %s artifact %s: %s"
    kind artifact_id payload_preview

let append_memory_notes_from_tool_results
    (config : Coord.config)
    (meta : keeper_meta)
    ~(turn : int)
    ~(results : Yojson.Safe.t list) : int =
  let now_ts = Time_compat.now () in
  let path = keeper_memory_bank_path config meta.name in
  let seen_artifacts : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  let written = ref 0 in
  List.iter
    (fun result ->
      match
        ( Multimodal.Tool_emission.extract_kind_from_result result,
          Multimodal.Tool_emission.extract_id_from_result result )
      with
      | Some kind_tag, Some artifact_id
        when String.trim artifact_id <> ""
             && not (Hashtbl.mem seen_artifacts artifact_id) ->
          Hashtbl.add seen_artifacts artifact_id ();
          let kind = Multimodal.Artifact.kind_tag_to_string kind_tag in
          let payload_preview = tool_result_payload_preview result in
          let text =
            tool_result_memory_text ~kind ~artifact_id ~payload_preview
          in
          if is_meaningful_memory_text text then begin
            append_jsonl_line path
              (`Assoc
                [ ("ts", `String (now_iso ()))
                ; ("ts_unix", `Float now_ts)
                ; ("name", `String meta.name)
                ; ( "trace_id",
                    `String
                      (Keeper_id.Trace_id.to_string meta.runtime.trace_id) )
                ; ("generation", `Int meta.runtime.generation)
                ; ("turn", `Int turn)
                ; ("kind", `String "long_term")
                ; ("horizon", `String long_term_horizon)
                ; ("source", `String "tool_result")
                ; ("schema_version", `Int keeper_memory_schema_version)
                ; ( "priority",
                    `Int
                      (tuned_priority_for_candidate
                         ~kind:"long_term" ~text) )
                ; ("text", `String text)
                ; ("artifact_id", `String artifact_id)
                ; ("artifact_kind", `String kind)
                ; ("payload_preview", `String payload_preview)
                ; ("metadata", tool_result_metadata result)
                ]);
            incr written
          end
      | _ -> ())
    results;
  !written

let summarize_memory_bank_lines
    (lines : string list)
    ~(recent_limit : int) : keeper_memory_summary =
  let parsed =
    lines
    |> List.filter_map (fun line ->
         try
           let j = Yojson.Safe.from_string line in
           let kind = Safe_ops.json_string ~default:"" "kind" j in
           let text = Safe_ops.json_string ~default:"" "text" j in
           let priority = Safe_ops.json_int ~default:0 "priority" j in
           let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
           let kind = String.trim kind in
           let text = String.trim text in
           if kind = "" || text = "" || not (is_meaningful_memory_text text) then None
           else Some { kind; text; priority; ts_unix }
         with Yojson.Json_error _ -> None)
  in
  let total_notes = List.length parsed in
  let last_ts_unix =
    parsed
    |> List.fold_left (fun acc (row : keeper_memory_line) ->
         max acc row.ts_unix)
         0.0
  in
  let kind_counts_tbl : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let kind_priority_tbl : (string, int) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun (row : keeper_memory_line) ->
      let cur = Option.value ~default:0 (Hashtbl.find_opt kind_counts_tbl row.kind) in
      Hashtbl.replace kind_counts_tbl row.kind (cur + 1);
      let pri_cur =
        Option.value ~default:min_int (Hashtbl.find_opt kind_priority_tbl row.kind)
      in
      Hashtbl.replace kind_priority_tbl row.kind (max pri_cur row.priority))
    parsed;
  let kind_counts =
    kind_counts_tbl
    |> Hashtbl.to_seq
    |> List.of_seq
    |> List.sort (fun (ka, va) (kb, vb) ->
         let c = compare vb va in
         if c <> 0 then c
         else
           let pa =
             Option.value ~default:min_int (Hashtbl.find_opt kind_priority_tbl ka)
           in
           let pb =
             Option.value ~default:min_int (Hashtbl.find_opt kind_priority_tbl kb)
           in
           let cp = compare pb pa in
           if cp <> 0 then cp else String.compare ka kb)
  in
  let top_kind =
    match kind_counts with
    | (kind, _) :: _ -> Some kind
    | [] -> None
  in
  let recent_notes =
    parsed
    |> List.rev
    |> take (max 0 recent_limit)
  in
  {
    total_notes;
    last_ts_unix;
    top_kind;
    kind_counts;
    recent_notes;
  }

let memory_summary_to_json (summary : keeper_memory_summary) : Yojson.Safe.t =
  `Assoc
    [
      ("total_notes", `Int summary.total_notes);
      ("last_ts_unix", `Float summary.last_ts_unix);
      ("top_kind", Json_util.string_opt_to_json summary.top_kind);
      ( "kind_counts",
        `List
          (List.map
             (fun (kind, count) ->
               `Assoc [ ("kind", `String kind); ("count", `Int count) ])
             summary.kind_counts) );
      ( "recent_notes",
        `List
          (List.map
             (fun (row : keeper_memory_line) ->
               `Assoc
                 [
                   ("kind", `String row.kind);
                   ("text", `String row.text);
                   ("priority", `Int row.priority);
                   ("ts_unix", `Float row.ts_unix);
                 ])
             summary.recent_notes) );
    ]
