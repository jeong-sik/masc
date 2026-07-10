(** Keeper_memory_recall — recall scoring, auto-rules, and memory eval. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

include Keeper_memory_bank

module Log_memory = Log.Memory

(* Static string-match patterns hoisted from evaluate_memory_recall.
   [Re.str] + [Re.compile] is pure, so a single DFA build at module
   load replaces one per-call compile on every weather/first-question
   recall evaluation. *)
let re_weather_ko = Re.str "날씨" |> Re.compile
let re_weather_en = Re.str "weather" |> Re.compile
let re_first_ko = Re.str "첫" |> Re.compile
let re_first_en = Re.str "first" |> Re.compile

(* RFC-0149 §3.1 — typed Result entry point.  Distinguishes "no memory"
   ([Ok []] for missing file or zero-line request) from "IO/parse fault"
   ([Error class]).  The catch-all classifies the exception through the
   closed sum {!Keeper_memory_recall_exn_class.t} so the caller can
   branch on a bounded label instead of a free-form string. *)
let read_file_tail_lines_result path ~max_bytes ~max_lines :
    (string list, Keeper_memory_recall_exn_class.t) result =
  if max_lines <= 0 then Ok []
  else if not (Fs_compat.file_exists path) then Ok []
  else
    try
      let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
      Ok
        (Fun.protect
           ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
           (fun () ->
             let file_len = (Unix.LargeFile.fstat fd).Unix.LargeFile.st_size in
             let min_start =
               if max_bytes <= 0
               then 0L
               else Int64.max 0L (Int64.sub file_len (Int64.of_int max_bytes))
             in
             let chunk_size = 64 * 1024 in
             let pos = ref file_len in
             let chunks = ref [] in
             let newline_count = ref 0 in
             let count_newlines s =
               String.iter (fun ch -> if ch = '\n' then incr newline_count) s
             in
             while Int64.compare !pos min_start > 0 && !newline_count <= max_lines do
               let available = Int64.sub !pos min_start in
               let read_len =
                 Int64.to_int (Int64.min (Int64.of_int chunk_size) available)
               in
               let start = Int64.sub !pos (Int64.of_int read_len) in
               ignore (Unix.LargeFile.lseek fd start Unix.SEEK_SET);
               let buf = Bytes.create read_len in
               let rec read_exact offset remaining =
                 if remaining <= 0 then offset
                 else
                   let n = Unix.read fd buf offset remaining in
                   if n = 0 then offset else read_exact (offset + n) (remaining - n)
               in
               let bytes_read = read_exact 0 read_len in
               let chunk = Bytes.sub_string buf 0 bytes_read in
               count_newlines chunk;
               chunks := chunk :: !chunks;
               pos := start
             done;
             let content = String.concat "" !chunks in
             let lines =
               content
               |> String.split_on_char '\n'
               |> List.filter (fun s -> String.trim s <> "")
             in
             let lines =
               if Int64.compare !pos 0L > 0
               then (match lines with _ :: rest -> rest | [] -> [])
               else lines
             in
             let n = List.length lines in
             if n <= max_lines then lines
             else
               let drop = n - max_lines in
               List.filteri (fun i _ -> i >= drop) lines))
    with
    | (Sys_error _ | Unix.Unix_error _ | End_of_file) as exn ->
        Error (Keeper_memory_recall_exn_class.classify exn)

let record_memory_recall_read_error ~site path exn_class =
  let exn_label = Keeper_memory_recall_exn_class.to_label exn_class in
  Log.Keeper.warn
    "%s: dropping history read of %s: <error class=%s>"
    site path exn_label;
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string MemoryRecallReadErrors)
    ~labels:[ ("exception_class", exn_label) ]
    ()
;;

(* Audit/snapshot read-path helper (RFC-0138 lock-free snapshot extension):
   project the most recent [window] lines of [path] via
   {!Jsonl_incremental_projection.recent_lines} — steady-state O(new bytes)
   instead of re-reading the tail on every snapshot — recording a typed read
   error and returning [] on file I/O failure, the same graceful degradation
   the prior tail read gave with the same {!Keeper_memory_recall_exn_class}
   classification.  Shared by the operator tool-audit and keeper status-metrics
   snapshot paths so the projection wiring and error handling live in one
   place. *)
