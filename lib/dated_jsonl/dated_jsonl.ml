(** Date-split JSONL storage.

    Extracts the [YYYY-MM/DD.jsonl] pattern originally used by
    {!Workspace_utils_ops.log_event} into a reusable module.

    Layout:
    {v
      base_dir/
        2026-03/
          20.jsonl
          21.001.jsonl   (completed size-rotation segment of day 21)
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

type read_operation =
  | Inspect
  | List_directory
  | Open_file
  | Read_file

type layout_entry_kind =
  | Month_directory
  | Day_file

type non_regular_file_kind =
  | Directory
  | Symbolic_link
  | Character_device
  | Block_device
  | Fifo
  | Socket

type read_error =
  | Invalid_offset of { offset : int }
  | Invalid_date_range of
      { since : string
      ; until : string
      }
  | Not_a_directory of { path : string }
  | Invalid_layout_entry of
      { parent : string
      ; entry : string
      ; expected : layout_entry_kind
      }
  | Non_regular_file of
      { path : string
      ; kind : non_regular_file_kind
      }
  | Io_error of
      { operation : read_operation
      ; path : string
      ; detail : string
      }

type recent_entry =
  | Parsed of Yojson.Safe.t
  | Malformed_json of
      { path : string
      ; line_number : int option
      ; detail : string
      }

let read_operation_to_string = function
  | Inspect -> "inspect"
  | List_directory -> "list directory"
  | Open_file -> "open"
  | Read_file -> "read"
;;

let layout_entry_kind_to_string = function
  | Month_directory -> "YYYY-MM month directory"
  | Day_file -> "DD.jsonl day file"
;;

let non_regular_file_kind_to_string = function
  | Directory -> "directory"
  | Symbolic_link -> "symbolic link"
  | Character_device -> "character device"
  | Block_device -> "block device"
  | Fifo -> "FIFO"
  | Socket -> "socket"
;;

let read_error_to_string = function
  | Invalid_offset { offset } ->
    Printf.sprintf "dated JSONL recent-read offset must be non-negative: %d" offset
  | Invalid_date_range { since; until } ->
    Printf.sprintf
      "dated JSONL range must be valid and ordered: since=%S until=%S"
      since
      until
  | Not_a_directory { path } -> "dated JSONL path is not a directory: " ^ path
  | Invalid_layout_entry { parent; entry; expected } ->
    Printf.sprintf
      "invalid dated JSONL layout entry %s: expected %s"
      (Filename.concat parent entry)
      (layout_entry_kind_to_string expected)
  | Non_regular_file { path; kind } ->
    Printf.sprintf
      "dated JSONL path has an unsupported file kind: %s (%s)"
      path
      (non_regular_file_kind_to_string kind)
  | Io_error { operation; path; detail } ->
    Printf.sprintf "failed to %s %s: %s" (read_operation_to_string operation) path detail
;;

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
let year_is_leap year =
  year mod 4 = 0 && (year mod 100 <> 0 || year mod 400 = 0)
;;

let days_in_month ~year = function
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> Some 31
  | 4 | 6 | 9 | 11 -> Some 30
  | 2 -> Some (if year_is_leap year then 29 else 28)
  | _ -> None
;;

let substring_is_ascii_digits value ~position ~length =
  let rec loop index =
    if index >= position + length
    then true
    else
      match value.[index] with
      | '0' .. '9' -> loop (index + 1)
      | _ -> false
  in
  loop position
;;

let parse_date s =
  if String.length s <> 10
     || s.[4] <> '-'
     || s.[7] <> '-'
     || not (substring_is_ascii_digits s ~position:0 ~length:4)
     || not (substring_is_ascii_digits s ~position:5 ~length:2)
     || not (substring_is_ascii_digits s ~position:8 ~length:2)
  then None
  else
    match
      int_of_string_opt (String.sub s 0 4),
      int_of_string_opt (String.sub s 5 2),
      int_of_string_opt (String.sub s 8 2)
    with
    | Some year, Some month, Some day ->
      (match days_in_month ~year month with
       | Some maximum when day >= 1 && day <= maximum ->
         Some (String.sub s 0 7, String.sub s 8 2)
       | Some _ | None -> None)
    | _ -> None

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

(** Day files matching [DD.jsonl] or [DD.NNN.jsonl], newest first. *)
let list_day_files month_path =
  list_subdirs month_path
  |> List.filter (fun f -> Filename.check_suffix f ".jsonl")

(* The day number is always the leading two characters — for both the
   current [DD.jsonl] and rotated [DD.NNN.jsonl] segments.
   [Filename.remove_extension] must not be used for this: it maps a
   segment to ["DD.NNN"], which compares greater than its own day and
   silently drops segments from range boundaries. *)
let day_number_of_day_file_name name =
  if String.length name >= 2 then String.sub name 0 2 else name
;;

type directory_presence =
  | Directory_present
  | Directory_missing

let directory_presence_of_stat path (stat : Unix.stats) =
  match stat.st_kind with
  | Unix.S_DIR -> Ok Directory_present
  | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
  | Unix.S_SOCK -> Error (Not_a_directory { path })
;;

let inspect_directory_result ~missing_is_empty path =
  let ( let* ) = Result.bind in
  let inspected =
    match Unix.lstat path with
    | stat -> Ok (Some stat)
    | exception Unix.Unix_error (Unix.ENOENT, _, _) when missing_is_empty ->
      Ok None
    | exception Unix.Unix_error (error, _, _) ->
      Error
        (Io_error
           { operation = Inspect; path; detail = Unix.error_message error })
    | exception Sys_error detail ->
      Error (Io_error { operation = Inspect; path; detail })
  in
  let* stat = inspected in
  match stat with
  | None -> Ok Directory_missing
  | Some stat ->
    if stat.Unix.st_kind <> Unix.S_LNK
    then directory_presence_of_stat path stat
    else Error (Non_regular_file { path; kind = Symbolic_link })
;;

let list_directory_result ~missing_is_empty path =
  let ( let* ) = Result.bind in
  let* presence = inspect_directory_result ~missing_is_empty path in
  match presence with
  | Directory_missing -> Ok []
  | Directory_present ->
    (match Sys.readdir path with
     | entries ->
       Ok
         (entries
          |> Array.to_list
          |> List.sort (fun left right -> String.compare right left))
     | exception Sys_error detail ->
       Error (Io_error { operation = List_directory; path; detail }))
;;

let year_and_month_of_directory_name name =
  if String.length name = 7
     && name.[4] = '-'
     && substring_is_ascii_digits name ~position:0 ~length:4
     && substring_is_ascii_digits name ~position:5 ~length:2
  then
    match
      int_of_string_opt (String.sub name 0 4),
      int_of_string_opt (String.sub name 5 2)
    with
    | Some year, Some month when month >= 1 && month <= 12 -> Some (year, month)
    | _ -> None
  else None
;;

let month_directory_name_is_valid name =
  Option.is_some (year_and_month_of_directory_name name)
;;

(* [DD.jsonl] is the day's current append target; [DD.NNN.jsonl] is a
   completed size-rotation segment of the same day (see
   [append_rotating]). Lexicographic name order places a day's segments
   after the previous day and before the day's current file, so the
   newest-first listings, the oldest-first prune order, and range
   selection all order them correctly with no special cases. *)
let rotation_sequence_digits = 3
let rotated_segment_name_length = 12 (* "DD." + NNN + ".jsonl" *)

let day_number_is_valid ~year ~month day_text =
  match int_of_string_opt day_text, days_in_month ~year month with
  | Some day, Some maximum -> day >= 1 && day <= maximum
  | None, _ | _, None -> false
;;

let day_file_name_is_valid ~year ~month name =
  let is_current_shape =
    String.length name = 8
    && String.equal (String.sub name 2 6) ".jsonl"
    && substring_is_ascii_digits name ~position:0 ~length:2
  in
  let is_rotated_segment_shape =
    String.length name = rotated_segment_name_length
    && Char.equal name.[2] '.'
    && String.equal (String.sub name 6 6) ".jsonl"
    && substring_is_ascii_digits name ~position:0 ~length:2
    && substring_is_ascii_digits name ~position:3 ~length:rotation_sequence_digits
  in
  (is_current_shape || is_rotated_segment_shape)
  && day_number_is_valid ~year ~month (String.sub name 0 2)
;;

(* A name this layout can never produce is a foreign file, not a corrupted
   member of it. Month directories are [YYYY-MM] and day files are
   [DD.jsonl]; neither can begin with a dot, so a dotfile was written by
   something other than this store.

   macOS writes [.DS_Store] into any directory Finder opens, and the live
   store sits under a browsed home, so failing the whole read for one would
   take every reader of that store down for the rest of a Finder visit.
   Entries that do belong to the layout stay strict: a directory named
   [2026-13] or a file named [32.jsonl] is corruption and still fails. *)
let entry_is_foreign_to_layout entry =
  String.length entry > 0 && Char.equal entry.[0] '.'
;;

let validate_layout_entries ~parent ~expected ~is_valid entries =
  let rec loop valid_entries = function
    | [] -> Ok (List.rev valid_entries)
    | entry :: rest when entry_is_foreign_to_layout entry -> loop valid_entries rest
    | entry :: rest ->
      if is_valid entry
      then loop (entry :: valid_entries) rest
      else Error (Invalid_layout_entry { parent; entry; expected })
  in
  loop [] entries
;;

let list_month_dirs_result base_dir =
  let ( let* ) = Result.bind in
  let* entries = list_directory_result ~missing_is_empty:true base_dir in
  validate_layout_entries
    ~parent:base_dir
    ~expected:Month_directory
    ~is_valid:month_directory_name_is_valid
    entries
;;

let list_day_files_result month_path =
  let ( let* ) = Result.bind in
  let month_entry = Filename.basename month_path in
  let* year, month =
    match year_and_month_of_directory_name month_entry with
    | Some value -> Ok value
    | None ->
      Error
        (Invalid_layout_entry
           { parent = Filename.dirname month_path
           ; entry = month_entry
           ; expected = Month_directory
           })
  in
  let* entries = list_directory_result ~missing_is_empty:false month_path in
  validate_layout_entries
    ~parent:month_path
    ~expected:Day_file
    ~is_valid:(day_file_name_is_valid ~year ~month)
    entries
;;

(* ── Lines from a single file ─────────────────────────── *)

(* Keep the physical-row predicate identical to [String.trim]'s OCaml 5.4
   whitespace contract: space, form feed, line feed, carriage return, tab. *)
let trim_whitespace = function
  | ' ' | '\012' | '\n' | '\r' | '\t' -> true
  | _ -> false
;;

let line_is_non_empty line =
  String.exists (fun character -> not (trim_whitespace character)) line
;;

let iter_non_empty_lines path f =
  if Fs_compat.file_exists path then
    try
      let ic = open_in_bin path in
      Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        try
          while true do
            let line = input_line ic in
            if line_is_non_empty line then f line
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
             if line_is_non_empty line then incr count
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

let close_file_descriptor_noerr descriptor =
  try Unix.close descriptor with
  | Unix.Unix_error _ -> ()
;;

let non_regular_file_kind_of_stats stats =
  match stats.Unix.st_kind with
  | Unix.S_REG -> None
  | Unix.S_DIR -> Some Directory
  | Unix.S_LNK -> Some Symbolic_link
  | Unix.S_CHR -> Some Character_device
  | Unix.S_BLK -> Some Block_device
  | Unix.S_FIFO -> Some Fifo
  | Unix.S_SOCK -> Some Socket
;;

let inspect_path_result path =
  match Unix.lstat path with
  | stats -> Ok stats
  | exception Unix.Unix_error (error, _, _) ->
    Error
      (Io_error
         { operation = Inspect; path; detail = Unix.error_message error })
;;

let same_file_identity left right =
  left.Unix.st_dev = right.Unix.st_dev && left.Unix.st_ino = right.Unix.st_ino
;;

let open_regular_input_result path =
  let ( let* ) = Result.bind in
  let* initial_stats = inspect_path_result path in
  match non_regular_file_kind_of_stats initial_stats with
  | Some kind -> Error (Non_regular_file { path; kind })
  | None ->
    (match
       Unix.openfile
         path
         [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ]
         0
     with
     | exception Unix.Unix_error (error, _, _) ->
       Error
         (Io_error
            { operation = Open_file; path; detail = Unix.error_message error })
     | descriptor ->
       let reject error =
         close_file_descriptor_noerr descriptor;
         Error error
       in
       (match Unix.fstat descriptor with
        | exception Unix.Unix_error (error, _, _) ->
          reject
            (Io_error
               { operation = Inspect; path; detail = Unix.error_message error })
        | opened_stats ->
          (match non_regular_file_kind_of_stats opened_stats with
           | Some kind -> reject (Non_regular_file { path; kind })
           | None ->
             (match inspect_path_result path with
              | Error error -> reject error
              | Ok current_stats ->
                (match non_regular_file_kind_of_stats current_stats with
                 | Some kind -> reject (Non_regular_file { path; kind })
                 | None when not (same_file_identity opened_stats current_stats) ->
                   reject
                     (Io_error
                        { operation = Inspect
                        ; path
                        ; detail = "path identity changed while opening"
                        })
                 | None ->
                   Ok (Unix.in_channel_of_descr descriptor))))))
;;

(** Read the last [n] non-empty lines from an open file. Each byte is inspected
    at most once while walking backwards. The loop stops after the chunk that
    contains the [n]th physical non-empty line, so it overscans by at most one
    8 KB chunk. Chunks are concatenated exactly once. *)
(* Segment [buffer] on ['\n'] exactly as [String.split_on_char] does — the final
   segment is always emitted, empty or not — without allocating anything. *)
let fold_newline_segments buffer f init =
  let len = Bytes.length buffer in
  let rec loop start index acc =
    if index >= len then f acc start len
    else if Bytes.get buffer index = '\n' then
      loop (index + 1) (index + 1) (f acc start index)
    else loop start (index + 1) acc
  in
  loop 0 0 init

let rec segment_has_content buffer index stop =
  index < stop
  && (not (trim_whitespace (Bytes.get buffer index))
      || segment_has_content buffer (index + 1) stop)

(* Cut the last [max_lines] non-empty segments out of [buffer].

   The previous shape was [Bytes.to_string |> String.split_on_char |>
   List.filter |> List.length |> List.filteri]. That copies the whole tail into
   a string, then allocates a string for every segment including the ones about
   to be dropped, then builds three lists over them. One dashboard read tails 36
   stores at up to 2000 lines of ~520B each, so those copies are tens of MB of
   short-lived allocation per request.

   That matters beyond this reader: profiling one wide read showed the CPU
   dominated by [caml_stw_empty_minor_heap] and the surrounding barrier frames,
   and OCaml 5 stops *every* domain for each minor collection. Allocation here
   is paid by every fiber in the process, not just this one.

   Two scans over the buffer allocate nothing; only surviving lines become
   strings. *)
let last_non_empty_lines buffer ~max_lines =
  let count =
    fold_newline_segments buffer
      (fun total start stop ->
         if segment_has_content buffer start stop then total + 1 else total)
      0
  in
  let skip = max 0 (count - max_lines) in
  let _, reversed =
    fold_newline_segments buffer
      (fun (seen, acc) start stop ->
         if not (segment_has_content buffer start stop) then (seen, acc)
         else if seen < skip then (seen + 1, acc)
         else (seen + 1, Bytes.sub_string buffer start (stop - start) :: acc))
      (0, [])
  in
  List.rev reversed

let load_tail_lines_from_channel input ~max_lines =
  if max_lines <= 0
  then []
  else
    let file_len = in_channel_length input in
    if file_len = 0
    then []
    else begin
      let chunk_size = 8192 in
      let chunks = ref [] in
      let non_empty_line_count = ref 0 in
      let current_line_is_non_empty = ref false in
      let position = ref file_len in
      while !position > 0 && !non_empty_line_count < max_lines do
        let read_start = max 0 (!position - chunk_size) in
        let read_len = !position - read_start in
        seek_in input read_start;
        let chunk = Bytes.create read_len in
        really_input input chunk 0 read_len;
        chunks := chunk :: !chunks;
        for index = read_len - 1 downto 0 do
          match Bytes.get chunk index with
          | '\n' ->
            if !current_line_is_non_empty then incr non_empty_line_count;
            current_line_is_non_empty := false
          | character ->
            if not (trim_whitespace character)
            then current_line_is_non_empty := true
        done;
        position := read_start
      done;
      let total_bytes =
        List.fold_left (fun total chunk -> total + Bytes.length chunk) 0 !chunks
      in
      let combined = Bytes.create total_bytes in
      let _next_offset =
        List.fold_left
          (fun offset chunk ->
             let length = Bytes.length chunk in
             Bytes.blit chunk 0 combined offset length;
             offset + length)
          0
          !chunks
      in
      last_non_empty_lines combined ~max_lines
    end
;;

(* One day file's tail read, split and parse is a single job on the process
   domain pool when one is installed: the reads are blocking syscalls, the
   scan and the parse are CPU work, and none of it touches the calling
   fiber's state. Without a pool, from a non-Eio context, or from a pool
   worker it runs inline as before. Measured 2026-09-05: on a live keeper
   these reads were about a tenth of the main thread's busy time and the
   longest runs outside turn spans (RFC main-domain-scheduler-latency
   section 8.8). *)
let off_fiber f = Domain_pool_ref.submit_io_or_inline f

let load_tail_lines_inline path ~max_lines =
  if max_lines <= 0 || not (Fs_compat.file_exists path)
  then []
  else
    let input = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr input)
      (fun () -> load_tail_lines_from_channel input ~max_lines)
;;

let load_tail_lines path ~max_lines =
  off_fiber (fun () -> load_tail_lines_inline path ~max_lines)
;;

let load_tail_lines_result_inline path ~max_lines =
  if max_lines <= 0
  then Ok []
  else
    match open_regular_input_result path with
    | Error _ as error -> error
    | Ok input ->
      Fun.protect
        ~finally:(fun () -> close_in_noerr input)
        (fun () ->
           match load_tail_lines_from_channel input ~max_lines with
           | lines -> Ok lines
           | exception Sys_error detail ->
             Error (Io_error { operation = Read_file; path; detail })
           | exception End_of_file ->
             Error
               (Io_error
                  { operation = Read_file
                  ; path
                  ; detail = "file changed while reading its tail"
                  })
           | exception Invalid_argument detail ->
             Error (Io_error { operation = Read_file; path; detail }))
;;

let load_tail_lines_result path ~max_lines =
  off_fiber (fun () -> load_tail_lines_result_inline path ~max_lines)
;;

let recent_entry_of_line ~path ?line_number line =
  match Yojson.Safe.from_string line with
  | json -> Parsed json
  | exception Yojson.Json_error detail ->
    Malformed_json { path; line_number; detail }
;;

let find_latest_line_from_channel input f =
  let chunk_size = 8192 in
  let rec scan position right_fragment =
    if position <= 0
    then
      right_fragment
      |> String.split_on_char '\n'
      |> List.rev
      |> List.find_map (fun line ->
        if line_is_non_empty line then f line else None)
    else
      let read_start = max 0 (position - chunk_size) in
      let read_len = position - read_start in
      seek_in input read_start;
      let chunk = Bytes.create read_len in
      really_input input chunk 0 read_len;
      let combined = Bytes.to_string chunk ^ right_fragment in
      let parts = String.split_on_char '\n' combined in
      let left_fragment, complete_lines =
        if read_start = 0
        then "", parts
        else
          match parts with
          | [] -> "", []
          | first :: rest -> first, rest
      in
      match
        complete_lines
        |> List.rev
        |> List.find_map (fun line ->
          if line_is_non_empty line then f line else None)
      with
      | Some _ as found -> found
      | None -> scan read_start left_fragment
  in
  scan (in_channel_length input) ""
;;

let find_latest_entry_in_file_result path f =
  match open_regular_input_result path with
  | Error _ as error -> error
  | Ok input ->
    Fun.protect
      ~finally:(fun () -> close_in_noerr input)
      (fun () ->
         match
           find_latest_line_from_channel input (fun line ->
             f (recent_entry_of_line ~path line))
         with
         | found -> Ok found
         | exception Sys_error detail ->
           Error (Io_error { operation = Read_file; path; detail })
         | exception End_of_file ->
           Error
             (Io_error
                { operation = Read_file
                ; path
                ; detail = "file changed while scanning backwards"
                })
         | exception Invalid_argument detail ->
           Error (Io_error { operation = Read_file; path; detail }))
;;

let prune_unlocked t ~days =
  if days <= 0 then 0
  else begin
    let now = Unix.gettimeofday () in
    let cutoff = now -. (float_of_int days *. Masc_time_constants.day) in
    (* The cutoff has to name directories the same way the writer named them.
       Rebuilding the format here is what lets prune delete by one calendar
       while the writer files by another (#27143). *)
    let cutoff_path = Jsonl_writer.dated_path ~base_dir:t.base_dir ~ts:cutoff in
    let cutoff_month = cutoff_path.Jsonl_writer.month_dir in
    let cutoff_day = Filename.remove_extension cutoff_path.Jsonl_writer.day_file in
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

type append_outcome =
  | Appended_to_current
  | Appended_after_rotation of { segment : string }
  | Skipped_rotation_exhausted of { sequence_limit : int }
  | Skipped_by_append_guard

(* Shared post-append maintenance for every append entry point:
   opportunistic once-per-process-day retention prune, then best-effort
   byte-budget prune that never touches the current day file. Divergence
   between append paths here would give the same store two different
   retention behaviours, so both call this one helper. *)
let run_post_append_pruning_unlocked t ~(dated : Jsonl_writer.dated_path) =
  (match t.retention_days with
   | None -> ()
   | Some days ->
     let today = dated.month_dir ^ "/" ^ dated.day_file in
     if
       not
         (Option.equal String.equal (Atomic.get t.last_prune_day) (Some today))
     then begin
       (* See retention pruning is opportunistic after append durability. *)
       ignore (prune_unlocked t ~days : int);
       Atomic.set t.last_prune_day (Some today)
     end);
  match t.max_bytes with
  | None -> ()
  | Some max_bytes ->
    (* See byte-budget pruning is best-effort cleanup after append. *)
    ignore (prune_to_max_bytes_unlocked t ~max_bytes ~keep_path:dated.path : int)

let append_unlocked t json =
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
    Jsonl_writer.append_jsonl ~path:dated.path json;
    run_post_append_pruning_unlocked t ~dated)

let append_inner t json = append_unlocked t json

let append t json =
  (Atomic.get append_guard) (fun () -> append_inner t json)

let max_rotation_sequence = 999 (* the [NNN] name space of [DD.NNN.jsonl] *)

let rotated_segment_name ~day_prefix ~sequence =
  Printf.sprintf "%s.%0*d.jsonl" day_prefix rotation_sequence_digits sequence

(* Highest existing rotation sequence for [day_prefix] plus one. Scans
   names structurally ([DD.NNN.jsonl] for this day) rather than keeping
   a counter, so restarts and foreign writers cannot desynchronise it. *)
let next_rotation_sequence ~month_path ~day_prefix =
  let day_dot = day_prefix ^ "." in
  list_subdirs month_path
  |> List.fold_left
       (fun highest name ->
          if
            String.length name = rotated_segment_name_length
            && String.starts_with ~prefix:day_dot name
            && substring_is_ascii_digits name ~position:3
                 ~length:rotation_sequence_digits
            && String.equal (String.sub name 6 6) ".jsonl"
          then
            match
              int_of_string_opt (String.sub name 3 rotation_sequence_digits)
            with
            | Some sequence -> Stdlib.Int.max highest sequence
            | None -> highest
          else highest)
       0
  |> ( + ) 1

(* [append_rotating] lives after the file-count cache below: rotation
   must drop the current file's cache entry, and a fresh file that
   happens to regrow to the cached byte boundary would otherwise return
   the rotated-out file's count. *)

let set_append_guard guard = Atomic.set append_guard guard

(* The only traversal for recent-row reads. [f] is applied per row so the
   caller's projection is the only thing that accumulates; [read_recent] gets
   its old behaviour back by projecting each row to itself.

   [f] runs outside the parse [try] on purpose: the reader swallows
   [Yojson.Json_error] to skip malformed rows, and a caller's decoder must not
   inherit that swallow. *)
let filter_map_recent ?(offset=0) t n ~f =
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
           let parsed_newest_first =
             off_fiber (fun () ->
               load_tail_lines_inline path ~max_lines:need
               |> List.rev_map (fun line ->
                 try Some (Yojson.Safe.from_string line)
                 with Yojson.Json_error _ -> None))
           in
           List.iter (fun parsed ->
             if !count >= n then raise_notrace Done;
             match parsed with
             | None -> ()
             | Some json ->
               if !skip > 0 then
                 decr skip
               else begin
                 (match f json with
                  | Some value -> collected := value :: !collected
                  | None -> ());
                 incr count
               end
           ) parsed_newest_first
         ) days
       ) months
     with Done -> ());
    !collected
  end

