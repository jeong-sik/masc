(** Keeper_memory_bank â memory bank persistence, compaction, and summarization. *)

(* Spec navigation (OCaml -> TLA+) â plan Â§19 anchor pattern.  Sibling
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
   "KeeperMemoryLifecycle" lands in this module too â completing the
   sibling pair with keeper_memory_policy.ml which carries the
   horizon-tier and producer anchor (memory_horizon_of_kind_opt).

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

(* Selection pipeline, dedup, consensus detection, and lock
   infrastructure extracted to [Keeper_memory_bank_selection]
   (godfile decomp). *)
include Keeper_memory_bank_selection

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(* RFC-0020 — type the memory-bank provenance carrier. [source] is persisted as
   a free string in memory_bank.jsonl by several producers; parsing it into a
   closed variant on read lets the priority/metric/preview consumers match
   exhaustively instead of comparing string literals. [Other] carries a
   provenance string written by an out-of-band producer so the wire value still
   round-trips (parse-don't-validate). *)
type memory_row_source =
  | Progress_consolidation
  | Cross_trace_recurrence
  | Tool_result
  | Voice_output
  | Other of string

let memory_row_source_of_string = function
  | "progress_consolidation" -> Progress_consolidation
  | "cross_trace_recurrence" -> Cross_trace_recurrence
  | "tool_result" -> Tool_result
  | "voice_output" -> Voice_output
  | other -> Other other

let memory_row_source_to_string = function
  | Progress_consolidation -> "progress_consolidation"
  | Cross_trace_recurrence -> "cross_trace_recurrence"
  | Tool_result -> "tool_result"
  | Voice_output -> "voice_output"
  | Other other -> other

type keeper_memory_row_raw = {
  json: Yojson.Safe.t;
  kind: string;
  horizon: string;
  source: memory_row_source;
  generation: int;
  text: string;
  priority: int;
  ts_unix: float;
}

type memory_bank_row_parse_error =
  | Malformed_json of string
  | Non_object_json of string
  | Schema_version_mismatch of { expected : int; actual : int option }
  | Unknown_kind of string
  | Missing_horizon
  | Horizon_mismatch of { kind : string; expected : string; actual : string }
  | Missing_source
  | Missing_trace_id
  | Empty_text
  | Non_meaningful_text

type memory_consolidation_summarizer =
  trace_id:string -> texts:string list -> string option

let memory_horizon_of_kind_exn kind =
  match memory_horizon_of_kind_opt kind with
  | Some horizon -> horizon
  | None -> invalid_arg ("unknown memory kind: " ^ kind)

let memory_bank_row_parse_error_kind = function
  | Malformed_json _ -> "malformed_json"
  | Non_object_json _ -> "non_object_json"
  | Schema_version_mismatch _ -> "schema_version_mismatch"
  | Unknown_kind _ -> "unknown_kind"
  | Missing_horizon -> "missing_horizon"
  | Horizon_mismatch _ -> "horizon_mismatch"
  | Missing_source -> "missing_source"
  | Missing_trace_id -> "missing_trace_id"
  | Empty_text -> "empty_text"
  | Non_meaningful_text -> "non_meaningful_text"

let memory_bank_row_parse_error_message = function
  | Malformed_json message -> message
  | Non_object_json kind ->
    Printf.sprintf "memory bank row must be object, got %s" kind
  | Schema_version_mismatch { expected; actual } ->
    Printf.sprintf
      "memory bank schema_version mismatch: expected %d, got %s"
      expected
      (match actual with
       | Some version -> string_of_int version
       | None -> "missing_or_non_integer")
  | Unknown_kind kind ->
    Printf.sprintf "memory bank row has unknown kind %S" kind
  | Missing_horizon -> "memory bank row missing canonical horizon"
  | Horizon_mismatch { kind; expected; actual } ->
    Printf.sprintf
      "memory bank row horizon mismatch for kind %S: expected %S, got %S"
      kind
      expected
      actual
  | Missing_source -> "memory bank row missing source"
  | Missing_trace_id -> "memory bank row missing trace_id"
  | Empty_text -> "memory bank row missing text"
  | Non_meaningful_text -> "memory bank row text is not meaningful"

let memory_bank_row_parse_error_to_json ~source ?keeper ?path ~line_index error =
  `Assoc
    ([ "source", `String source
     ; "line_index", `Int line_index
     ; "error_kind", `String (memory_bank_row_parse_error_kind error)
     ; "message", `String (memory_bank_row_parse_error_message error)
     ]
     @
     (match keeper with
      | Some keeper_name -> [ "keeper", `String keeper_name ]
      | None -> [])
     @
     match path with
     | Some source_path -> [ "path", `String source_path ]
     | None -> [])

let parse_memory_bank_row_result (line : string) :
    (keeper_memory_row_raw, memory_bank_row_parse_error) result =
  match Yojson.Safe.from_string line with
  | exception Yojson.Json_error message -> Error (Malformed_json message)
  | `Assoc _ as j ->
    let schema_version = Safe_ops.json_int_opt "schema_version" j in
    if schema_version <> Some keeper_memory_schema_version then
      Error
        (Schema_version_mismatch
           { expected = keeper_memory_schema_version; actual = schema_version })
    else (
    let kind = Safe_ops.json_string ~default:"" "kind" j |> String.trim in
    let horizon = memory_horizon_of_json_opt j in
    let expected_horizon = memory_horizon_of_kind_opt kind in
    let source_raw = Safe_ops.json_string ~default:"" "source" j |> String.trim in
    let trace_id = Safe_ops.json_string ~default:"" "trace_id" j |> String.trim in
    let generation = Safe_ops.json_int ~default:0 "generation" j in
    let text = Safe_ops.json_string ~default:"" "text" j |> String.trim in
    let priority =
      let raw = Safe_ops.json_int ~default:1 "priority" j in
      if raw < 1 then 1 else if raw > 100 then 100 else raw
    in
    let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
    match expected_horizon, horizon, source_raw, trace_id, text with
    | None, _, _, _, _ -> Error (Unknown_kind kind)
    | Some _, None, _, _, _ -> Error Missing_horizon
    | Some expected_horizon, Some horizon, _, _, _
      when not (String.equal expected_horizon horizon) ->
      Error (Horizon_mismatch { kind; expected = expected_horizon; actual = horizon })
    | Some _, Some _, "", _, _ -> Error Missing_source
    | Some _, Some _, _, "", _ -> Error Missing_trace_id
    | Some _, Some _, _, _, "" -> Error Empty_text
    | Some _, Some _, _, _, _ when not (is_meaningful_memory_text text) ->
      Error Non_meaningful_text
    | Some _, Some horizon, _, _, _ ->
      Ok
        { json = j
        ; kind
        ; horizon
        ; source = memory_row_source_of_string source_raw
        ; generation
        ; text
        ; priority
        ; ts_unix
        })
  | other -> Error (Non_object_json (Json_util.kind_name other))

let parse_memory_bank_row (line : string) : keeper_memory_row_raw option =
  match parse_memory_bank_row_result line with
  | Ok row -> Some row
  | Error (_error : memory_bank_row_parse_error) -> None

let parse_memory_bank_content content =
  let lines =
    content
    |> String.split_on_char '\n'
    |> List.filter (fun s -> String.trim s <> "")
  in
  let parsed_rev, invalid =
    List.fold_left
      (fun (acc, inv) line ->
         match parse_memory_bank_row_result line with
         | Ok row -> row :: acc, inv
         | Error (_error : memory_bank_row_parse_error) -> acc, inv + 1)
      ([], 0)
      lines
  in
  List.rev parsed_rev, invalid
;;

(* Detect schema-mismatch rows among the invalid lines. A row is a schema mismatch
   when it parses as JSON and carries an explicit [schema_version] that differs
   from the current version. Rows without [schema_version] or non-JSON garbage are
   ordinary parse failures, not schema mismatches. *)
let has_schema_mismatch content =
  let current = keeper_memory_schema_version in
  content
  |> String.split_on_char '\n'
  |> List.exists (fun raw ->
    let line = String.trim raw in
    if String.equal line ""
    then false
    else (
      match Yojson.Safe.from_string line with
      | exception Yojson.Json_error _ -> false
      | `Assoc fields ->
        (match Safe_ops.json_int_opt "schema_version" (`Assoc fields) with
         | Some v when v <> current -> true
         | _ -> false)
      | _ -> false))
