(** Keeper_memory_bank — memory bank persistence, compaction, and summarization. *)

open Keeper_types

include Keeper_memory_policy

let select_memory_candidates
    (rows : (string * string * int) list) : (string * string * int) list =
  let total_cap = total_cap () in
  let kind_caps = kind_caps () in
  let used_by_kind : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let rec go acc = function
    | [] -> List.rev acc
    | _ when List.length acc >= total_cap -> List.rev acc
    | (kind, text, pr) :: rest ->
        let cap = cap_for_kind kind_caps kind in
        let used = Option.value ~default:0 (Hashtbl.find_opt used_by_kind kind) in
        if cap <= 0 || used >= cap then
          go acc rest
        else begin
          Hashtbl.replace used_by_kind kind (used + 1);
          go ((kind, text, pr) :: acc) rest
        end
  in
  go [] rows

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

let dedup_memory_candidates
    (items : (string * string * int) list) : (string * string * int) list =
  dedup_by_key
    (fun (kind, text, _) ->
      String.lowercase_ascii (String.trim kind ^ ":" ^ String.trim text))
    items

let normalize_memory_text_key (s : string) : string =
  s
  |> String.trim
  |> String.lowercase_ascii
  |> Re.replace_string (Re.Pcre.re {re|[ \t\n\r!"#$%&'()*+,\-./:;<=>?@\[\]^_`{|}~]+|re} |> Re.compile) ~by:""

let is_meaningful_memory_text (s : string) : bool =
  let key = normalize_memory_text_key s in
  let placeholders = [
    "";
    "none";
    "null";
    "na";
    "nil";
    "없음";
    "없다";
    "없어요";
    "해당없음";
    "무";
    "미정";
  ] in
  not (List.mem key placeholders)
  && not (String_util.contains_substring s "[SYNTHETIC]")
  && not (String.equal (String.trim s) "No tools used this generation")

let memory_candidates_from_snapshot
    (snapshot : keeper_state_snapshot) : (string * string * int) list =
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
  text: string;
  priority: int;
  ts_unix: float;
}

let parse_memory_bank_row (line : string) : keeper_memory_row_raw option =
  try
    let j = Yojson.Safe.from_string line in
    let kind = Safe_ops.json_string ~default:"" "kind" j |> String.trim in
    let text = Safe_ops.json_string ~default:"" "text" j |> String.trim in
    let priority = Safe_ops.json_int ~default:0 "priority" j in
    let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
    if kind = "" || text = "" || not (is_meaningful_memory_text text) then
      None
    else
      Some { json = j; kind; text; priority; ts_unix }
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
      let summary_text =
        Printf.sprintf "[consolidated:%d] %s"
          (List.length group)
          (String.concat "; " (take 5 texts))
      in
      let summary_json = `Assoc [
        ("ts", `String (now_iso ()));
        ("ts_unix", `Float now);
        ("kind", `String "long_term");
        ("priority", `Int 90);
        ("text", `String summary_text);
        ("trace_id", `String tid);
        ("consolidated_from", `Int (List.length group));
      ] in
      consolidated := {
        json = summary_json;
        kind = "long_term";
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
          ("priority", `Int 95);
          ("text", `String row.text);
          ("recurring_across", `Int (List.length tids));
        ] in
        consolidated := {
          json = lt_json;
          kind = "long_term";
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
    Safe_ops.get_env_int_logged
      "MASC_KEEPER_MEMORY_MAX_NOTES"
      ~default:default_target
  in
  max 40 (min 4000 raw)

let memory_compaction_trigger_bytes ~(target_notes : int) : int =
  let default_trigger = max 120000 (target_notes * 360) in
  let raw =
    Safe_ops.get_env_int_logged
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

let compact_memory_bank_if_needed
    (config : Room.config)
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
    if size_bytes < trigger_bytes then
      { no_memory_bank_compaction with
        target_notes;
        reason = Some "under_trigger_bytes";
      }
    else
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
          if before_notes <= target_notes && invalid = 0 then
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
            let _ = consolidated_count in
            let by_recency =
              List.sort
                (fun (a : keeper_memory_row_raw) (b : keeper_memory_row_raw) ->
                  let c = compare b.ts_unix a.ts_unix in
                  if c <> 0 then c else compare b.priority a.priority)
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
              let selected_rev = ref [] in
              let selected_count = ref 0 in
              let fallback_kind_cap = max 8 (target_notes / 8) in
              let add_row ~ignore_kind_cap (row : keeper_memory_row_raw) =
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
                      Hashtbl.add selected_keys key ();
                      Hashtbl.replace kind_used row.kind (used + 1);
                      selected_rev := row :: !selected_rev;
                      incr selected_count
                    end
              in
              let recent_floor = max 16 (min 64 (target_notes / 5)) in
              by_recency
              |> take recent_floor
              |> List.iter (fun row -> add_row ~ignore_kind_cap:false row);
              let by_priority =
                List.sort
                  (fun (a : keeper_memory_row_raw) (b : keeper_memory_row_raw) ->
                    let c = compare b.priority a.priority in
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
                    { no_memory_bank_compaction with
                      target_notes;
                      before_notes;
                      after_notes = before_notes;
                      dedup_dropped;
                      invalid_dropped = invalid;
                      reason = Some "write_failed";
                    }
                | Ok () ->
                    {
                      performed = true;
                      reason = Some "compacted";
                      target_notes;
                      before_notes;
                      after_notes;
                      dropped_notes;
                      dedup_dropped;
                      invalid_dropped = invalid;
                    }

let append_memory_notes_from_reply
    (config : Room.config)
    (meta : keeper_meta)
    ~(turn : int)
    ~(reply : string) : (int * string list) =
  let snapshot =
    match parse_state_snapshot_from_reply reply with
    | Some s -> s
    | None ->
        (* Deterministic fallback: use keeper meta fields as memory source.
           This guarantees memory write regardless of LLM output format.
           See RFC #3646 Section 3: Det/NonDet boundary principle. *)
        {
          Keeper_memory_policy.goal =
            (if meta.goal <> "" then Some meta.goal else None);
          progress = None;
          done_summary = None;
          next_summary = None;
          next_items = [];
          decisions = [];
          open_questions = [];
          constraints = [];
        }
  in
  let notes =
    memory_candidates_from_snapshot snapshot
  in
  if notes = [] then
    (0, [])
  else
    let now_ts = Time_compat.now () in
    let path = keeper_memory_bank_path config meta.name in
    let kinds_acc = ref [] in
    let seen_kinds : (string, unit) Hashtbl.t = Hashtbl.create 8 in
    List.iter
      (fun (kind, text, priority) ->
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
              ("priority", `Int priority);
              ("text", `String text);
            ]))
      notes;
    (List.length notes, List.rev !kinds_acc)

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
           if kind = "" || text = "" then None
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