(* [n] counts the values [f] produced, where [filter_map_recent]'s [n] counts
   rows visited. Each day file is scanned backwards in 8 KB chunks through the
   same primitive as [find_latest_entry_result], so a sparse/no-match query
   never materialises a whole day file. Only the current chunk/line fragment
   and the selected values remain live. *)
let collect_matching_files ?(offset = 0) t n ~month_is_in_range
      ~day_is_in_range ~f =
  if n <= 0 then []
  else begin
    let skip = ref offset in
    let collected = ref [] in
    let count = ref 0 in
    let months = list_month_dirs t.base_dir in
    let exception Done in
    (try
       List.iter (fun m ->
         if month_is_in_range m
         then begin
           let month_path = Filename.concat t.base_dir m in
           let days = list_day_files month_path in
           List.iter (fun d ->
             if !count >= n then raise_notrace Done;
             if day_is_in_range m d
             then begin
               let path = Filename.concat month_path d in
               let input = open_in_bin path in
               Fun.protect
                 ~finally:(fun () -> close_in_noerr input)
                 (fun () ->
                    ignore
                      (find_latest_line_from_channel input (fun line ->
                         let parsed =
                           try Some (Yojson.Safe.from_string line)
                           with Yojson.Json_error _ -> None
                         in
                         match parsed with
                         | None -> None
                         | Some json ->
                           (match f json with
                            | None -> None
                            | Some value ->
                              if !skip > 0
                              then (
                                decr skip;
                                None)
                              else begin
                                collected := value :: !collected;
                                incr count;
                                if !count >= n then Some () else None
                              end))))
             end)
             days
         end
       ) months
     with Done -> ());
    !collected
  end