;;

(* ── Memory Consolidation ───────────────────────────────── *)

(** Extract trace_id from a memory row's JSON. *)
let row_trace_id (row : keeper_memory_row_raw) : string =
  Safe_ops.json_string ~default:"" "trace_id" row.json

let deterministic_progress_consolidation_summary ~count texts =
  Printf.sprintf "[consolidated:%d] %s"
    count
    (String.concat "; " (take 5 texts))

let sanitize_consolidation_summary text =
  text
  |> Keeper_text_processing.strip_state_blocks_text
  |> String.trim
  |> String_util.utf8_safe ~max_bytes:(max_memory_text_length ()) ~suffix:"..."
  |> String_util.to_string

let progress_consolidation_summary ?summarizer ~trace_id ~count texts =
  let fallback = deterministic_progress_consolidation_summary ~count texts in
  match summarizer with
  | Some summarize when memory_llm_summary_enabled () ->
      let summarized =
        try summarize ~trace_id ~texts with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            Log.Keeper.warn
              "memory consolidation summarizer failed for trace_id=%s: %s; using deterministic fallback"
              trace_id
              (Printexc.to_string exn);
            None
      in
      (match summarized with
      | Some candidate ->
          let summary = sanitize_consolidation_summary candidate in
          if summary <> "" && is_meaningful_memory_text summary then
            Printf.sprintf "[consolidated:%d][llm] %s" count summary
          else fallback
      | None -> fallback)
  | _ -> fallback

(** Minimum group size that triggers consolidation, used for both
    same-trace progress merging and cross-trace recurrence promotion.
    Below this floor a "burst" is treated as noise and not promoted to
    long-term storage. *)
let consolidation_min_group_size = 3

(** Priority assigned to consolidated long-term notes synthesized from
    same-trace progress merges.  Lower than {!consolidation_recurrence_priority}
    because a single-trace burst is weaker evidence than recurrence across
    multiple traces. *)
let consolidation_progress_priority = 90

(** Priority assigned to consolidated long-term notes synthesized from
    cross-trace text recurrence (the same normalised text appearing in
    [consolidation_min_group_size]+ distinct traces).  Higher than
    {!consolidation_progress_priority} — recurrence across traces is
    stronger evidence than a within-trace burst. *)
let consolidation_recurrence_priority = 95

(** Consolidate memory notes before compaction.
    1. Merge progress notes from same trace_id ({!consolidation_min_group_size}+
       → single summary at {!consolidation_progress_priority}).
    2. Promote recurring texts across trace_ids to long_term at
       {!consolidation_recurrence_priority}.
    Returns a new row list with consolidated entries appended. *)
let consolidate_memory_notes ?summarizer (rows : keeper_memory_row_raw list)
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
    if List.length group >= consolidation_min_group_size then begin
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
        progress_consolidation_summary ?summarizer ~trace_id:tid
          ~count:(List.length group)
          texts
      in
      let summary_json = `Assoc [
        ("ts", `String (now_iso ()));
        ("ts_unix", `Float now);
        ("kind", `String "long_term");
        ("horizon", `String long_term_horizon);
        ("source", `String (memory_row_source_to_string Progress_consolidation));
        ("schema_version", `Int keeper_memory_schema_version);
        ("priority", `Int consolidation_progress_priority);
        ("text", `String summary_text);
        ("trace_id", `String tid);
        ("generation", `Int generation);
        ("consolidated_from", `Int (List.length group));
      ] in
      consolidated := {
        json = summary_json;
        kind = "long_term";
        horizon = long_term_horizon;
        source = Progress_consolidation;
        generation;
        text = summary_text;
        priority = consolidation_progress_priority;
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
    if List.length tids >= consolidation_min_group_size then begin
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
          ("source", `String (memory_row_source_to_string Cross_trace_recurrence));
          ("schema_version", `Int keeper_memory_schema_version);
          ("priority", `Int consolidation_recurrence_priority);
          ("text", `String row.text);
          (* Carry the representative source row's trace_id. [parse_memory_bank_row]
             rejects rows with an empty trace_id, so omitting it here silently
             purges this promoted long_term note on the next read/compaction.
             [row] is one of the input rows (all passed that parse guard), so
             [row_trace_id row] is non-empty. The note recurred across
             [recurring_across] traces; this records the highest-priority origin. *)
          ("trace_id", `String (row_trace_id row));
          ("generation", `Int row.generation);
          ("recurring_across", `Int (List.length tids));
        ] in
        consolidated := {
          json = lt_json;
          kind = "long_term";
          horizon = long_term_horizon;
          source = Cross_trace_recurrence;
          generation = row.generation;
          text = row.text;
          priority = consolidation_recurrence_priority;
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
    | Cross_trace_recurrence -> 4
    | Progress_consolidation -> 2
    | Tool_result | Voice_output | Other _ -> 0
  in
  max 1 (min 120 (row.priority + horizon_bonus + source_bonus))

let write_memory_bank_rows_unlocked
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

let write_memory_bank_rows path rows =
  with_memory_bank_lock path (fun () -> write_memory_bank_rows_unlocked path rows)
;;

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
  | (Progress_consolidation | Cross_trace_recurrence) as s ->
    memory_row_source_to_string s
  | Tool_result | Voice_output | Other _ -> "other"

let memory_row_identity (row : keeper_memory_row_raw) =
  Yojson.Safe.to_string row.json

let identity_counts rows =
  let counts : (string, int) Hashtbl.t = Hashtbl.create (max 16 (List.length rows)) in
  List.iter
    (fun row ->
       let id = memory_row_identity row in
       let cur = Option.value ~default:0 (Hashtbl.find_opt counts id) in
       Hashtbl.replace counts id (cur + 1))
    rows;
  counts
;;

let consume_identity counts row =
  let id = memory_row_identity row in
  match Hashtbl.find_opt counts id with
  | Some n when n > 1 ->
    Hashtbl.replace counts id (n - 1);
    true
  | Some _ ->
    Hashtbl.remove counts id;
    true
  | None -> false
;;

let rewrite_memory_bank_preserving_concurrent_appends ~path ~base_rows selected =
  with_memory_bank_lock path (fun () ->
    let selected =
      match Safe_ops.read_file_safe path with
      | Error _ -> selected
      | Ok current_content ->
        let current_rows, _invalid = parse_memory_bank_content current_content in
        let base_counts = identity_counts base_rows in
        let concurrent_rows =
          current_rows
          |> List.filter (fun row -> not (consume_identity base_counts row))
        in
        if concurrent_rows = [] then selected else selected @ concurrent_rows
    in
    write_memory_bank_rows_unlocked path selected)
;;

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
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string MemoryConsolidations)
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
    ?summarizer
    (config : Workspace.config)
    (meta : keeper_meta) : memory_bank_compaction =
  let target_notes = memory_compaction_target_notes () in
  let path = Keeper_types_support.keeper_memory_bank_path config meta.name in
  if not (Fs_compat.file_exists path) then
    { no_memory_bank_compaction with
      target_notes;
      source = None;
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
        source = None;
      }
    | Ok content ->
      let parsed, invalid = parse_memory_bank_content content in
      let before_notes = List.length parsed in
      if invalid > 0 && has_schema_mismatch content
      then (
        Log.Keeper.warn
          "memory_bank_compaction: keeper=%s schema mismatch detected; refusing compaction"
          meta.name;
        { no_memory_bank_compaction with
          performed = true;
          target_notes;
          before_notes;
          after_notes = before_notes;
          invalid_dropped = invalid;
          source = Some Memory_bank;
          error = Some Schema_mismatch;
        })
      else if size_bytes < trigger_bytes && before_notes <= target_notes && invalid = 0
      then
        { no_memory_bank_compaction with
          target_notes;
          before_notes;
          after_notes = before_notes;
          source = None;
        }
      else if before_notes <= target_notes && invalid = 0 then
        { no_memory_bank_compaction with
          target_notes;
          before_notes;
          after_notes = before_notes;
          source = None;
        }
      else
        (* Consolidation: merge progress clusters and promote recurring notes *)
        let consolidated_parsed, consolidated_count =
          consolidate_memory_notes ?summarizer parsed
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
        if List.length deduped <= target_notes && dedup_dropped = 0 && invalid = 0
        then
          { no_memory_bank_compaction with
            target_notes;
            before_notes;
            after_notes = before_notes;
            source = None;
          }
        else
          let kind_caps = memory_kind_caps_for_compaction ~target_notes in
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
                  Option.value
                    ~default:fallback_kind_cap
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
            |> List.sort (fun (a : keeper_memory_row_raw) (b : keeper_memory_row_raw) ->
              let c = compare a.ts_unix b.ts_unix in
              if c <> 0 then c else compare a.priority b.priority)
          in
          let after_notes = List.length selected in
          let dropped_notes = max 0 (before_notes - after_notes) in
          let dropped_by_kind =
            Hashtbl.to_seq kind_dropped_keys
            |> Seq.fold_left
                 (fun acc (_, kind) ->
                   let cur = Option.value ~default:0 (List.assoc_opt kind acc) in
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
              source = None;
            }
          else
            match
              rewrite_memory_bank_preserving_concurrent_appends
                ~path
                ~base_rows:parsed
                selected
            with
            | Error msg ->
              record_memory_consolidation_metrics
                ~keeper_name:meta.name
                ~outcome:"write_failed"
                generated_consolidated;
              Otel_metric_store.inc_counter
                Keeper_metrics.(to_string MemoryBankCompactionFailures)
                ~labels:[ "keeper", meta.name; "reason", "write_error" ]
                ();
              Log.Keeper.warn
                "memory_bank_compaction: keeper=%s write failed: %s"
                meta.name
                msg;
              { no_memory_bank_compaction with
                performed = true;
                target_notes;
                before_notes;
                after_notes = before_notes;
                dedup_dropped;
                invalid_dropped = invalid;
                source = Some Memory_bank;
                error = Some (Write_error msg);
              }
            | Ok () ->
              let retained =
                retained_generated_rows ~generated:generated_consolidated selected
              in
              let evicted =
                evicted_generated_rows ~generated:generated_consolidated ~retained
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
                source = Some Memory_bank;
                target_notes;
                before_notes;
                after_notes;
                dropped_notes;
                dedup_dropped;
                invalid_dropped = invalid;
                dropped_by_kind;
                error = None;
              }

let append_memory_notes_from_reply_result
    (config : Workspace.config)
    (meta : keeper_meta)
    ?snapshot
    ?state_snapshot_source
    ~(turn : int)
    ~(reply : string)
    () : ((int * string list), string) result =
  (* [source] is the per-note provenance written to the memory-bank JSONL — a
     separate vocabulary from the turn-cascade [state_snapshot_source]. The
     turn-cascade source (when present) is rendered to its wire string and carries
     its typed synthetic-ness; the internal fallback labels are never synthetic.
     RFC-0242 §3.2: the candidate gate now receives the [is_synthetic] bit, not a
     string to re-classify. *)
  let (snapshot, source, is_synthetic) =
    match snapshot with
    | Some s ->
      (match state_snapshot_source with
       | Some src ->
         ( s,
           Keeper_memory_policy.state_snapshot_source_to_string src,
           Keeper_memory_policy.state_snapshot_source_is_synthetic src )
       | None -> (s, "message_metadata", false))
    | None ->
      (match parse_state_snapshot_from_reply reply with
    | Some s -> (s, "reply_state_block", false)
    | None ->
        (* Deterministic fallback: use keeper meta fields as memory source.
           This guarantees memory write regardless of LLM output format.
           See RFC #3646 Section 3: Det/NonDet boundary principle. *)
        ( {
            Keeper_memory_policy.priority = None;
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
          "meta_goal_fallback", false ))
  in
  let selection =
    memory_candidates_from_snapshot_gated ~is_synthetic snapshot
  in
  let notes = selection.selected in
  if selection.dropped_by_total_cap > 0 || selection.dropped_by_kind <> [] then
    Log.Keeper.warn
      ~keeper_name:meta.name
      "memory_candidates dropped total_cap=%d kind=%s"
      selection.dropped_by_total_cap
      (String.concat ","
         (List.map (fun (k, c) -> Printf.sprintf "%s:%d" k c) selection.dropped_by_kind));
  if notes = [] then
    Ok (0, [])
  else
    let now_ts = Time_compat.now () in
    let path = Keeper_types_support.keeper_memory_bank_path config meta.name in
    let seen_kinds : (string, unit) Hashtbl.t = Hashtbl.create 8 in
    with_memory_bank_lock path (fun () ->
      let rec loop kinds_acc written = function
        | [] -> Ok (written, List.rev kinds_acc)
        | (kind, text, priority) :: rest ->
          let horizon = memory_horizon_of_kind_exn kind in
          let is_new_kind = not (Hashtbl.mem seen_kinds kind) in
          let json =
            `Assoc
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
              ]
          in
          (match Keeper_types_support.append_jsonl_line_result path json with
           | Error msg -> Error msg
           | Ok () ->
             let kinds_acc =
               if is_new_kind then begin
                 Hashtbl.add seen_kinds kind ();
                 kind :: kinds_acc
               end
               else kinds_acc
             in
             loop kinds_acc (written + 1) rest)
      in
      loop [] 0 notes)

