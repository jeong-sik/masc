(** Keeper_memory_recall — history/tail JSONL reading for memory surfaces.

    The keyword-classifier recall eval ([is_memory_recall_query],
    [expected_topic_hint], [evaluate_memory_recall]) was removed with the
    legacy memory bank: recall is the keeper's own judgment via the
    [keeper_memory_search] tool, not a substring heuristic. What remains
    here is the typed file-reading substrate those surfaces share. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(* Whether the final returned line was newline-terminated in the file.
   [Partial_last_line] means an append was in flight when the read happened,
   which is the difference between a truncated write and real corruption at
   the tail of an append-only log. *)
type tail_completion =
  | Complete
  | Partial_last_line

(* RFC-0149 §3.1 — typed Result entry point.  Distinguishes "no memory"
   ([Ok []] for missing file or zero-line request) from "IO/parse fault"
   ([Error class]).  The catch-all classifies the exception through the
   closed sum {!Keeper_memory_recall_exn_class.t} so the caller can
   branch on a bounded label instead of a free-form string. *)
let read_file_tail_lines_with_completion path ~max_bytes ~max_lines :
    (string list * tail_completion, Keeper_memory_recall_exn_class.t) result =
  if max_lines <= 0 then Ok ([], Complete)
  else if not (Fs_compat.file_exists path) then Ok ([], Complete)
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
             (* The read always ends at end-of-file, so the last byte of
                [content] tells whether the final line was terminated. A file
                whose last line is still being appended has no trailing
                newline yet. The symmetric case at the other end -- a first
                line cut by the [max_bytes] window -- is already handled above
                by dropping it when [!pos > 0]. *)
             let completion =
               if String.length content > 0
                  && content.[String.length content - 1] = '\n'
               then Complete
               else Partial_last_line
             in
             let n = List.length lines in
             let lines =
               if n <= max_lines then lines
               else
                 let drop = n - max_lines in
                 List.filteri (fun i _ -> i >= drop) lines
             in
             (lines, completion)))
    with
    | (Sys_error _ | Unix.Unix_error _ | End_of_file) as exn ->
        Error (Keeper_memory_recall_exn_class.classify exn)

(* The completion flag matters to exactly one caller (the decision-log reader,
   which must tell an in-flight append from corruption). Everyone else keeps
   the original shape through this wrapper, so there is one implementation
   rather than two readers to keep in step. *)
let read_file_tail_lines_result path ~max_bytes ~max_lines :
    (string list, Keeper_memory_recall_exn_class.t) result =
  Result.map fst (read_file_tail_lines_with_completion path ~max_bytes ~max_lines)

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

let recent_user_messages (msgs : Agent_core.Types.message list) ~(max_n : int) : string list =
  msgs
  |> List.rev
  |> List.filter_map (fun (m : Agent_core.Types.message) ->
       if m.role = Agent_core.Types.User then
         let c = String.trim (Agent_core.Types.text_of_message m) in
         if c = "" then None else Some c
       else None)
  |> take max_n

(* RFC-0149 §3.1: pure list -> list filter behind
   [load_history_user_messages_result].  The per-line
   [try ... with exn -> log + (* cancel-guard-ok: prose *)
   counter + None] is a separate boundary (JSONL corruption) from the
   file-read IO fault the caller reports as [Error]. *)
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
             Keeper_metrics.(to_string MemoryRecallHistorySwallowedExceptions)
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