let collect_matching ?offset t n ~f =
  collect_matching_files
    ?offset
    t
    n
    ~month_is_in_range:(fun _ -> true)
    ~day_is_in_range:(fun _ _ -> true)
    ~f
;;

let collect_matching_range ?offset t ~since ~until n ~f =
  match parse_date since, parse_date until with
  | Some (since_month, since_day), Some (until_month, until_day)
    when String.compare since until <= 0 ->
    collect_matching_files
      ?offset
      t
      n
      ~month_is_in_range:(fun month ->
        String.compare month since_month >= 0
        && String.compare month until_month <= 0)
      ~day_is_in_range:(fun month day_file ->
        let day = day_number_of_day_file_name day_file in
        not
          ((String.equal month since_month && String.compare day since_day < 0)
           || (String.equal month until_month && String.compare day until_day > 0)))
      ~f
  | Some _, Some _ | None, _ | _, None -> []
;;

let read_recent ?offset t n =
  filter_map_recent ?offset t n ~f:(fun json -> Some json)

let read_recent_result ?(offset=0) t n =
  if offset < 0
  then Error (Invalid_offset { offset })
  else if n <= 0
  then Ok []
  else
    let ( let* ) = Result.bind in
    let skip = ref offset in
    let collected = ref [] in
    let count = ref 0 in
    let requested_line_count () =
      let remaining = n - !count in
      if !skip > max_int - remaining then max_int else remaining + !skip
    in
    let rec visit_days month_path = function
      | [] -> Ok ()
      | _ when !count >= n -> Ok ()
      | day :: rest ->
        let path = Filename.concat month_path day in
        let* entries_newest_first =
          off_fiber (fun () ->
            load_tail_lines_result_inline path ~max_lines:(requested_line_count ())
            |> Result.map (List.rev_map (fun line -> recent_entry_of_line ~path line)))
        in
        List.iter
          (fun entry ->
             if !count < n
             then if !skip > 0
             then decr skip
             else begin
               collected := entry :: !collected;
               incr count
             end)
          entries_newest_first;
        visit_days month_path rest
    in
    let rec visit_months = function
      | [] -> Ok ()
      | _ when !count >= n -> Ok ()
      | month :: rest ->
        let month_path = Filename.concat t.base_dir month in
        let* days = list_day_files_result month_path in
        let* () = visit_days month_path days in
        visit_months rest
    in
    let* months = list_month_dirs_result t.base_dir in
    let* () = visit_months months in
    Ok !collected