let append_memory_notes_from_reply config meta ?snapshot ?state_snapshot_source ~turn ~reply () =
  match
    append_memory_notes_from_reply_result config meta ?snapshot ?state_snapshot_source ~turn
      ~reply ()
  with
  | Ok value -> value
  | Error msg -> raise (Sys_error msg)

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

let append_memory_notes_from_tool_results_result
    (config : Workspace.config)
    (meta : keeper_meta)
    ~(turn : int)
    ~(results : Yojson.Safe.t list) : (int, string) result =
  let now_ts = Time_compat.now () in
  let path = Keeper_types_support.keeper_memory_bank_path config meta.name in
  let seen_artifacts : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  with_memory_bank_lock path (fun () ->
    let rec loop written = function
      | [] -> Ok written
      | result :: rest -> (
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
          let text = tool_result_memory_text ~kind ~artifact_id ~payload_preview in
          if is_meaningful_memory_text text then
            let json =
              `Assoc
                [ ("ts", `String (now_iso ()))
                ; ("ts_unix", `Float now_ts)
                ; ("name", `String meta.name)
                ; ( "trace_id",
                    `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id) )
                ; ("generation", `Int meta.runtime.generation)
                ; ("turn", `Int turn)
                ; ("kind", `String "long_term")
                ; ("horizon", `String long_term_horizon)
                ; ("source", `String (memory_row_source_to_string Tool_result))
                ; ("schema_version", `Int keeper_memory_schema_version)
                ; ("priority", `Int (tuned_priority_for_candidate ~kind:"long_term" ~text))
                ; ("text", `String text)
                ; ("artifact_id", `String artifact_id)
                ; ("artifact_kind", `String kind)
                ; ("payload_preview", `String payload_preview)
                ; ("metadata", tool_result_metadata result)
                ]
            in
            (match Keeper_types_support.append_jsonl_line_result path json with
             | Error msg -> Error msg
             | Ok () -> loop (written + 1) rest)
          else loop written rest
        | _ -> loop written rest)
    in
    loop 0 results)

