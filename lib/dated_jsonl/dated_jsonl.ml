(** Date-split JSONL storage.

    Extracts the [YYYY-MM/DD.jsonl] pattern originally used by
    {!Workspace_utils_ops.log_event} into a reusable module.

    Layout:
    {v
      base_dir/
        2026-03/
          20.jsonl
          21.jsonl
        2026-04/
          01.jsonl
    v}
*)

type t = {
  base_dir : string;
  mutex : Eio.Mutex.t Atomic.t;
  retention_days : int option;
  max_bytes : int option;
  last_prune_day : string option Atomic.t;
}

let default_append_guard f = f ()
let append_guard : ((unit -> unit) -> unit) Atomic.t = Atomic.make default_append_guard

let mutex_registry : (string, Eio.Mutex.t Atomic.t) Hashtbl.t = Hashtbl.create 16
let mutex_registry_mu = Stdlib.Mutex.create ()

let strip_trailing_slashes path =
  let rec loop len =
    if len > 1 && path.[len - 1] = '/' then loop (len - 1) else len
  in
  let len = loop (String.length path) in
  if len = String.length path then path else String.sub path 0 len

let mutex_key base_dir =
  let path =
    if Filename.is_relative base_dir then
      Filename.concat (Config_dir_resolver.current_working_dir ()) base_dir
    else
      base_dir
  in
  strip_trailing_slashes path

let mutex_for_base_dir ~base_dir =
  let key = mutex_key base_dir in
  Stdlib.Mutex.protect mutex_registry_mu (fun () ->
    match Hashtbl.find_opt mutex_registry key with
    | Some cell -> cell
    | None ->
        let mutex = Eio.Mutex.create () in
        let cell = Atomic.make mutex in
        Hashtbl.add mutex_registry key cell;
        cell)

let create ~base_dir ?mutex ?retention_days ?max_bytes () =
  let mutex =
    match mutex with
    | Some mutex -> Atomic.make mutex
    | None -> mutex_for_base_dir ~base_dir
  in
  let retention_days =
    match retention_days with
    | Some days when days > 0 -> Some days
    | _ -> None
  in
  let max_bytes =
    match max_bytes with
    | Some bytes when bytes > 0 -> Some bytes
    | _ -> None
  in
  {
    base_dir;
    mutex;
    retention_days;
    max_bytes;
    last_prune_day = Atomic.make None;
  }

let base_dir t = t.base_dir

(** Parse ["YYYY-MM-DD"] into [("YYYY-MM", "DD")].
    Returns [None] for malformed strings. *)
let parse_date s =
  if String.length s < 10 then None
  else
    let month = String.sub s 0 7 in
    let day = String.sub s 8 2 in
    Some (month, day)

(* ── Directory listing (sorted descending) ────────────── *)

let list_subdirs path =
  if not (Sys.file_exists path) then []
  else
    try
      Sys.readdir path
      |> Array.to_list
      |> List.sort (fun a b -> String.compare b a)
    with Sys_error _ -> []

(** Month directories matching [YYYY-MM] pattern, newest first. *)
let list_month_dirs base_dir =
  list_subdirs base_dir
  |> List.filter (fun d ->
    String.length d = 7
    && d.[4] = '-'
    && Option.is_some (int_of_string_opt (String.sub d 0 4)))

(** Day files matching [DD.jsonl], newest first. *)
let list_day_files month_path =
  list_subdirs month_path
  |> List.filter (fun f -> Filename.check_suffix f ".jsonl")

(* ── Lines from a single file ─────────────────────────── *)

let iter_non_empty_lines path f =
  if Fs_compat.file_exists path then
    try
      let ic = open_in_bin path in
      Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        try
          while true do
            let line = input_line ic in
            if String.trim line <> "" then f line
          done
        with End_of_file -> ())
    with Sys_error _ -> ()