;;

let find_latest_entry_result t f =
  let ( let* ) = Result.bind in
  let rec visit_days month_path = function
    | [] -> Ok None
    | day :: rest ->
      let* found =
        find_latest_entry_in_file_result
          (Filename.concat month_path day)
          f
      in
      (match found with
       | Some _ -> Ok found
       | None -> visit_days month_path rest)
  in
  let rec visit_months = function
    | [] -> Ok None
    | month :: rest ->
      let month_path = Filename.concat t.base_dir month in
      let* days = list_day_files_result month_path in
      let* found = visit_days month_path days in
      (match found with
       | Some _ -> Ok found
       | None -> visit_months rest)
  in
  let* months = list_month_dirs_result t.base_dir in
  visit_months months
;;

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

let iter_json_file_entries_result path f =
  match open_regular_input_result path with
  | Error _ as error -> error
  | Ok input ->
    Fun.protect
      ~finally:(fun () -> close_in_noerr input)
      (fun () ->
         let rec loop line_number =
           match input_line input with
           | exception End_of_file -> Ok ()
           | exception Sys_error detail ->
             Error (Io_error { operation = Read_file; path; detail })
           | line when not (line_is_non_empty line) -> loop (line_number + 1)
           | line ->
             f (recent_entry_of_line ~path ~line_number line);
             loop (line_number + 1)
         in
         loop 1)