let recent_lines_or_record
    (projection : string list Jsonl_incremental_projection.t)
    ~(site : string)
    ~(key : string)
    ~(path : string)
    ~(window : int)
    ~(initial_tail_bytes : int) : string list =
  try
    Jsonl_incremental_projection.recent_lines projection ~key ~path ~window
      ~initial_tail_bytes
  with
  (* Re-raise cancellation verbatim (RFC-0106): never absorb
     [Eio.Cancel.Cancelled] into the read-error counter. *)
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    record_memory_recall_read_error ~site path
      (Keeper_memory_recall_exn_class.classify exn);
    (* Preserve the last successful projection instead of collapsing to [] on a
       transient read error, so a briefly-unreadable or partially-corrupt tail
       does not blank an otherwise-populated snapshot (the error is still
       recorded above for observability). [peek] holds the newest-first ring, so
       reverse it to the oldest-first order [recent_lines] returns. *)
    (match Jsonl_incremental_projection.peek projection ~key with
     | Some (_ :: _ as newest_first) -> List.rev newest_first
     | _ -> [])
;;

(* RFC-0149 §3.1 — typed Result entry point.  Distinguishes "empty
   memory bank" ([Ok summary] where [summary] holds zero recent rows)
   from "memory bank read failed" ([Error class]).  Callers that want
   to render a [Memory_unavailable] signal up the chain should consume
   this variant instead of the legacy
   [read_keeper_memory_summary]/[empty-summary] silent fallback. *)
let read_keeper_memory_summary_result
    (config : Workspace.config)
    ~(name : string)
    ~(max_bytes : int)
    ~(max_lines : int)
    ~(recent_limit : int) :
    (keeper_memory_summary, Keeper_memory_recall_exn_class.t) result =
  match
    read_file_tail_lines_result
      (Keeper_types_support.keeper_memory_bank_path config name)
      ~max_bytes
      ~max_lines
  with
  | Ok lines -> Ok (summarize_memory_bank_lines lines ~recent_limit)
  | Error exn_class -> Error exn_class

(* RFC-0149 §3.1: pure list -> list reducer.  Now the sole consumer is
   [read_memory_horizon_counts_result]; the legacy facade was deleted
   in the §3.1 closeout once all caller sites consumed the typed
   variant. *)
let memory_horizon_counts_from_lines (lines : string list) :
    (string * int) list =
  let counts : (string, int) Hashtbl.t = Hashtbl.create 8 in
  List.iter
    (fun line ->
      match parse_memory_bank_row line with
      | None -> ()
      | Some row ->
          let cur =
            Option.value ~default:0
              (Hashtbl.find_opt counts row.horizon)
          in
          Hashtbl.replace counts row.horizon (cur + 1))
    lines;
  counts
  |> Hashtbl.to_seq
  |> List.of_seq
  |> List.sort (fun (ka, va) (kb, vb) ->
         let c = compare vb va in
         if c <> 0 then c else String.compare ka kb)