let count_non_empty_lines path =
  if not (Fs_compat.file_exists path) then 0
  else
    try
      let ic = open_in_bin path in
      Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        let count = ref 0 in
        (try
           while true do
             let line = input_line ic in
             if String.trim line <> "" then incr count
           done
         with End_of_file -> ());
        !count)
    with Sys_error _ -> 0

let file_size path =
  try (Unix.stat path).Unix.st_size with
  | Unix.Unix_error _ | Sys_error _ -> 0

let day_file_paths_oldest_first base_dir =
  list_month_dirs base_dir
  |> List.rev
  |> List.concat_map (fun month ->
       let month_path = Filename.concat base_dir month in
       list_day_files month_path
       |> List.rev
       |> List.map (fun day -> (month_path, Filename.concat month_path day)))

let remove_file_and_empty_month ~month_path path =
  try
    Sys.remove path;
    (try Unix.rmdir month_path with Unix.Unix_error _ -> ());
    true
  with Sys_error _ -> false

(** Read the last [n] non-empty lines from a file without loading the entire
    file into memory.  Reads backwards in 8 KB chunks from the end.

    Uses a generous 3x multiplier on newline counting to handle files with
    blank lines between data.  Chunks are collected in a list (O(1) prepend)
    and concatenated once at the end to avoid O(N^2) buffer copying. *)
let load_tail_lines path ~max_lines =
  if max_lines <= 0 || not (Fs_compat.file_exists path) then []
  else
    let ic = open_in_bin path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let file_len = in_channel_length ic in
      if file_len = 0 then []
      else
        let chunk_size = 8192 in
        (* Use 3x multiplier: blank lines mean newlines > non-empty lines *)
        let target_newlines = max_lines * 3 in
        let chunks = ref [] in
        let total_newlines = ref 0 in
        let pos = ref file_len in
        while !pos > 0 && !total_newlines <= target_newlines do
          let read_start = max 0 (!pos - chunk_size) in
          let read_len = !pos - read_start in
          seek_in ic read_start;
          let chunk = Bytes.create read_len in
          really_input ic chunk 0 read_len;
          chunks := chunk :: !chunks;
          (* Count newlines in this chunk only (not accumulated) *)
          for i = 0 to read_len - 1 do
            if Bytes.get chunk i = '\n' then incr total_newlines
          done;
          pos := read_start
        done;
        (* Concatenate chunks once (already in file order) *)
        let total_bytes = List.fold_left (fun acc c -> acc + Bytes.length c) 0 !chunks in
        let combined = Bytes.create total_bytes in
        let _ = List.fold_left (fun off c ->
          let len = Bytes.length c in
          Bytes.blit c 0 combined off len;
          off + len
        ) 0 !chunks in
        let raw_lines =
          Bytes.to_string combined
          |> String.split_on_char '\n'
        in
        let raw_lines =
          if !pos > 0 then
            match raw_lines with
            | _partial :: rest -> rest
            | [] -> []
          else raw_lines
        in
        let all_lines =
          raw_lines
          |> List.filter (fun l -> String.trim l <> "")
        in
        let total = List.length all_lines in
        if total <= max_lines then all_lines
        else
          List.filteri (fun i _ -> i >= total - max_lines) all_lines
    )

let prune_unlocked t ~days =
  if days <= 0 then 0
  else begin
    let now = Unix.gettimeofday () in
    let cutoff = now -. (float_of_int days *. Masc_time_constants.day) in
    let cutoff_tm = Unix.gmtime cutoff in
    let cutoff_month =
      Printf.sprintf "%04d-%02d"
        (cutoff_tm.Unix.tm_year + 1900)
        (cutoff_tm.Unix.tm_mon + 1)
    in
    let cutoff_day = Printf.sprintf "%02d" cutoff_tm.Unix.tm_mday in
    let deleted = ref 0 in
    let months = list_month_dirs t.base_dir in
    List.iter (fun m ->
      let month_path = Filename.concat t.base_dir m in
      if String.compare m cutoff_month < 0 then begin
        (* Entire month is before cutoff — remove all files *)
        let day_files = list_day_files month_path in
        List.iter (fun d ->
          (try Sys.remove (Filename.concat month_path d) with Sys_error _ -> ());
          incr deleted
        ) day_files;
        (try Unix.rmdir month_path with Unix.Unix_error _ -> ())
      end else if m = cutoff_month then begin
        let day_files = list_day_files month_path in
        List.iter (fun d ->
          let day_num = Filename.remove_extension d in
          if String.compare day_num cutoff_day < 0 then begin
            (try Sys.remove (Filename.concat month_path d) with Sys_error _ -> ());
            incr deleted
          end
        ) day_files
      end
    ) months;
    !deleted
  end