;;

let iter_all_entries_result t f =
  let ( let* ) = Result.bind in
  let rec iter_days month_path = function
    | [] -> Ok ()
    | day :: rest ->
      let* () =
        iter_json_file_entries_result (Filename.concat month_path day) f
      in
      iter_days month_path rest
  in
  let rec iter_months = function
    | [] -> Ok ()
    | month :: rest ->
      let month_path = Filename.concat t.base_dir month in
      let* days = list_day_files_result month_path in
      let* () = iter_days month_path (List.rev days) in
      iter_months rest
  in
  let* months = list_month_dirs_result t.base_dir in
  iter_months (List.rev months)
;;

let iter_range_entries_result t ~since ~until f =
  let ( let* ) = Result.bind in
  match parse_date since, parse_date until with
  | None, _ | _, None -> Error (Invalid_date_range { since; until })
  | Some (since_month, since_day), Some (until_month, until_day)
    when String.compare (since_month ^ since_day) (until_month ^ until_day) > 0 ->
    Error (Invalid_date_range { since; until })
  | Some (since_month, since_day), Some (until_month, until_day) ->
    let month_in_range month =
      String.compare month since_month >= 0
      && String.compare month until_month <= 0
    in
    let day_in_range month day =
      let day_number = day_number_of_day_file_name day in
      not
        ((String.equal month since_month
          && String.compare day_number since_day < 0)
         || (String.equal month until_month
             && String.compare day_number until_day > 0))
    in
    let rec iter_days month month_path = function
      | [] -> Ok ()
      | day :: rest ->
        let* () =
          if day_in_range month day
          then
            iter_json_file_entries_result
              (Filename.concat month_path day)
              f
          else Ok ()
        in
        iter_days month month_path rest
    in
    let rec iter_months = function
      | [] -> Ok ()
      | (month, year, month_number) :: rest ->
        let month_path = Filename.concat t.base_dir month in
        let* days =
          list_directory_result ~missing_is_empty:false month_path
        in
        let selected_days =
          days
          |> List.filter (day_file_name_is_valid ~year ~month:month_number)
          |> List.filter (day_in_range month)
          |> List.rev
        in
        let* () = iter_days month month_path selected_days in
        iter_months rest
    in
    let* entries =
      list_directory_result ~missing_is_empty:true t.base_dir
    in
    entries
    |> List.filter_map (fun month ->
      match year_and_month_of_directory_name month with
      | Some (year, month_number) when month_in_range month ->
        Some (month, year, month_number)
      | Some _ | None -> None)
    |> List.rev
    |> iter_months
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
          let day_num = day_number_of_day_file_name d in
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