let append_memory_notes_from_tool_results config meta ~turn ~results =
  match append_memory_notes_from_tool_results_result config meta ~turn ~results with
  | Ok written -> written
  | Error msg -> raise (Sys_error msg)

let append_voice_output
    (config : Workspace.config)
    (meta : keeper_meta)
    ?provider
    ~(execution : string)
    ~(voice_priority : int)
    ~(turn : int)
    ~(message : string)
    () : (int, string) result =
  let text = String.trim message in
  if text = "" || not (is_meaningful_memory_text text)
  then Ok 0
  else (
    let kind = "progress" in
    let now_ts = Time_compat.now () in
    let path = Keeper_types_support.keeper_memory_bank_path config meta.name in
    let optional_provider =
      match provider |> Option.map String.trim with
      | Some value when value <> "" -> [ "provider", `String value ]
      | _ -> []
    in
    let fields =
      [ "ts", `String (now_iso ())
      ; "ts_unix", `Float now_ts
      ; "name", `String meta.name
      ; "trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      ; "generation", `Int meta.runtime.generation
      ; "turn", `Int turn
      ; "kind", `String kind
      ; "horizon", `String short_term_horizon
      ; "source", `String (memory_row_source_to_string Voice_output)
      ; "schema_version", `Int keeper_memory_schema_version
      ; "priority", `Int (tuned_priority_for_candidate ~kind ~text)
      ; "text", `String text
      ; "tool", `String "keeper_voice_speak"
      ; "execution", `String execution
      ; "voice_priority", `Int (max 1 voice_priority)
      ]
      @ optional_provider
    in
    match
      with_memory_bank_lock path (fun () ->
        Keeper_types_support.append_jsonl_line_result path (`Assoc fields))
    with
    | Ok () -> Ok 1
    | Error msg -> Error msg)

let summarize_memory_bank_lines
    (lines : string list)
    ~(recent_limit : int) : keeper_memory_summary =
  let raw_rows = lines |> List.filter_map parse_memory_bank_row in
  let parsed =
    raw_rows
    |> List.map (fun (row : keeper_memory_row_raw) ->
         { kind = row.kind
         ; text = row.text
         ; priority = row.priority
         ; ts_unix = row.ts_unix
         })
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
  (* Voice output is self-generated speech.  If it surfaces as the most
     recent note, the model treats its own spoken text as a fresh user
     request and re-enters the voice tool in a self-echo loop (2026-06-14
     sangsu voice repeat incident).  Keep the row in the bank for search,
     but exclude it from the auto-injected recent-note preview. *)
  let recent_notes =
    raw_rows
    |> List.filter (fun (row : keeper_memory_row_raw) ->
         match row.source with
         | Voice_output -> false
         | Progress_consolidation | Cross_trace_recurrence | Tool_result | Other _ -> true)
    |> List.map (fun (row : keeper_memory_row_raw) ->
         { kind = row.kind
         ; text = row.text
         ; priority = row.priority
         ; ts_unix = row.ts_unix
         })
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