let prune_to_max_bytes_unlocked t ~max_bytes ~keep_path =
  if max_bytes <= 0 then 0
  else begin
    let files = day_file_paths_oldest_first t.base_dir in
    let total =
      List.fold_left (fun acc (_, path) -> acc + file_size path) 0 files
    in
    let remaining = ref total in
    let deleted = ref 0 in
    List.iter
      (fun (month_path, path) ->
         if !remaining > max_bytes && not (String.equal path keep_path) then
           let bytes = file_size path in
           if remove_file_and_empty_month ~month_path path then begin
             remaining := max 0 (!remaining - bytes);
             incr deleted
           end)
      files;
    !deleted
  end

(* ── Public API ───────────────────────────────────────── *)

let append_unlocked ?max_current_file_bytes t json =
  let mutex = Atomic.get t.mutex in
  (* [use_ro] serializes file appends without poisoning the shared mutex on
     IO failure, so retry paths can keep using the same registry entry.
     [use_rw] would poison on any exception regardless of [~protect].

     [Fs_compat.append_jsonl] (post-RFC-0108 #15936) already provides
     per-path cross-domain atomicity via its own Stdlib.Mutex registry
     and fresh-fd-per-call. The PR-5 (#15928) inline [atomic_append_jsonl]
     was a pre-emptive duplicate of that guarantee — removed here. *)
  Eio.Mutex.use_ro mutex (fun () ->
    let dated = Jsonl_writer.dated_path_now ~base_dir:t.base_dir in
    let fits_current_file =
      match max_current_file_bytes with
      | Some max_bytes when max_bytes > 0 ->
        let row_bytes = String.length (Yojson.Safe.to_string json) + 1 in
        file_size dated.path + row_bytes <= max_bytes
      | _ -> true
    in
    if not fits_current_file
    then false
    else begin
      Jsonl_writer.append_jsonl ~path:dated.path json;
      (match t.retention_days with
       | None -> ()
       | Some days ->
         let today = dated.month_dir ^ "/" ^ dated.day_file in
         if
           not
             (Option.equal String.equal
                (Atomic.get t.last_prune_day)
                (Some today))
         then begin
           (* See retention pruning is opportunistic after append durability. *)
           ignore (prune_unlocked t ~days : int);
           Atomic.set t.last_prune_day (Some today)
         end);
      (match t.max_bytes with
       | None -> ()
       | Some max_bytes ->
         (* See byte-budget pruning is best-effort cleanup after append. *)
         ignore
           (prune_to_max_bytes_unlocked t ~max_bytes ~keep_path:dated.path : int));
      true
    end)

let append_inner t json = ignore (append_unlocked t json : bool)

let append t json =
  (Atomic.get append_guard) (fun () -> append_inner t json)

let append_if_current_file_fits t ~max_current_file_bytes json =
  let appended = ref false in
  (Atomic.get append_guard) (fun () ->
    appended := append_unlocked ~max_current_file_bytes t json);
  !appended

let set_append_guard guard = Atomic.set append_guard guard

let read_recent ?(offset=0) t n =
  if n <= 0 then []
  else begin
    let skip = ref offset in
    let collected = ref [] in
    let count = ref 0 in
    let months = list_month_dirs t.base_dir in
    let exception Done in
    (try
       List.iter (fun m ->
         let month_path = Filename.concat t.base_dir m in
         let days = list_day_files month_path in
         List.iter (fun d ->
           if !count >= n then raise_notrace Done;
           let path = Filename.concat month_path d in
           let need = n - !count + !skip in
           let lines = load_tail_lines path ~max_lines:need in
           let rev_lines = List.rev lines in
           List.iter (fun line ->
             if !count >= n then raise_notrace Done;
             (try
                let json = Yojson.Safe.from_string line in
                if !skip > 0 then
                  decr skip
                else begin
                  collected := json :: !collected;
                  incr count
                end
              with Yojson.Json_error _ -> ())
           ) rev_lines
         ) days
       ) months
     with Done -> ());
    !collected
  end

let read_recent_lines ?(offset=0) t n =
  if n <= 0 then []
  else begin
    let skip = ref offset in
    let collected = ref [] in
    let count = ref 0 in
    let months = list_month_dirs t.base_dir in
    let exception Done in
    (try
       List.iter (fun m ->
         let month_path = Filename.concat t.base_dir m in
         let days = list_day_files month_path in
         List.iter (fun d ->
           if !count >= n then raise_notrace Done;
           let path = Filename.concat month_path d in
           let need = n - !count + !skip in
           let lines = load_tail_lines path ~max_lines:need in
           let rev_lines = List.rev lines in
           List.iter (fun line ->
             if !count >= n then raise_notrace Done;
             if !skip > 0 then
               decr skip
             else begin
               collected := line :: !collected;
               incr count
             end
           ) rev_lines
         ) days
       ) months
     with Done -> ());
    !collected
  end

let iter_json_file path f =
  iter_non_empty_lines path (fun line ->
    try f (Yojson.Safe.from_string line) with
    | Yojson.Json_error _ -> ())

let iter_all t f =
  let months = list_month_dirs t.base_dir |> List.rev in
  List.iter
    (fun m ->
       let month_path = Filename.concat t.base_dir m in
       let days = list_day_files month_path |> List.rev in
       List.iter
         (fun d -> iter_json_file (Filename.concat month_path d) f)
         days)
    months

let sorted_entries_result path =
  try Ok (Sys.readdir path |> Array.to_list |> List.sort String.compare) with
  | Sys_error message -> Error (Printf.sprintf "failed to list %s: %s" path message)
;;

let line_error operation path line_number message =
  Printf.sprintf "%s %s:%d: %s" operation path line_number message
;;

let iter_json_file_result path f =
  try
    let input = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr input)
      (fun () ->
         let rec loop line_number =
           match input_line input with
           | exception End_of_file -> Ok ()
           | exception Sys_error message ->
             Error (line_error "failed to read" path line_number message)
           | line when String.trim line = "" -> loop (line_number + 1)
           | line ->
             (match Yojson.Safe.from_string line with
              | json ->
                f json;
                loop (line_number + 1)
              | exception Yojson.Json_error message ->
                Error (line_error "failed to parse" path line_number message))
         in
         loop 1)
  with
  | Sys_error message -> Error (Printf.sprintf "failed to open %s: %s" path message)
;;

let iter_all_result t f =
  let ( let* ) = Result.bind in
  let* store_present =
    try
      match (Unix.stat t.base_dir).st_kind with
      | Unix.S_DIR -> Ok true
      | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
        Error ("dated JSONL base path is not a directory: " ^ t.base_dir)
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
    | Unix.Unix_error (error, _, _) ->
      Error
        (Printf.sprintf
           "failed to inspect %s: %s"
           t.base_dir
           (Unix.error_message error))
  in
  if not store_present then Ok ()
  else
    let* months = sorted_entries_result t.base_dir in
    let months =
      List.filter
        (fun name ->
           String.length name = 7
           && name.[4] = '-'
           && Option.is_some (int_of_string_opt (String.sub name 0 4)))
        months
    in
    let rec iter_months = function
      | [] -> Ok ()
      | month :: rest ->
        let month_path = Filename.concat t.base_dir month in
        let* days = sorted_entries_result month_path in
        let days = List.filter (fun name -> Filename.check_suffix name ".jsonl") days in
        let rec iter_days = function
          | [] -> Ok ()
          | day :: rest ->
            let* () = iter_json_file_result (Filename.concat month_path day) f in
            iter_days rest
        in
        let* () = iter_days days in
        iter_months rest
    in
    iter_months months
;;

let iter_range t ~since ~until f =
  match parse_date since, parse_date until with
  | None, _ | _, None -> ()
  | Some (since_month, since_day), Some (until_month, until_day) ->
    let months = list_month_dirs t.base_dir |> List.rev in
    List.iter (fun m ->
      if String.compare m since_month >= 0
         && String.compare m until_month <= 0 then begin
        let month_path = Filename.concat t.base_dir m in
        let days = list_day_files month_path |> List.rev in
        List.iter (fun d ->
          let day_num = Filename.remove_extension d in
          let dominated =
            (m = since_month && String.compare day_num since_day < 0)
            || (m = until_month && String.compare day_num until_day > 0)
          in
          if not dominated then iter_json_file (Filename.concat month_path d) f)
          days
      end)
      months

(* Per-file non-empty-line count cached as (boundary, count). Day-files are
   append-only and split by date, so the count of newline-terminated lines
   before a byte boundary is a pure function of the file prefix: a closed
   (past-day) file hits the cache forever, and the growing current-day file
   re-reads only the bytes appended since the last call instead of the whole
   file. A boundary past the current size (prune/rewrite) falls back to a
   full rescan, so the cached count never drifts.

   Counting contract: only '\n'-terminated lines are counted. A trailing
   partially-flushed line is invisible until its newline lands — for the
   monotonic dashboard counters served by [count_entries] that is the
   correct staleness direction (undercount by at most the in-flight line).
   Audit callers that must count an unterminated trailing line use
   [count_entries_uncached]. *)
type file_count_entry =
  { fc_boundary : int
  ; fc_count : int
  }

let file_count_cache : (string, file_count_entry) Hashtbl.t = Hashtbl.create 64
let file_count_cache_mu = Stdlib.Mutex.create ()

let count_non_empty_lines_cached path =
  let size = try (Unix.stat path).Unix.st_size with Unix.Unix_error _ -> -1 in
  if size < 0
  then count_non_empty_lines path
  else begin
    let cached =
      Stdlib.Mutex.protect file_count_cache_mu (fun () ->
        Hashtbl.find_opt file_count_cache path)
    in
    match cached with
    | Some e when e.fc_boundary = size -> e.fc_count
    | cached ->
      let store_label = Filename.basename (Filename.dirname path) in
      let from, base =
        match cached with
        | Some e when e.fc_boundary < size -> e.fc_boundary, e.fc_count
        | Some _ ->
          (* boundary past the file size: shrink/rotation — full re-parse *)
          Otel_metric_store_core.inc_counter
            Otel_builtin_metric_names.metric_telemetry_cache_rescans
            ~labels:[ ("store", store_label) ]
            ();
          0, 0
        | None -> 0, 0
      in
      let delta, boundary =
        Fs_compat.fold_appended_lines ~path ~from ~init:0
          ~f:(fun acc _line -> acc + 1)
      in
      Otel_metric_store_core.inc_counter
        Otel_builtin_metric_names.metric_telemetry_scanned_bytes
        ~labels:[ ("store", store_label) ]
        ~delta:(Float.of_int (max 0 (boundary - from)))
        ();
      let count = base + delta in
      Stdlib.Mutex.protect file_count_cache_mu (fun () ->
        Hashtbl.replace file_count_cache path
          { fc_boundary = boundary; fc_count = count });
      count
  end

let fold_day_file_counts t ~counter =
  let months = list_month_dirs t.base_dir in
  List.fold_left (fun total month ->
    let month_path = Filename.concat t.base_dir month in
    let days = list_day_files month_path in
    total
    + List.fold_left (fun month_total day ->
        let path = Filename.concat month_path day in
        month_total + counter path
      ) 0 days
  ) 0 months

(* Truly uncached: every day-file is re-read byte by byte. Audit/test callers
   that must not observe any caching use this directly. *)
let count_entries_uncached t = fold_day_file_counts t ~counter:count_non_empty_lines

(* Per-file-cached full count. O(appended bytes) in steady state: closed
   day-files hit [file_count_cache] outright and the growing current-day
   file re-reads only its delta. *)
let count_entries_incremental t =
  fold_day_file_counts t ~counter:count_non_empty_lines_cached

(* The RFC-0162 §3.2 10s-TTL store-level cache that used to sit here is
   removed: the boundary-keyed per-file cache above makes a [count_entries]
   call O(appended bytes), so the TTL layer no longer bought anything and
   only added a staleness window plus a second cache surface to reason
   about. *)
let count_entries = count_entries_incremental

let reset_count_cache_for_testing () =
  Stdlib.Mutex.protect file_count_cache_mu (fun () -> Hashtbl.reset file_count_cache)
;;
let read_range t ~since ~until =
  let collected = ref [] in
  iter_range t ~since ~until (fun json -> collected := json :: !collected);
  List.rev !collected

(* Like [read_range] but bounded to the [n] most recent entries within
   [since, until] (inclusive day range). Reads newest day-file first and
   only the tail of each file, parsing at most ~[n] entries instead of the
   whole window. [read_range] parses every entry in the range, which is
   unbounded over large stores; callers that already pass a result limit
   should use this so a wide window cannot scan months of multi-MB files.
   Returns entries oldest-first within the collected set (same convention
   as [read_recent]). *)
let read_range_recent ?(offset = 0) t ~since ~until n =
  if n <= 0
  then []
  else (
    match parse_date since, parse_date until with
    | None, _ | _, None -> []
    | Some (since_month, since_day), Some (until_month, until_day) ->
      let skip = ref offset in
      let collected = ref [] in
      let count = ref 0 in
      let months = list_month_dirs t.base_dir in
      let exception Done in
      (try
         List.iter
           (fun m ->
              if String.compare m since_month >= 0
                 && String.compare m until_month <= 0
              then begin
                let month_path = Filename.concat t.base_dir m in
                let days = list_day_files month_path in
                List.iter
                  (fun d ->
                     if !count >= n then raise_notrace Done;
                     let day_num = Filename.remove_extension d in
                     let dominated =
                       (m = since_month && String.compare day_num since_day < 0)
                       || (m = until_month && String.compare day_num until_day > 0)
                     in
                     if not dominated
                     then begin
                       let path = Filename.concat month_path d in
                       let need = n - !count + !skip in
                       let lines = load_tail_lines path ~max_lines:need in
                       let rev_lines = List.rev lines in
                       List.iter
                         (fun line ->
                            if !count >= n then raise_notrace Done;
                            try
                              let json = Yojson.Safe.from_string line in
                              if !skip > 0
                              then decr skip
                              else begin
                                collected := json :: !collected;
                                incr count
                              end
                            with
                            | Yojson.Json_error _ -> ())
                         rev_lines
                     end)
                  days
              end)
           months
       with
       | Done -> ());
      !collected)

let prune t ~days =
  let mutex = Atomic.get t.mutex in
  Eio.Mutex.use_ro mutex (fun () -> prune_unlocked t ~days)

(* Test hooks declared in the .mli — implementation lives in this
   module so tests can verify mutex-registry sharing without
   widening the public API surface. *)
module For_testing = struct
  let mutex (t : t) = Atomic.get t.mutex

  let mutex_for_base_dir base_dir =
    let cell = mutex_for_base_dir ~base_dir in
    Atomic.get cell

  let registry_size () =
    Stdlib.Mutex.protect mutex_registry_mu (fun () ->
      Hashtbl.length mutex_registry)

  let reset_append_guard () = Atomic.set append_guard default_append_guard
end

(* Duplicate count_entries removed — canonical definition at line 225 *)