let prepare_for_directory_removal t =
  let dated = Jsonl_writer.dated_path_now ~base_dir:t.base_dir in
  Fs_compat.invalidate_cached_writer dated.path;
  Fs_compat.invalidate_mkdir_memo (Filename.dirname dated.path);
  Stdlib.Mutex.protect file_count_cache_mu (fun () ->
    Hashtbl.remove file_count_cache dated.path)
;;

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

(* The count cache above lives in process memory, so every restart re-counted
   every retained line of every dated store. Measured 2026-08-29: masc
   bootstrapped 24 times that day, and 23 of the 28 telemetry_summary
   "heavy refresh" warnings landed within five minutes of a bootstrap, the
   worst at 225.70s and 5,704MB against tool_calls 1.1GB +
   agent-core-events 935MB + trajectories 654MB.

   Persisting (path, boundary, count) turns that back into the incremental
   read it already is in steady state. The file is a cache and never an
   authority: each entry is still checked against the file's current size on
   use, so a boundary that no longer matches re-reads the delta, and a
   boundary past the size falls back to the full rescan. A missing,
   truncated, or unreadable cache file costs exactly what today costs. *)

let count_cache_rows () =
  Stdlib.Mutex.protect file_count_cache_mu (fun () ->
    Hashtbl.fold
      (fun path entry acc -> (path, entry.fc_boundary, entry.fc_count) :: acc)
      file_count_cache
      [])
