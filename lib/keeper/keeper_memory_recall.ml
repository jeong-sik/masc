(** Keeper_memory_recall — history/tail JSONL reading for memory surfaces.

    The keyword-classifier recall eval ([is_memory_recall_query],
    [expected_topic_hint], [evaluate_memory_recall]) was removed with the
    legacy memory bank: recall is the keeper's own judgment via the
    [keeper_memory_search] tool, not a substring heuristic. What remains
    here is the typed file-reading substrate those surfaces share. *)

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

let user_messages_newest_first (msgs : Agent_core.Types.message list) : string list =
  msgs
  |> List.rev
  |> List.filter_map (fun (m : Agent_core.Types.message) ->
       if m.role = Agent_core.Types.User then
         let content = String.trim (Agent_core.Types.text_of_message m) in
         if content = "" then None else Some content
       else None)
;;

let load_history_user_messages_result ~path ~limit ~accept =
  let unreadable_rows = ref 0 in
  let matches = ref [] in
  let remaining = ref limit in
  let record_unreadable exn_class detail =
    incr unreadable_rows;
    Log.Keeper.warn "load_history_user_messages: skipping line in %s: %s" path detail;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string MemoryRecallHistorySwallowedExceptions)
      ~labels:[ "exception_class", Keeper_memory_recall_exn_class.to_label exn_class ]
      ()
  in
  let user_message = function
    | Dated_jsonl.Malformed_json { detail; _ } ->
      record_unreadable Keeper_memory_recall_exn_class.Yojson_parse_error detail;
      None
    | Dated_jsonl.Parsed json ->
      (try
         let role = Json_util.get_string json "role" in
         let source =
           Json_util.get_string json "source"
           |> Option.value ~default:""
           |> String.trim
         in
         if role = Some "user"
            && not (Keeper_types_support.is_internal_history_source source)
         then
           let content = String.trim (Keeper_context_core.text_of_history_jsonl_json json) in
           if content = "" then None else Some content
         else None
       with
       | (Yojson.Safe.Util.Type_error _ | Failure _) as exn ->
         record_unreadable (Keeper_memory_recall_exn_class.classify exn)
           (Printexc.to_string exn);
         None)
  in
  let read_result =
    if limit <= 0 then Ok None
    else
      try
        let exists =
          Domain_pool_ref.submit_io_or_inline (fun () ->
            match Unix.lstat path with
            | _ -> true
            | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false)
        in
        if not exists then Ok None
        else
          match
            Dated_jsonl.find_latest_entry_in_file_result path (fun entry ->
              match user_message entry with
              | Some content when accept content ->
                matches := content :: !matches;
                decr remaining;
                if !remaining = 0 then Some () else None
              | Some _ | None -> None)
          with
          | Ok _ as result -> result
          | Error error ->
            Log.Keeper.warn "history search: %s" (Dated_jsonl.read_error_to_string error);
            Error Keeper_memory_recall_exn_class.Io_error
      with
      | (Sys_error _ | Unix.Unix_error _ | End_of_file) as exn ->
        Error (Keeper_memory_recall_exn_class.classify exn)
  in
  let result =
    match read_result with
    | Ok _ -> Ok (List.rev !matches)
    | Error exn_class ->
      record_memory_recall_read_error ~site:"load_history_user_messages_result" path exn_class;
      Error exn_class
  in
  result, !unreadable_rows
;;