(* RFC-0149 §3.1: typed Result variant.  Distinguishes [Ok []] ("no
   horizon rows recorded") from [Error class] ("bank read failed"). *)
let read_memory_horizon_counts_result
    (config : Workspace.config)
    ~(name : string)
    ~(max_bytes : int)
    ~(max_lines : int) :
    ((string * int) list, Keeper_memory_recall_exn_class.t) result =
  match
    read_file_tail_lines_result
      (Keeper_types_support.keeper_memory_bank_path config name)
      ~max_bytes
      ~max_lines
  with
  | Ok lines -> Ok (memory_horizon_counts_from_lines lines)
  | Error exn_class -> Error exn_class

(* RFC-0149 §3.1: pure list -> list filter (horizon-aware memory text
   projector).  Now the sole consumer is
   [read_recent_memory_texts_result]; the legacy facade was deleted
   in the §3.1 closeout. *)
let recent_memory_texts_from_lines
    ~(horizon : string)
    ~(limit : int)
    (lines : string list) : string list =
  lines
  |> List.filter_map parse_memory_bank_row
  |> List.filter (fun row -> String.equal row.horizon horizon)
  |> List.sort (fun a b ->
         let c = compare b.priority a.priority in
         if c <> 0 then c else compare b.ts_unix a.ts_unix)
  |> dedup_by_key (fun row -> normalize_memory_text_key row.text)
  |> take (max 0 limit)
  |> List.map (fun row -> row.text)

(* RFC-0149 §3.1: typed Result variant.  Distinguishes [Ok []] ("no
   recent texts for this horizon") from [Error class] ("bank read
   failed"). *)
let read_recent_memory_texts_result
    (config : Workspace.config)
    ~(name : string)
    ~(horizon : string)
    ~(max_bytes : int)
    ~(max_lines : int)
    ~(limit : int) :
    (string list, Keeper_memory_recall_exn_class.t) result =
  match
    read_file_tail_lines_result
      (Keeper_types_support.keeper_memory_bank_path config name)
      ~max_bytes
      ~max_lines
  with
  | Ok lines -> Ok (recent_memory_texts_from_lines ~horizon ~limit lines)
  | Error exn_class -> Error exn_class

(** Detect whether a query is asking about past conversation memory.

    Keywords are split by language for maintainability.
    English keywords are broad ("remember", "before") — matched after
    lowercasing to catch case variations.
    Korean keywords include spacing variants ("기억안나" vs "기억 안나")
    because Korean tokenizers often disagree on spacing. *)
let is_memory_recall_query (s : string) : bool =
  let q = String.lowercase_ascii s in
  let en_keywords = [
    "what did i ask";
    "first question";
    "before";
    "remember";
    "remembered";
    "do you remember";
    "memory";
  ] in
  let ko_keywords = [
    "기억";        (* "memory/remember" — base morpheme *)
    "기억해";      (* "do you remember" *)
    "기억안나";    (* "can't remember" — no space variant *)
    "기억 안나";   (* "can't remember" — spaced variant *)
    "기억나";      (* "I remember" — no space variant *)
    "기억 나";     (* "I remember" — spaced variant *)
    "전에 뭐";     (* "what before" — asking about prior *)
    "이전에";      (* "previously" *)
    "첫 질문";     (* "first question" *)
    "처음 물어";   (* "first asked" *)
    "뭐라고 물어봤"; (* "what did I ask" *)
  ] in
  let needles = en_keywords @ ko_keywords in
  List.exists (String_util.contains_substring q) needles

let expected_topic_hint (s : string) : string option =
  let q = String.lowercase_ascii s in
  let has_ko needle = String_util.contains_substring s needle in
  let has_en needle = String_util.contains_substring q needle in
  if has_ko "날씨" || has_en "weather" then
    Some "weather"
  else if has_ko "첫 질문"
       || has_en "first question"
       || has_en "very first"
       || has_en "earliest"
       || ((has_ko "처음" || has_ko "첫" || has_en "first")
           && (has_ko "질문" || has_ko "물어" || has_en "question" || has_en "ask"))
  then
    Some "first_question"
  else
    None

let recent_user_messages (msgs : Agent_sdk.Types.message list) ~(max_n : int) : string list =
  msgs
  |> List.rev
  |> List.filter_map (fun (m : Agent_sdk.Types.message) ->
       if m.role = Agent_sdk.Types.User then
         let c = String.trim (Agent_sdk.Types.text_of_message m) in
         if c = "" then None else Some c
       else None)
  |> take max_n

(* RFC-0149 §3.1: pure list -> list filter extracted so the legacy
   silent-fallback path and the [_result] variant share the same
   per-line parsing logic.  The per-line [try ... with exn -> log +
   counter + None] is preserved here — that is a separate boundary
   (JSONL corruption) from the file-read IO fault. *)
let history_user_messages_from_lines
    ~(path : string)
    ~(max_n : int)
    (lines : string list) : string list =
  lines
  |> List.filter_map (fun line ->
       try
         let json = Yojson.Safe.from_string line in
         let role = Json_util.get_string json "role" in
         let source =
           Json_util.get_string json "source"
           |> Option.value ~default:""
           |> String.trim
         in
         (* Issue #18400: role may be null in corrupted JSONL lines. Use to_string_option so null/missing roles are skipped instead of throwing Type_error. *)
         if role = Some "user" then
           let content =
             String.trim
               (Keeper_context_core.text_of_history_jsonl_json json)
           in
           if content = ""
              || Keeper_types_support.is_internal_history_source source
           then None
           else Some content
         else None
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           (* V07 (HIGH): make non-Cancel failures visible instead of
              masking JSONL corruption / fs faults as "no history".
              Behavior preserved — we still drop this line and return
              [None]; only logging + counter are added.

              P1 follow-up: the [exception_class] label is now a
              4-value closed sum from [Keeper_memory_recall_exn_class]
              (constructor-level match on the [exn] type, not a
              substring scan on [Printexc.to_string]) so the metric
              cardinality is bounded. The full error string is still
              emitted to the log body. *)
           let exn_detail = Printexc.to_string exn in
           let exn_label =
             Keeper_memory_recall_exn_class.(to_label (classify exn))
           in
           Log.Keeper.warn
             "load_history_user_messages: skipping line in %s: %s"
             path exn_detail;
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string MemoryBankLoadHistorySwallowedExceptions)
             ~labels:[ ("exception_class", exn_label) ]
             ();
           None)
  |> take max_n

(* RFC-0149 §3.1: typed Result variant.  Distinguishes [Ok []] ("no
   user messages found in the history file") from [Error class] ("the
   history file read failed"). Read failures still increment the bounded
   recall-read-error metric before returning [Error]. *)
let load_history_user_messages_result
    ~(path : string)
    ~(max_n : int) :
    (string list, Keeper_memory_recall_exn_class.t) result =
  match
    read_file_tail_lines_result
      path
      ~max_bytes:0
      ~max_lines:(max_n * 3)
  with
  | Ok lines ->
    Ok (history_user_messages_from_lines ~path ~max_n lines)
  | Error exn_class ->
    record_memory_recall_read_error
      ~site:"load_history_user_messages_result"
      path
      exn_class;
    Error exn_class

(** Build recall candidates by merging checkpoint messages with history.jsonl.
    Checkpoint messages are prioritized (recent context), history.jsonl
    provides cross-generation recall for older conversations. Deduplication
    uses exact string match on the first 100 characters. *)
let recall_candidates_with_history
    ~(checkpoint_messages : Agent_sdk.Types.message list)
    ~(history_path : string)
    ~(max_checkpoint : int)
    ~(max_history : int) : string list =
  let from_checkpoint = recent_user_messages checkpoint_messages ~max_n:max_checkpoint in
  (* RFC-0149 §3.1 closeout — aggregation site.  History read failure
     is elided to [[]] so the checkpoint matches still surface; the
     bounded [exn_class] counter emitted by
     [load_history_user_messages_result] is the informational signal for
     the failure. *)
  let from_history =
    match
      load_history_user_messages_result ~path:history_path ~max_n:max_history
    with
    | Ok msgs -> msgs
    | Error _ -> []
  in
  (* Deduplicate: checkpoint messages take priority *)
  let key_of s =
    let len = min 100 (String.length s) in
    String.sub s 0 len
  in
  let module SS = Set_util.StringSet in
  let seen =
    List.fold_left (fun acc s -> SS.add (key_of s) acc)
      SS.empty from_checkpoint
  in
  let unique_history =
    List.filter (fun s -> not (SS.mem (key_of s) seen)) from_history
  in
  from_checkpoint @ unique_history

type memory_recall_eval = {
  performed: bool;
  query_kind: string;
  expected_topic: string option;
  candidate_count: int;
  initial_score: float;
  final_score: float;
  threshold: float;
  passed: bool;
  best_match: string option;
}

let evaluate_memory_recall
    ~(user_message : string)
    ~(assistant_reply : string)
    ~(candidates : string list) : memory_recall_eval =
  let recall = is_memory_recall_query user_message in
  let expected_topic = expected_topic_hint user_message in
  let has_weather_word (s : string) =
    let q = String.lowercase_ascii s in
    Re.execp re_weather_ko s
    || Re.execp re_weather_en q
  in
  (* Similarity threshold for recall match acceptance.
     0.18 (default): Jaccard + character n-gram combined score.
     At this level, queries sharing 2+ morphemes with a candidate produce
     scores above 0.18, while unrelated pairs stay below. Determined by
     manual review of recall accuracy on keeper session transcripts.

     0.15 (weather): Weather queries are typically short ("오늘 날씨" = 2 words)
     with minimal context words. The reduced n-gram surface area produces
     lower scores for genuine matches, so we lower the threshold by 0.03
     to avoid false negatives on this common query type. *)
  let threshold =
    match expected_topic with
    | Some "weather" -> 0.15
    | _ -> 0.18
  in
  if not recall then
    {
      performed = false;
      query_kind = "none";
      expected_topic;
      candidate_count = List.length candidates;
      initial_score = 0.0;
      final_score = 0.0;
      threshold;
      passed = true;
      best_match = None;
    }
  else if candidates = [] then
    {
      performed = true;
      query_kind = Option.value ~default:"recall" expected_topic;
      expected_topic;
      candidate_count = 0;
      initial_score = 0.0;
      final_score = 0.0;
      threshold;
      passed = false;
      best_match = None;
    }
  else
    let weather_candidates = List.filter has_weather_word candidates in
    let candidates_for_general =
      match expected_topic with
      | Some "weather" when weather_candidates <> [] -> weather_candidates
      | _ -> candidates
    in
    let oldest_candidate =
      match List.rev candidates with
      | c :: _ -> Some c
      | [] -> None
    in
    let (best_msg, best_score) =
      match expected_topic, oldest_candidate with
      | Some "first_question", Some target ->
          (Some target, jaccard_similarity assistant_reply target)
      | _ ->
          List.fold_left (fun (best_m, best_s) cand ->
            let score = jaccard_similarity assistant_reply cand in
            if score > best_s then (Some cand, score) else (best_m, best_s)
          ) (None, 0.0) candidates_for_general
    in
    let topic_bonus =
      match expected_topic with
      | Some "weather" ->
          let has_weather_reply = has_weather_word assistant_reply in
          if has_weather_reply then 0.08 else -.0.08
      | Some "first_question" ->
          let has_first =
            Re.execp re_first_ko assistant_reply
            || Re.execp re_first_en (String.lowercase_ascii assistant_reply)
          in
          if has_first then 0.05 else -.0.05
      | _ -> 0.0
    in
    let final_score = max 0.0 (min 1.0 (best_score +. topic_bonus)) in
    {
      performed = true;
      query_kind = Option.value ~default:"recall" expected_topic;
      expected_topic;
      candidate_count = List.length candidates;
      initial_score = best_score;
      final_score;
      threshold;
      passed = final_score >= threshold;
      best_match = best_msg;
    }

let memory_eval_to_json
    (e : memory_recall_eval)
    ~(correction_applied : bool)
    ~(correction_success : bool)
    ~(correction_skipped_budget : bool)
    ~(prompt_fallback_applied : bool)
    ~(prompt_fallback_success : bool)
    ~(prompt_fallback_skipped_budget : bool)
    ~(postpass_budget_ms : int)
    ~(postpass_budget_remaining_ms : int)
    ~(recall_fallback_applied : bool) : Yojson.Safe.t =
  `Assoc [
    ("performed", `Bool e.performed);
    ("query_kind", `String e.query_kind);
    ("expected_topic", Json_util.string_opt_to_json e.expected_topic);
    ("candidate_count", `Int e.candidate_count);
    ("initial_score", `Float e.initial_score);
    ("final_score", `Float e.final_score);
    ("threshold", `Float e.threshold);
    ("passed", `Bool e.passed);
    ("best_match", Json_util.string_opt_to_json e.best_match);
    ("correction_applied", `Bool correction_applied);
    ("correction_success", `Bool correction_success);
    ("correction_skipped_budget", `Bool correction_skipped_budget);
    ("prompt_fallback_applied", `Bool prompt_fallback_applied);
    ("prompt_fallback_success", `Bool prompt_fallback_success);
    ("prompt_fallback_skipped_budget", `Bool prompt_fallback_skipped_budget);
    ("postpass_budget_ms", `Int postpass_budget_ms);
    ("postpass_budget_remaining_ms", `Int postpass_budget_remaining_ms);
    ("deterministic_fallback_applied", `Bool recall_fallback_applied);
    ("recall_fallback_applied", `Bool recall_fallback_applied);
  ]

let work_kind_of_eval (e : memory_recall_eval) : string =
  if e.performed then
    if e.query_kind <> "" && e.query_kind <> "none" then
      e.query_kind
    else
      "memory_recall"
  else
    match e.expected_topic with
    | Some "weather" -> "weather_answer"
    | Some "first_question" -> "first_question_answer"
    | Some topic when topic <> "" -> topic
    | _ -> "general_chat"