;;

(* Entries are merged rather than replacing the table: a load races nothing at
   startup, but a caller that reloads later must not drop counts this process
   has already measured. A row whose in-memory entry is at least as advanced
   wins, since that one was measured against a size this process observed. *)
let install_count_cache_rows rows =
  Stdlib.Mutex.protect file_count_cache_mu (fun () ->
    List.iter
      (fun (path, boundary, count) ->
         if String.length path > 0 && boundary >= 0 && count >= 0
         then (
           match Hashtbl.find_opt file_count_cache path with
           | Some existing when existing.fc_boundary >= boundary -> ()
           | Some _ | None ->
             Hashtbl.replace
               file_count_cache
               path
               { fc_boundary = boundary; fc_count = count }))
      rows)
;;

let count_cache_to_json rows =
  `List
    (List.map
       (fun (path, boundary, count) ->
          `Assoc
            [ "path", `String path
            ; "boundary", `Int boundary
            ; "count", `Int count
            ])
       rows)
;;

let count_cache_of_json = function
  | `List entries ->
    List.filter_map
      (fun entry ->
         match entry with
         | `Assoc fields ->
           (match
              ( List.assoc_opt "path" fields
              , List.assoc_opt "boundary" fields
              , List.assoc_opt "count" fields )
            with
            | Some (`String path), Some (`Int boundary), Some (`Int count) ->
              Some (path, boundary, count)
            | _ -> None)
         | _ -> None)
      entries
  | _ -> []
;;

let save_count_cache ~path =
  match count_cache_rows () with
  | [] -> Ok ()
  | rows ->
    (try
       Fs_compat.mkdir_p (Filename.dirname path);
       let tmp = path ^ ".tmp" in
       let oc = open_out tmp in
       Fun.protect
         ~finally:(fun () -> close_out_noerr oc)
         (fun () ->
            output_string oc (Yojson.Safe.to_string (count_cache_to_json rows)));
       Sys.rename tmp path;
       Ok ()
     with
     | Sys_error detail -> Error detail
     | Unix.Unix_error (err, op, arg) ->
       Error (Printf.sprintf "%s(%s): %s" op arg (Unix.error_message err)))
;;

let load_count_cache ~path =
  if not (Sys.file_exists path)
  then Ok 0
  else (
    try
      let content = Fs_compat.load_file path in
      let rows = count_cache_of_json (Yojson.Safe.from_string content) in
      install_count_cache_rows rows;
      Ok (List.length rows)
    with
    | Yojson.Json_error detail -> Error detail
    | Sys_error detail -> Error detail
    | Unix.Unix_error (err, op, arg) ->
      Error (Printf.sprintf "%s(%s): %s" op arg (Unix.error_message err)))
;;

let append_rotating_unlocked t ~max_current_file_bytes json =
  let mutex = Atomic.get t.mutex in
  Eio.Mutex.use_ro mutex (fun () ->
    let dated = Jsonl_writer.dated_path_now ~base_dir:t.base_dir in
    let row_bytes = String.length (Yojson.Safe.to_string json) + 1 in
    let current_bytes = file_size dated.path in
    let placement =
      if
        max_current_file_bytes <= 0
        || current_bytes + row_bytes <= max_current_file_bytes
      then Some Appended_to_current
      else if current_bytes = 0
      then
        (* A single row larger than the cap: rotating an empty file out
           would spin forever without ever accepting the row. The row
           lands, the segment runs oversized once, and the next append
           rotates it out. *)
        Some Appended_to_current
      else begin
        let month_path = Filename.dirname dated.path in
        let day_prefix = day_number_of_day_file_name dated.day_file in
        let sequence = next_rotation_sequence ~month_path ~day_prefix in
        if sequence > max_rotation_sequence
        then None
        else begin
          let segment = rotated_segment_name ~day_prefix ~sequence in
          (* Same pre-rename steps as [prepare_for_directory_removal]:
             drop the cached writer for the old identity, and drop the
             file-count entry — a fresh file that regrows to exactly
             the cached byte boundary would otherwise serve the
             rotated-out file's count. *)
          Fs_compat.invalidate_cached_writer dated.path;
          Stdlib.Mutex.protect file_count_cache_mu (fun () ->
            Hashtbl.remove file_count_cache dated.path);
          Sys.rename dated.path (Filename.concat month_path segment);
          Some (Appended_after_rotation { segment })
        end
      end
    in
    match placement with
    | None ->
      Skipped_rotation_exhausted { sequence_limit = max_rotation_sequence }
    | Some outcome ->
      Jsonl_writer.append_jsonl ~path:dated.path json;
      run_post_append_pruning_unlocked t ~dated;
      outcome)

let append_rotating t ~max_current_file_bytes json =
  let outcome = ref Skipped_by_append_guard in
  (Atomic.get append_guard) (fun () ->
    outcome := append_rotating_unlocked t ~max_current_file_bytes json);
  !outcome

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
(* Range counterpart to [filter_map_recent]: the caller's projection runs per
   row so the parsed tree is unreachable before the next row is read, and
   [read_range_recent] is this with an identity projection.

   [f] runs outside the parse [try] for the same reason as in
   [filter_map_recent]: the reader swallows [Yojson.Json_error] to skip
   malformed rows and a caller's decoder must not inherit that swallow. *)
let filter_map_range_recent ?(offset = 0) t ~since ~until n ~f =
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
                     let day_num = day_number_of_day_file_name d in
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
                            let parsed =
                              try Some (Yojson.Safe.from_string line)
                              with Yojson.Json_error _ -> None
                            in
                            match parsed with
                            | None -> ()
                            | Some json ->
                              if !skip > 0
                              then decr skip
                              else begin
                                (match f json with
                                 | Some value -> collected := value :: !collected
                                 | None -> ());
                                incr count
                              end)
                         rev_lines
                     end)
                  days
              end)
           months
       with
       | Done -> ());
      !collected)

let read_range_recent ?offset t ~since ~until n =
  filter_map_range_recent ?offset t ~since ~until n ~f:(fun json -> Some json)
;;

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

end
