(** Date and segment naming are a pure contract shared by scans, rotation,
    pruning and strict layout validation. Filesystem effects stay here. *)
open Dated_jsonl_layout
module Store = Dated_jsonl_store
module Layout = Dated_jsonl_layout

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
  location : Store.location;
  base_dir : string;
  max_bytes : int option;
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

(* A day file of a store, by the names the layout gives it. *)
type place =
  { month_dir : string
  ; day_file : string
  }

(* The order the strict reads visit day files in, oldest first: months by
   name, as [list_month_dirs_result] sorts them, and the files of a month as
   [list_day_entries_result] does. *)
let compare_places left right =
  match String.compare left.month_dir right.month_dir with
  | 0 -> compare_day_files left.day_file right.day_file
  | order -> order
;;

(* A row an append put at the end of a day file: the row as the strict reads
   decode it, its line as they read it (the text without its newline), the
   file, and the store's directory. *)
type written =
  { row : recent_entry Lazy.t
  ; line : string
  ; place : place
  ; store_dir : string
  }

(* A fact's value, and the newest day file the value saw a row in. A row
   written to a file older than that one is not the store's newest row. *)
type 'a held =
  { value : 'a
  ; newest : place option
  }

(* A fact about a store that is kept in memory beside the store's files
   (RFC "Keeper row facts are kept in memory by their writers"). [read] gives
   the value from the files and is the only definition of it; [step] gives the
   value after one more row from the value before it, or [None] when the row
   alone does not tell. *)
type 'a fact =
  { id : 'a Type.Id.t
  ; name : string (* the [fact] label of the fact's read counter *)
  ; read : t -> ('a held, read_error) result
  ; step : 'a -> written -> 'a option
  }

type kept = Kept : 'a fact * 'a held Fact_cell.t -> kept

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

(* One entry for each store directory, under the name the file system gives
   the directory ([File_system_named]): the mutex its writers take and the
   facts kept in memory about it. A handle holds no entry: it asks for its
   store's each time it writes, prunes or reads a fact. The handles of a
   Keeper's stores are kept for the life of the process, and an entry chosen
   when a handle was opened would stay with the spelling even after the
   directory came to exist under another one.

   [kept] only grows, by a compare-and-set, and only a reader of a fact adds
   to it ([cell_of_entry]). Whoever writes or removes files goes through the
   cells that are there and makes none. *)
type entry =
  { mutex : Cross_context_mutex.t
  ; kept : kept list Atomic.t
  }

let registry : entry File_system_named.t =
  File_system_named.create (fun () ->
    { mutex = Cross_context_mutex.create (); kept = Atomic.make [] })

let resolve location = File_system_named.resolve registry (Store.absolute_dir location)
let store_mutex t = (resolve t.location).File_system_named.entry.mutex

let forget_kept entry =
  List.iter (fun (Kept (_, cell)) -> Fact_cell.forget cell) (Atomic.get entry.kept)

(* After a change of the store's files made under [resolved.entry]: the
   directory may by now be another entry's, and the change then went by that
   entry's cells unseen ([File_system_named.another_entry_now]). *)
let forget_kept_of_the_directory resolved location =
  match
    File_system_named.another_entry_now registry resolved (Store.absolute_dir location)
  with
  | None -> ()
  | Some now ->
    forget_kept now;
    forget_kept resolved.File_system_named.entry

(* Store directories were removed by code outside this module. Every
   remembered name and every kept fact goes: which directories went is not
   looked at, and neither is whether the removal succeeded. *)
let directories_removed () =
  File_system_named.removed registry;
  List.iter forget_kept (File_system_named.entries registry)

let open_store ?max_bytes location =
  let base_dir = Store.dir location in
  let max_bytes =
    match max_bytes with
    | Some bytes when bytes > 0 -> Some bytes
    | _ -> None
  in
  {
    location;
    base_dir;
    max_bytes;
  }

let base_dir t = t.base_dir

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

(** Current and completed day files, newest first. *)
let list_day_files month_path =
  list_subdirs month_path
  |> List.filter (fun f -> Filename.check_suffix f ".jsonl")
  |> List.sort (fun left right -> compare_day_files right left)

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
  let open Result.Syntax in
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
  let open Result.Syntax in
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

(* The store's side files sit among the month directories and belong to
   the store, so they are passed over by name. They are never opened here. *)
let list_month_dirs_result t =
  let open Result.Syntax in
  let* entries = list_directory_result ~missing_is_empty:true t.base_dir in
  let is_side_file = Store.is_side_file (Store.of_location t.location) in
  validate_layout_entries
    ~parent:t.base_dir
    ~expected:Month_directory
    ~is_valid:month_directory_name_is_valid
    (List.filter (fun entry -> not (is_side_file entry)) entries)
;;

let list_day_entries_result month_path =
  let open Result.Syntax in
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
  let* days =
    validate_layout_entries
      ~parent:month_path
      ~expected:Day_file
      ~is_valid:(day_file_name_is_valid ~year ~month)
      entries
  in
  Ok (entries, List.sort (fun left right -> compare_day_files right left) days)
;;

let list_day_files_result month_path =
  list_day_entries_result month_path |> Result.map snd
;;

let month_dir_paths_newest_first_result t =
  list_month_dirs_result t
  |> Result.map (List.map (Filename.concat t.base_dir))
;;

let day_file_paths_newest_first_result month_path =
  list_day_files_result month_path
  |> Result.map (List.map (Filename.concat month_path))
;;

let compare_day_file_names = compare_day_files

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
      Fs_compat.Input.with_open ~path ~open_input:open_in_bin (fun ic ->
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
      Fs_compat.Input.with_open ~path ~open_input:open_in_bin (fun ic ->
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

(* Conversion is still part of admission: a rejected raw descriptor must be
   settled before leaving the path mutex, with its original exception intact. *)
let input_channel_of_descriptor descriptor =
  match Unix.in_channel_of_descr descriptor with
  | input -> input
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    close_file_descriptor_noerr descriptor;
    Printexc.raise_with_backtrace exn backtrace
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
  let open Result.Syntax in
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
                   Ok (input_channel_of_descriptor descriptor))))))
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

type tail_row =
  { offset : int
  ; line : string
  }

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
let last_non_empty_rows buffer ~base ~max_lines =
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
         else
           ( seen + 1
           , { offset = base + start; line = Bytes.sub_string buffer start (stop - start) }
             :: acc ))
      (0, [])
  in
  List.rev reversed

let load_tail_rows_from_channel input ~max_lines =
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
      last_non_empty_rows combined ~base:!position ~max_lines
    end
;;

let tail_lines rows = List.map (fun row -> row.line) rows

(* One day file's tail read, split and parse is a single job on the process
   domain pool when one is installed: the reads are blocking syscalls, the
   scan and the parse are CPU work, and none of it touches the calling
   fiber's state. Without a pool, from a non-Eio context, or from a pool
   worker it runs inline as before. Measured 2026-09-05: on a live keeper
   these reads were about a tenth of the main thread's busy time and the
   longest runs outside turn spans (RFC main-domain-scheduler-latency
   section 8.8). *)
let off_fiber ~name f = Domain_pool_ref.submit_io_or_inline ~name f

(* The pool job's name for a read of [t]'s store. A read given
   only a path is named by the function that reads it. *)
let job_name t = "dated_jsonl:" ^ Store.pool_job_name (Store.of_location t.location)

(* A file removed between the existence check and the open is a missing file,
   which reads as an empty tail. *)
let load_tail_rows_inline path ~max_lines =
  if max_lines <= 0 || not (Fs_compat.file_exists path)
  then []
  else
    let open_input path =
      match open_in_bin path with
      | input -> Ok input
      | exception Sys_error _ when not (Fs_compat.file_exists path) -> Error ()
    in
    match Fs_compat.Input.with_open_result ~path ~open_input
      (fun input -> Ok (load_tail_rows_from_channel input ~max_lines)) with
    | Ok rows -> rows
    | Error () -> []
;;

let load_tail_lines_inline path ~max_lines =
  tail_lines (load_tail_rows_inline path ~max_lines)
;;

let map_tail_rows_as ~name path ~max_lines ~f =
  off_fiber ~name (fun () -> List.map f (load_tail_rows_inline path ~max_lines))

let map_tail_rows path ~max_lines ~f = map_tail_rows_as ~name:__FUNCTION__ path ~max_lines ~f
;;

let load_tail_rows path ~max_lines = map_tail_rows path ~max_lines ~f:Fun.id

let load_tail_lines path ~max_lines =
  map_tail_rows path ~max_lines ~f:(fun row -> row.line)
;;

let tail_rows_of_input_result ~path input ~max_lines =
  match load_tail_rows_from_channel input ~max_lines with
  | rows -> Ok rows
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
    Error (Io_error { operation = Read_file; path; detail })
;;

let load_tail_lines_result_inline path ~max_lines =
  if max_lines <= 0
  then Ok []
  else
    Fs_compat.Input.with_open_result ~path ~open_input:open_regular_input_result
      (fun input -> tail_rows_of_input_result ~path input ~max_lines |> Result.map tail_lines)
;;

type tail_input_rejection =
  | Missing_tail_file
  | Tail_input_error of read_error

let open_tail_input_result path =
  match Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0 with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Error Missing_tail_file
  | exception Unix.Unix_error (error, _, _) ->
    Error (Tail_input_error
      (Io_error { operation = Open_file; path; detail = Unix.error_message error }))
  | descriptor ->
    let reject error =
      close_file_descriptor_noerr descriptor;
      Error (Tail_input_error error)
    in
    (match Unix.fstat descriptor with
     | exception Unix.Unix_error (error, _, _) ->
       reject (Io_error { operation = Inspect; path; detail = Unix.error_message error })
     | stats ->
       match non_regular_file_kind_of_stats stats with
       | Some kind -> reject (Non_regular_file { path; kind })
       | None -> Ok (input_channel_of_descriptor descriptor))
;;

(* The open itself tells a missing file from one that cannot be opened, so no
   existence check stands between the two. The path is followed as
   [load_tail_rows_inline] follows it; what was opened is then inspected. *)
let load_tail_rows_result_inline path ~max_lines =
  if max_lines <= 0
  then Ok []
  else
    match Fs_compat.Input.with_open_result ~path ~open_input:open_tail_input_result
      (fun input -> tail_rows_of_input_result ~path input ~max_lines
        |> Result.map_error (fun error -> Tail_input_error error)) with
    | Ok rows -> Ok rows
    | Error Missing_tail_file -> Ok []
    | Error (Tail_input_error error) -> Error error
;;

let map_tail_rows_result path ~max_lines ~f =
  off_fiber ~name:__FUNCTION__ (fun () ->
    load_tail_rows_result_inline path ~max_lines |> Result.map (List.map f))
;;

(* A physical line as the strict reads parse it. The result does not depend on
   the file the line is in, so an append parses its row before it takes the
   store's mutex. *)
let parse_line line =
  match Yojson.Safe.from_string line with
  | json -> Ok json
  | exception Yojson.Json_error detail -> Error detail
;;

let recent_entry_of_parsed ~path ?line_number = function
  | Ok json -> Parsed json
  | Error detail -> Malformed_json { path; line_number; detail }
;;

let recent_entry_of_line ~path ?line_number line =
  recent_entry_of_parsed ~path ?line_number (parse_line line)
;;

let entry_of_physical_line ~path line =
  if line_is_non_empty line then Some (recent_entry_of_line ~path line) else None
;;

(* One step of a backwards scan: read the bytes that end at [scan_position]
   and return the lines they close, decoded, newest first, with the state for
   the next step. Each step is one job on the domain pool through
   [off_fiber]; the caller applies its own filter on the fiber and asks for
   the next step only when nothing matched, so a match in the newest chunk
   costs one job and no caller closure leaves the fiber.

   A line that has not reached its start yet is kept as the pieces read so
   far, in file order, and joined once when its newline is found. Joining the
   pieces on every step copied such a line once per chunk: reading a 900 KB
   provider-input row in 8 KB chunks allocated 52 MB, and those scans were a
   fifth of a live server's allocation on 2026-09-16. A step that
   finds no newline doubles the next read, so a long line also takes a
   logarithmic number of jobs; the step after a newline reads [chunk_size]
   again. *)
type scan_state =
  { scan_position : int
  ; read_size : int
  ; unfinished_line : string list
    (** The pieces, in file order, of the line that ends at the previous
        step's read. None of them holds a newline. *)
  }

let scan_step ?(lower_bound = 0) input ~chunk_size ~decode { scan_position = position; read_size; unfinished_line } =
  let decode_newest_first lines =
    List.fold_left
      (fun acc line -> if line_is_non_empty line then decode line :: acc else acc)
      []
      lines
  in
  let close_line first_piece = String.concat "" (first_piece :: unfinished_line) in
  if position <= lower_bound
  then decode_newest_first [ String.concat "" unfinished_line ], None
  else begin
    let read_start = max lower_bound (position - read_size) in
    let read_len = position - read_start in
    seek_in input read_start;
    let chunk = really_input_string input read_len in
    match String.index_opt chunk '\n' with
    | None when read_start = lower_bound -> decode_newest_first [ close_line chunk ], None
    | None ->
      ( []
      , Some
          { scan_position = read_start
          ; read_size = 2 * read_size
          ; unfinished_line = chunk :: unfinished_line
          } )
    | Some first_newline ->
      let last_newline = String.rindex chunk '\n' in
      let between =
        if last_newline > first_newline
        then
          String.split_on_char
            '\n'
            (String.sub chunk (first_newline + 1) (last_newline - first_newline - 1))
        else []
      in
      let closed =
        close_line (String.sub chunk (last_newline + 1) (read_len - last_newline - 1))
      in
      let leading = String.sub chunk 0 first_newline in
      if read_start = lower_bound
      then decode_newest_first ((leading :: between) @ [ closed ]), None
      else
        ( decode_newest_first (between @ [ closed ])
        , Some
            { scan_position = read_start
            ; read_size = chunk_size
            ; unfinished_line = [ leading ]
            } )
  end
;;

let find_latest_decoded_from_channel ?(from = 0) ?until input ~decode f =
  let chunk_size = 8192 in
  let rec drive state =
    let decoded_newest_first, next =
      off_fiber ~name:__FUNCTION__ (fun () -> scan_step ~lower_bound:from input ~chunk_size ~decode state)
    in
    match List.find_map f decoded_newest_first with
    | Some _ as found -> found
    | None ->
      (match next with
       | None -> None
       | Some state -> drive state)
  in
  drive
    { scan_position = (match until with Some position -> position | None -> in_channel_length input)
    ; read_size = chunk_size
    ; unfinished_line = []
    }
;;

let find_latest_entry_in_file_result path f =
  Fs_compat.Input.with_open_result ~path ~open_input:open_regular_input_result
      (fun input ->
         match
           find_latest_decoded_from_channel
             input
             ~decode:(fun line -> recent_entry_of_line ~path line)
             f
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

let prune_bound_directory ~location ~days directory =
  if days <= 0 then 0
  else
    (* NDT-OK: the operator/store retention declaration owns this wall-clock cutoff. *)
    let cutoff = Unix.gettimeofday () -. (float_of_int days *. Masc_time_constants.day) in
    (* The writer owns the calendar spelling (#27143). *)
    let cutoff_path = Store.dated_path location ~ts:cutoff in
    Dated_jsonl_retention.prune
      ~cutoff_month:cutoff_path.Store.month_dir
      ~cutoff_day:(Filename.remove_extension cutoff_path.Store.day_file) directory

let prune_unlocked t ~days =
  if days <= 0 then 0
  else Store.with_retention_location t.location (prune_bound_directory ~location:t.location ~days)

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

(* Shared post-append maintenance for every append entry point: a
   best-effort byte-budget prune that never touches the current day file.
   Divergence between append paths here would give the same store two
   different size limits, so both call this one helper. Removing day files
   by age is the prune pass's job ([prune_listed_stores_bound]). *)
let run_post_append_pruning_unlocked t ~(dated : Store.dated_path) =
  match t.max_bytes with
  | None -> `Kept_every_file
  | Some max_bytes ->
    (* See byte-budget pruning is best-effort cleanup after append. *)
    if prune_to_max_bytes_unlocked t ~max_bytes ~keep_path:dated.path > 0
    then `Removed_files
    else `Kept_every_file

(* ── The facts kept in memory, on the write side ─────────

   An append sees every cell of the store before it changes a file and
   settles each one after its row is on disk, both under the store's mutex,
   so two appends never interleave here. A reader that fills a cell and a
   caller that removes files take no mutex; the cells themselves arbitrate
   ([Fact_cell]). *)

type seen = Seen : 'a fact * 'a held Fact_cell.t * 'a held Fact_cell.seen -> seen

type seen_before_change =
  { kept_then : kept list
  ; cells : seen list
  }

let see_kept entry =
  let kept_then = Atomic.get entry.kept in
  { kept_then
  ; cells =
      List.map (fun (Kept (fact, cell)) -> Seen (fact, cell, Fact_cell.see cell)) kept_then
  }

(* A value after [written]. The row is the store's newest only when no day
   file after its own holds a row; [held.newest] is the newest file the value
   saw one in. A clock that went back puts the row in an older file, and what
   the strict reads then answer is not told by the row. *)
let after_row fact written held =
  match held.newest with
  | Some newest when compare_places written.place newest < 0 -> None
  | Some _ | None ->
    (match fact.step held.value written with
     | Some value -> Some { value; newest = Some written.place }
     | None -> None
     | exception ((Out_of_memory | Stack_overflow) as exn) -> raise exn
     | exception exn ->
       (* The row is on disk whatever a step does. A step that raises has
          not told the value, which is [None]'s meaning; raising from here
          would report a committed row as a failed append. *)
       Log.Misc.error
         "dated JSONL fact step raised, the fact is read from the files again: %s"
         (Printexc.to_string exn);
       None)

let settle_kept entry before written =
  List.iter
    (fun (Seen (fact, cell, seen)) ->
       Fact_cell.settle cell seen ~step:(after_row fact written))
    before.cells;
  (* A cell made while the row was being written was not seen before it. A
     fill of that cell can have read the files without the row. *)
  if Atomic.get entry.kept != before.kept_then then forget_kept entry

let written_row ~(dated : Store.dated_path) ~line parsed =
  { row = lazy (recent_entry_of_parsed ~path:dated.path (Lazy.force parsed))
  ; line
  ; place = { month_dir = dated.month_dir; day_file = dated.day_file }
  ; store_dir = dated.base_dir
  }

(* The row's text, rendered once: what goes to disk, and what the facts are
   told about, read back the way the strict reads read it. It is parsed
   before the mutex is taken when the store keeps a fact; a fact that appears
   after that look is parsed under the mutex, once. *)
type rendered =
  { line : string
  ; rows : string
  ; parsed : (Yojson.Safe.t, string) result Lazy.t
  }

let render entry json =
  let line = Yojson.Safe.to_string json in
  let parsed = lazy (parse_line line) in
  (match Atomic.get entry.kept with
   | [] -> ()
   | _ :: _ -> ignore (Lazy.force parsed : (Yojson.Safe.t, string) result));
  { line; rows = line ^ "\n"; parsed }

(* Run [change], which changes the store's files under the store's mutex and
   keeps the cells right itself while it returns. When it raises, the files
   may or may not have changed, so the store's facts are forgotten. Either
   way the directory may have turned out to be another entry's. *)
let changing_files t change =
  let resolved = resolve t.location in
  match change resolved.File_system_named.entry with
  | result ->
    forget_kept_of_the_directory resolved t.location;
    result
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    forget_kept resolved.File_system_named.entry;
    forget_kept_of_the_directory resolved t.location;
    Printexc.raise_with_backtrace exn backtrace

(* Run [removal], which removes files of the store, and forget the store's
   facts on every way out of it: how many files went and whether it
   succeeded are not looked at. *)
let removing_files t removal =
  changing_files t (fun entry ->
    let result = Cross_context_mutex.with_lock entry.mutex removal in
    forget_kept entry;
    result)

let append_unlocked ~on_committed t json =
  (* [Fs_compat.append_jsonl_rows] provides per-path cross-domain atomicity
     through its own mutex registry and cached descriptor. *)
  (* [append] reaches here from OS threads too: the audit log is written from
     [Thread.create] workers, where an [Eio.Mutex] waits through an effect the
     thread has no handler for. That raises [Stdlib.Effect.Unhandled] inside
     the thread and kills it before the row lands. [Eio_guard.with_mutex_ro]
     only serializes a real fiber and raises for the rest, so the
     cross-context gate is what covers both: a fiber yields cooperatively and
     a raw thread takes the Stdlib mutex. *)
  changing_files t (fun entry ->
    let rendered = render entry json in
    Cross_context_mutex.with_lock entry.mutex (fun () ->
      let dated = Store.dated_path_now t.location in
      let before = see_kept entry in
      Fs_compat.append_jsonl_rows dated.path rendered.rows;
      (* The facts first, then the caller's acknowledgement: whoever the
         acknowledgement wakes reads the facts with the row in them. *)
      settle_kept entry before (written_row ~dated ~line:rendered.line rendered.parsed);
      on_committed ();
      match run_post_append_pruning_unlocked t ~dated with
      | `Kept_every_file -> ()
      | `Removed_files -> forget_kept entry))

let append_inner t json = append_unlocked ~on_committed:ignore t json

let append t json =
  (Atomic.get append_guard) (fun () -> append_inner t json)

exception Append_guard_skipped

let append_notifying_commit t json ~on_committed =
  let committed = ref false in
  (Atomic.get append_guard) (fun () ->
    append_unlocked t json ~on_committed:(fun () ->
      committed := true;
      on_committed ()));
  if not !committed then raise Append_guard_skipped

(* Scan persisted identities so reopening a pruned store keeps progressing.
   Never wrap an overflowing integer onto an existing segment. *)
let next_rotation_sequence ~month_path ~day_prefix =
  let highest =
    list_subdirs month_path
    |> List.fold_left (fun highest name ->
      match day_file_parts name with
      | Some (day, Some sequence) when String.equal day day_prefix -> max highest sequence
      | Some (_, Some _) | Some (_, None) | None -> highest) 0
  in
  if highest = max_int then None else Some (highest + 1)

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
   inherit that swallow.

   [day_files] are the paths to visit, newest first. [before_read] sees each
   path just before that file is read. *)
let filter_map_recent_over ?(offset=0) t n ~f ~before_read day_files =
  if n <= 0 then []
  else begin
    let skip = ref offset in
    let collected = ref [] in
    let count = ref 0 in
    let exception Done in
    (try
       Seq.iter (fun path ->
           if !count >= n then raise_notrace Done;
           let need = n - !count + !skip in
           (* [need] lines is enough only when every one of them parses. A
              malformed row inside the window used to take a row's place and
              shrink the answer without saying so: read_recent 2 over
              1, 2, 3 and a trailing unparseable row returned one entry.
              The .mli splits the two readings -- here [n] counts parsed
              rows, and read_recent_result is the reader whose limit counts
              physical rows including malformed ones -- so widen the window
              and read the file again until it yields [need] parsed rows or
              runs out of lines. A file with no malformed rows settles on
              the first round, which is every call this had before. *)
           before_read path;
           let parsed_newest_first =
             off_fiber ~name:(job_name t) (fun () ->
               let rec read_widening window =
                 let lines = load_tail_lines_inline path ~max_lines:window in
                 let parsed =
                   List.rev_map
                     (fun line ->
                        try Some (Yojson.Safe.from_string line)
                        with Yojson.Json_error _ -> None)
                     lines
                 in
                 let parsed_count =
                   List.fold_left
                     (fun acc entry -> if Option.is_some entry then acc + 1 else acc)
                     0
                     parsed
                 in
                 (* Fewer lines than asked for means the file is exhausted and
                    a wider window would read the same thing again. *)
                 if parsed_count >= need
                    || List.length lines < window
                    (* Doubling past this wraps to a negative window, which
                       reads nothing and never reaches the exhausted test. *)
                    || window > max_int / 2
                 then parsed
                 else read_widening (window * 2)
               in
               read_widening need)
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
       ) day_files
     with Done -> ());
    !collected
  end

(* Day files newest first; each month is listed only when the walk reaches
   it, so a read that fills its window in the newest month lists no other. *)
let day_files_newest_first_on_demand t =
  List.to_seq (list_month_dirs t.base_dir)
  |> Seq.flat_map (fun month ->
    let month_path = Filename.concat t.base_dir month in
    Seq.map (Filename.concat month_path) (List.to_seq (list_day_files month_path)))

let filter_map_recent ?offset t n ~f =
  filter_map_recent_over ?offset t n ~f ~before_read:ignore
    (day_files_newest_first_on_demand t)

(* A recent read kept per store until the store's files change. Day files
   only grow by appending and leave by whole-file removal, so the newest [n]
   parsed rows are a function of the day-file list and of the files the read
   opened. When the list is the same and each opened file is still the same
   file (device, inode) with the same size and modification time, the
   previous answer is the answer.

   The read walks the very list the answer is kept under: listing twice let a
   second listing that failed quietly (a month read as empty when the process
   ran out of descriptors) leave a short answer under a complete list. The
   list is taken with the listing functions that report errors, and a failed
   listing keeps nothing. Each file's identity is taken just before its bytes
   are read: a row appended during the read leaves the recorded identity
   behind the bytes the answer saw, so the next call reads again. A file
   whose identity cannot be taken keeps the answer out. Every race costs one
   more read, never a stale answer. *)
type file_identity =
  { fi_device : int
  ; fi_inode : int
  ; fi_size : int
  ; fi_modified_at : float
  }

let identity_if_present path =
  match Unix.stat path with
  | stats ->
    Some
      { fi_device = stats.Unix.st_dev
      ; fi_inode = stats.Unix.st_ino
      ; fi_size = stats.Unix.st_size
      ; fi_modified_at = stats.Unix.st_mtime
      }
  | exception Unix.Unix_error _ -> None

let equal_file_identity left right =
  Int.equal left.fi_device right.fi_device
  && Int.equal left.fi_inode right.fi_inode
  && Int.equal left.fi_size right.fi_size
  && Float.equal left.fi_modified_at right.fi_modified_at

type 'a recent_answer =
  { ra_day_files : string list
  ; ra_read_files : (string * file_identity) list
  ; ra_values : 'a list
  }

type 'a recent_view =
  { rv_rows : int
  ; rv_project : Yojson.Safe.t -> 'a option
  ; rv_mu : Stdlib.Mutex.t
  ; rv_answers : (string, 'a recent_answer) Hashtbl.t
  }

let recent_view n ~f =
  { rv_rows = n
  ; rv_project = f
  ; rv_mu = Stdlib.Mutex.create ()
  ; rv_answers = Hashtbl.create 64
  }

let recent_answer_is_current answer ~day_files =
  List.equal String.equal answer.ra_day_files day_files
  && List.for_all
       (fun (path, identity) ->
          Option.equal equal_file_identity (identity_if_present path) (Some identity))
       answer.ra_read_files

(* Every month's day files, newest first, from listings that all succeeded. *)
let day_file_paths_newest_first_listed t =
  let open Result.Syntax in
  let* months = month_dir_paths_newest_first_result t in
  let rec collect newest_first_by_month = function
    | [] -> Ok (List.concat (List.rev newest_first_by_month))
    | month :: older ->
      let* days = day_file_paths_newest_first_result month in
      collect (days :: newest_first_by_month) older
  in
  collect [] months

(* Counts have always included every .jsonl name; recent views ignore foreign
   dotfiles. Keep both selections from the same successful directory reads so
   switching to permissive fallback does not add previously omitted dotfiles
   to the count. *)
let day_file_paths_for_summary t =
  let open Result.Syntax in
  let* months = month_dir_paths_newest_first_result t in
  let rec collect count_parts recent_parts = function
    | [] -> Ok (List.concat (List.rev count_parts), List.concat (List.rev recent_parts))
    | month :: older ->
      let* entries, days = list_day_entries_result month in
      let counted =
        entries
        |> List.filter (fun name -> Filename.check_suffix name ".jsonl")
        |> List.sort (fun left right -> compare_day_files right left)
        |> List.map (Filename.concat month)
      in
      let recent = List.map (Filename.concat month) days in
      collect (counted :: count_parts) (recent :: recent_parts) older
  in
  collect [] [] months

let read_recent_view_over view t day_files =
  let kept =
    Stdlib.Mutex.protect view.rv_mu (fun () ->
      Hashtbl.find_opt view.rv_answers t.base_dir)
  in
  match kept with
  | Some answer when recent_answer_is_current answer ~day_files -> answer.ra_values
  | Some _ | None ->
    let read_files = ref [] and every_file_identified = ref true in
    let values =
      filter_map_recent_over t view.rv_rows ~f:view.rv_project
        ~before_read:(fun path ->
          match identity_if_present path with
          | Some identity -> read_files := (path, identity) :: !read_files
          | None -> every_file_identified := false)
        (List.to_seq day_files)
    in
    if !every_file_identified then
      Stdlib.Mutex.protect view.rv_mu (fun () ->
        Hashtbl.replace view.rv_answers t.base_dir
          { ra_day_files = day_files; ra_read_files = !read_files; ra_values = values });
    values

let read_recent_view view t =
  match day_file_paths_newest_first_listed t with
  | Error _ -> filter_map_recent t view.rv_rows ~f:view.rv_project
  | Ok day_files -> read_recent_view_over view t day_files

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
               let open_input path =
                 match Unix.openfile path [ Unix.O_RDONLY ] 0 with
                 | descriptor -> Ok (input_channel_of_descriptor descriptor)
                 | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Error ()
               in
               (match Fs_compat.Input.with_open_result ~path ~open_input
                 (fun input ->
                    (* See [find_latest_decoded_from_channel]: only its selected value matters. *)
                    ignore
                      (find_latest_decoded_from_channel
                         input
                         ~decode:(fun line ->
                           try Some (Yojson.Safe.from_string line)
                           with Yojson.Json_error _ -> None)
                         (fun parsed ->
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
                              end)));
                    Ok ()) with
               | Ok () -> ()
               | Error () ->
                 (* Retention snapshots names before reading them. A later
                    day or its month may disappear after a newer day's
                    callback yields. Other open failures stay observable. *)
                 Log.Misc.debug
                   "dated_jsonl: skipped day file removed during scan path=%s"
                   path;
                 ())
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

let read_recent_using_result ?(offset=0) t n ~decode =
  if offset < 0
  then Error (Invalid_offset { offset })
  else if n <= 0
  then Ok []
  else
    let open Result.Syntax in
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
          off_fiber ~name:(job_name t) (fun () ->
            load_tail_lines_result_inline path ~max_lines:(requested_line_count ())
            |> Result.map (List.rev_map (fun line -> decode ~path line)))
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
    let* months = list_month_dirs_result t in
    let* () = visit_months months in
    Ok !collected
;;

let read_recent_result ?offset t n =
  read_recent_using_result ?offset t n
    ~decode:(fun ~path line -> recent_entry_of_line ~path line)
;;

let read_recent_lines_result ?offset t n =
  read_recent_using_result ?offset t n ~decode:(fun ~path line -> path, line)
;;

(* The first value [f] selects, newest row first, with the day file its row
   is in. *)
let find_latest_entry_with_its_file_result t f =
  let open Result.Syntax in
  let rec visit_days month_path = function
    | [] -> Ok None
    | day :: rest ->
      let path = Filename.concat month_path day in
      let* found = find_latest_entry_in_file_result path f in
      (match found with
       | Some value -> Ok (Some (value, path))
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
  let* months = list_month_dirs_result t in
  visit_months months
;;

let find_latest_entry_result t f =
  Result.map (Option.map fst) (find_latest_entry_with_its_file_result t f)
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
           let lines = map_tail_rows_as ~name:(job_name t) path ~max_lines:need
                         ~f:(fun row -> row.line) in
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
  Fs_compat.Input.with_open_result ~path ~open_input:open_regular_input_result
      (fun input ->
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
  let open Result.Syntax in
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
  let* months = list_month_dirs_result t in
  iter_months (List.rev months)
;;

let fold_range_file_paths_result t ~since ~until ~init ~f =
  let open Result.Syntax in
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
    let rec iter_days acc month month_path = function
      | [] -> Ok acc
      | day :: rest ->
        let* acc =
          if day_in_range month day
          then f acc (Filename.concat month_path day)
          else Ok acc
        in
        iter_days acc month month_path rest
    in
    let rec iter_months acc = function
      | [] -> Ok acc
      | (month, year, month_number) :: rest ->
        let month_path = Filename.concat t.base_dir month in
        let* days =
          list_directory_result ~missing_is_empty:false month_path
        in
        let selected_days =
          days
          |> List.filter (day_file_name_is_valid ~year ~month:month_number)
          |> List.filter (day_in_range month)
          |> List.sort compare_day_files
        in
        let* acc = iter_days acc month month_path selected_days in
        iter_months acc rest
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
    |> iter_months init
;;

let range_day_file_paths_result t ~since ~until =
  fold_range_file_paths_result t ~since ~until ~init:[]
    ~f:(fun paths path -> Ok (path :: paths))
  |> Result.map List.rev
;;

let iter_range_entries_result t ~since ~until f =
  fold_range_file_paths_result t ~since ~until ~init:()
    ~f:(fun () path -> iter_json_file_entries_result path f)
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

let close t =
  let dated = Store.dated_path_now t.location in
  Fs_compat.invalidate_cached_writer dated.path
;;

let prepare_for_directory_removal t =
  let dated = Store.dated_path_now t.location in
  close t;
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

(* Per-file-cached full count. Every retained file is listed and statted;
   only appended bytes are read from files whose cached boundary grew. *)
let count_entries_incremental t =
  fold_day_file_counts t ~counter:count_non_empty_lines_cached

(* The RFC-0162 §3.2 10s-TTL store-level cache that used to sit here is
   removed: the boundary-keyed cache bounds content reads to appended bytes.
   Metadata still scales with retained file count; a TTL would hide changes
   by external writers rather than remove that work while staying current. *)
let count_entries = count_entries_incremental

let count_and_read_recent_view view t =
  match day_file_paths_for_summary t with
  | Error _ ->
    let count = count_entries t in
    count, filter_map_recent t view.rv_rows ~f:view.rv_project
  | Ok (counted_files, recent_files) ->
    let count = List.fold_left
      (fun total path -> total + count_non_empty_lines_cached path) 0 counted_files in
    count, read_recent_view_over view t recent_files
;;

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

let count_cache_filename = "dated-jsonl-count-cache.json"

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

let append_rotating_unlocked ~on_committed t ~max_current_file_bytes json =
  changing_files t (fun entry ->
    let rendered = render entry json in
    Cross_context_mutex.with_lock entry.mutex (fun () ->
    let dated = Store.dated_path_now t.location in
    let row_bytes = String.length rendered.rows in
    let current_bytes = file_size dated.path in
    (* Before the rename: rotating the current file out is a change of the
       store's files too. The rows keep their order across it, so the row
       appended after it is still the newest. *)
    let before = see_kept entry in
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
        match next_rotation_sequence ~month_path ~day_prefix with
        | None -> None
        | Some sequence -> begin
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
      (* Nothing was renamed and nothing was written: the facts stand. *)
      Skipped_rotation_exhausted { sequence_limit = max_int }
    | Some outcome ->
      Fs_compat.append_jsonl_rows dated.path rendered.rows;
      settle_kept entry before (written_row ~dated ~line:rendered.line rendered.parsed);
      on_committed ();
      (match run_post_append_pruning_unlocked t ~dated with
       | `Kept_every_file -> ()
       | `Removed_files -> forget_kept entry);
      outcome))

let append_rotating ?(on_committed = ignore) t ~max_current_file_bytes json =
  let outcome = ref Skipped_by_append_guard in
  (Atomic.get append_guard) (fun () ->
    outcome := append_rotating_unlocked ~on_committed t ~max_current_file_bytes json);
  !outcome

let read_range t ~since ~until =
  let collected = ref [] in
  iter_range t ~since ~until (fun json -> collected := json :: !collected);
  List.rev !collected

(* The day files a range covers, oldest first, without opening any of them.
   [iter_range] answers what the rows are; a caller that keeps its own
   accumulator between calls needs to know which files it read and how far,
   and that is a different question. Same day-selection rule as [iter_range],
   from the same code, so a file this returns is a file that would have been
   iterated.

   Callers: [fold_range_appended] below. Exported because a store is
   append-only per day file, so an incremental reader outside this module can
   only exist if it can name them. *)
let range_day_file_paths t ~since ~until =
  match parse_date since, parse_date until with
  | None, _ | _, None -> []
  | Some (since_month, since_day), Some (until_month, until_day) ->
    list_month_dirs t.base_dir
    |> List.filter (fun m ->
      String.compare m since_month >= 0 && String.compare m until_month <= 0)
    |> List.concat_map (fun m ->
      let month_path = Filename.concat t.base_dir m in
      list_day_files month_path
      |> List.filter (fun d ->
        let day_num = day_number_of_day_file_name d in
        let dominated =
          (m = since_month && String.compare day_num since_day < 0)
          || (m = until_month && String.compare day_num until_day > 0)
        in
        not dominated)
      |> List.map (fun d -> Filename.concat month_path d))
;;

(* Fold the rows a range gained since [cursors] said each file was read to.

   A day file is append-only, so what a trailing-window answer gains between
   two calls is the bytes appended to files it already read plus files that
   did not exist yet. Measured 2026-09-06 on this workspace's tool-call log: a
   24h window is 242MB, and the busy hour appends about 15MB -- 0.04MB at a
   10-second call interval. Re-reading the window for that is the cost this
   exists to remove.

   [cursors] maps a path to the byte boundary a previous fold stopped at; the
   returned list is the same map advanced, and a caller keeps it beside its
   accumulator. A path absent from [cursors] is read whole. A file that
   shrank below its cursor is a rotation or a rewrite: [fold_appended_lines]
   restarts it from zero, which double-counts rather than under-counts, so a
   caller that cannot tolerate that must compare the returned cursor against
   the one it passed. *)
let fold_range_appended_raw t ~since ~until ~cursors ~init ~f =
  let paths = range_day_file_paths t ~since ~until in
  List.fold_left
    (fun (acc, next_cursors) path ->
       let from = match List.assoc_opt path cursors with Some n -> n | None -> 0 in
       let acc, boundary =
         Fs_compat.fold_appended_lines ~path ~from ~init:acc ~f
       in
       acc, (path, boundary) :: next_cursors)
    (init, [])
    paths
;;

let fold_range_appended t ~since ~until ~cursors ~init ~f =
  fold_range_appended_raw t ~since ~until ~cursors ~init ~f:(fun acc line ->
    match Yojson.Safe.from_string line with
    | json -> f acc json
    | exception Yojson.Json_error _ -> acc)
;;

type append_cursor = (string * Unix.stats * int) list

type 'a appended_read =
  | Appended of 'a * append_cursor
  | Cursor_invalidated

let append_snapshot_result t ~since ~until =
  let open Result.Syntax in
  let* paths = range_day_file_paths_result t ~since ~until in
  let rec inspect acc = function
    | [] -> Ok (List.rev acc)
    | path :: rest ->
      let* stats = inspect_path_result path in
      (match non_regular_file_kind_of_stats stats with
       | Some kind -> Error (Non_regular_file { path; kind })
       | None -> inspect ((path, stats) :: acc) rest)
  in
  inspect [] paths
;;

let append_only_successor previous current =
  same_file_identity previous current
  && current.Unix.st_size >= previous.Unix.st_size
  && (current.Unix.st_size > previous.Unix.st_size
      || (current.Unix.st_mtime = previous.Unix.st_mtime
          && current.Unix.st_ctime = previous.Unix.st_ctime))
;;

let appended_read_changed path =
  Io_error { operation = Read_file; path;
             detail = "dated files changed during incremental read" }
;;

(* Consume only the captured extent of an already verified handle. Keep the
   boundary before an incomplete last line, even if the writer appends while
   this read is running. Callback errors are deliberately outside I/O catches. *)
let fold_captured_entries_result channel ~path ~from ~until ~init ~f =
  let rec drive acc boundary position fragment =
    if position >= until then Ok (acc, boundary)
    else
      let chunk = Bytes.create (min 65536 (until - position)) in
      let read =
        match input channel chunk 0 (Bytes.length chunk) with
        | 0 -> Error (appended_read_changed path)
        | length -> Ok length
        | exception Sys_error detail ->
          Error (Io_error { operation = Read_file; path; detail })
      in
      match read with
      | Error _ as error -> error
      | Ok length ->
        let value = ref acc in
        let next_boundary = ref boundary in
        (* Search only bytes returned by [input], then copy each span at
           once instead of inserting its bytes individually. *)
        let rec newline_at index =
          if index >= length || Bytes.get chunk index = '\n' then index
          else newline_at (index + 1)
        in
        let rec consume start =
          if start < length then begin
            let index = newline_at start in
            if index < length then begin
              let line =
                if Buffer.length fragment = 0 then
                  Bytes.sub_string chunk start (index - start)
                else begin
                  Buffer.add_subbytes fragment chunk start (index - start);
                  let line = Buffer.contents fragment in
                  Buffer.clear fragment;
                  line
                end
              in
              next_boundary := position + index + 1;
              if String.trim line <> "" then
                value := f !value (recent_entry_of_line ~path line);
              consume (index + 1)
            end else
              Buffer.add_subbytes fragment chunk start (length - start)
          end
        in
        consume 0;
        drive !value !next_boundary (position + length) fragment
  in
  let seek =
    match seek_in channel from with
    | () -> Ok ()
    | exception Sys_error detail ->
      Error (Io_error { operation = Read_file; path; detail })
  in
  match seek with
  | Error _ as error -> error
  | Ok () -> drive init from from (Buffer.create 256)
;;

let fold_range_appended_result t ~since ~until ~cursor ~init ~f =
  let open Result.Syntax in
  let* snapshot = append_snapshot_result t ~since ~until in
  let previous = match cursor with Some cursor -> cursor | None -> [] in
  let invalidated =
    List.exists
      (fun (path, prior, _) ->
         match List.assoc_opt path snapshot with
         | None -> true
         | Some current -> not (append_only_successor prior current))
      previous
  in
  if invalidated then Ok Cursor_invalidated
  else
    let read_file acc (path, captured) =
      Fs_compat.Input.with_open_result ~path ~open_input:open_regular_input_result (fun channel ->
        let* opened =
          match Unix.fstat (Unix.descr_of_in_channel channel) with
          | stats -> Ok stats
          | exception Unix.Unix_error (error, _, _) ->
            Error (Io_error { operation = Inspect; path;
                              detail = Unix.error_message error })
        in
        if not (append_only_successor captured opened)
        then Error (appended_read_changed path)
        else
          let from =
            match List.find_opt (fun (name, _, _) -> String.equal name path) previous with
            | Some (_, _, boundary) -> boundary
            | None -> 0
          in
          let* value, boundary =
            fold_captured_entries_result channel ~path ~from
              ~until:captured.Unix.st_size ~init:acc
              ~f:(fun acc -> function Parsed row -> f acc row | Malformed_json _ -> acc)
          in
          Ok (value, (path, captured, boundary)))
    in
    let rec read_all acc cursors = function
      | [] -> Ok (acc, List.rev cursors)
      | file :: rest ->
        let* acc, cursor = read_file acc file in
        read_all acc (cursor :: cursors) rest
    in
    let* value, next = read_all init [] snapshot in
    let* after = append_snapshot_result t ~since ~until in
    let stable =
      List.map fst snapshot = List.map fst after
      && List.for_all
           (fun (path, captured) ->
              match List.assoc_opt path after with
              | Some current -> append_only_successor captured current
              | None -> false)
           snapshot
    in
    if stable then Ok (Appended (value, next))
    else Error (appended_read_changed t.base_dir)
;;

type incomplete_tail =
  | Incomplete_tail_is_error
  | Incomplete_tail_is_unwritten

let fold_file_appended path ~incomplete_tail ~cursor ~init ~f =
  let open Result.Syntax in
  let* captured = inspect_path_result path in
  let* () = match non_regular_file_kind_of_stats captured with
    | Some kind -> Error (Non_regular_file {path;kind}) | None -> Ok () in
  let previous = match cursor with None -> [] | Some cursor -> cursor in
  match previous with
  | (_ :: _ :: _) -> Ok Cursor_invalidated
  | [(prior_path, prior, _)] when prior_path <> path || not (append_only_successor prior captured) ->
      Ok Cursor_invalidated
  | [] | [_] ->
    Fs_compat.Input.with_open_result ~path ~open_input:open_regular_input_result (fun channel ->
      let* opened = match Unix.fstat (Unix.descr_of_in_channel channel) with
        | stats -> Ok stats
        | exception Unix.Unix_error (error, _, _) ->
            Error (Io_error {operation=Inspect;path;detail=Unix.error_message error}) in
      if not (append_only_successor captured opened) then Error (appended_read_changed path)
      else
        let from = match previous with [] -> 0 | (_,_,offset) :: _ -> offset in
        let* value, boundary = fold_captured_entries_result channel ~path ~from
          ~until:captured.Unix.st_size ~init ~f in
        let* () =
          if boundary = captured.Unix.st_size then Ok ()
          else
            match incomplete_tail with
            | Incomplete_tail_is_error ->
              Error (Io_error {operation=Read_file;path;detail="incomplete trailing JSONL row"})
            | Incomplete_tail_is_unwritten -> Ok ()
        in
        let* after = inspect_path_result path in
        if append_only_successor captured after then
          Ok (Appended (value, [(path,captured,boundary)]))
        else Error (appended_read_changed path))
;;

let fold_file_appended_entries_result path =
  fold_file_appended path ~incomplete_tail:Incomplete_tail_is_error
;;

let fold_file_appended_complete_entries_result path =
  fold_file_appended path ~incomplete_tail:Incomplete_tail_is_unwritten
;;

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
                       let lines = map_tail_rows_as ~name:(job_name t) path ~max_lines:need
                         ~f:(fun row -> row.line) in
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

(* Keep the existing store mutex on the fiber. Descriptor operations offload
   through Fs_compat, so neither directory reads nor unlinks block the domain. *)
let prune t ~days = removing_files t (fun () -> prune_unlocked t ~days)

let days_to_keep ~operator_window_days store =
  match Store.retention store with
  | Store.Operator_window ->
    if operator_window_days > 0 then Some operator_window_days else None
  | Store.Fixed_days days -> Some days
  | Store.Own_days read -> Some (read ())
  | Store.Kept -> None

let prune_listed_stores_bound root held ~operator_window_days ~on_pruned =
  List.fold_left
    (fun pruned store ->
       match days_to_keep ~operator_window_days store with
       | None -> pruned
       | Some days when days <= 0 -> pruned
       | Some days ->
         pruned + Store.fold_retention_directories root held store
           ~f:(fun location directory ->
             let t = open_store location in
             let removed =
               removing_files t (fun () ->
                 prune_bound_directory ~location ~days directory)
             in
             if removed > 0 then on_pruned location;
             removed))
    0 Store.all

(* ── The facts kept in memory, on the read side ────────── *)

(* The store's cell for [fact]. The first reader makes it, and every later
   one finds that one: a second cell for the same fact would be settled by no
   writer that saw the first. *)
let cell_of_entry : type a. entry -> a fact -> a held Fact_cell.t =
  fun entry fact ->
  let rec find : kept list -> a held Fact_cell.t option = function
    | [] -> None
    | Kept (other, cell) :: rest ->
      (match Type.Id.provably_equal fact.id other.id with
       | Some Type.Equal -> Some cell
       | None -> find rest)
  in
  let rec find_or_add () =
    let kept = Atomic.get entry.kept in
    match find kept with
    | Some cell -> cell
    | None ->
      let cell = Fact_cell.make () in
      if Atomic.compare_and_set entry.kept kept (Kept (fact, cell) :: kept)
      then cell
      else find_or_add ()
  in
  find_or_add ()

let place_of_day_file_path path =
  { month_dir = Filename.basename (Filename.dirname path)
  ; day_file = Filename.basename path
  }

let last_row : recent_entry option fact =
  { id = Type.Id.make ()
  ; name = "last_row"
  ; read =
      (fun t ->
        read_recent_using_result t 1 ~decode:(fun ~path line ->
          path, recent_entry_of_line ~path line)
        |> Result.map (function
          | [] -> { value = None; newest = None }
          | (path, row) :: _ ->
            { value = Some row; newest = Some (place_of_day_file_path path) }))
  ; step = (fun _ written -> Some (Some (Lazy.force written.row)))
  }

(* The newest [count] physical rows, oldest first. An appended row goes to
   the end and the row before the window falls out. Each call makes a fact of
   its own: a count is defined in one place, and the fact is made there.

   A row is its JSON, or [None] when it is not JSON. The file it is in is no
   part of the value: a size rotation renames the current day file under the
   rows a window still holds, and a kept name would be the old one. *)
(* A window of the store's newest [count] physical rows, oldest first.
   [of_line] gives a row from its line as the strict read hands it over, and
   [of_written] the same row from an append. The value names no file. *)
let window ~what ~name ~count ~of_line ~of_written =
  if count < 1 then invalid_arg (Printf.sprintf "Dated_jsonl.%s: count %d" what count);
  let rec drop excess rows =
    match rows with
    | _ :: rest when excess > 0 -> drop (excess - 1) rest
    | [] | _ :: _ -> rows
  in
  { id = Type.Id.make ()
  ; name
  ; read =
      (fun t ->
        read_recent_using_result t count ~decode:(fun ~path line -> path, of_line ~path line)
        |> Result.map (fun rows ->
          { value = List.map snd rows
          ; newest =
              (match List.rev rows with
               | [] -> None
               | (path, _) :: _ -> Some (place_of_day_file_path path))
          }))
  ; step =
      (fun held written ->
        let rows = held @ [ of_written written ] in
        Some (drop (List.length rows - count) rows))
  }

let last_rows ~name ~count : Yojson.Safe.t option list fact =
  let json_of = function
    | Parsed json -> Some json
    | Malformed_json _ -> None
  in
  window
    ~what:"last_rows"
    ~name
    ~count
    ~of_line:(fun ~path line -> json_of (recent_entry_of_line ~path line))
    ~of_written:(fun written -> json_of (Lazy.force written.row))

let last_lines ~name ~count : string list fact =
  window
    ~what:"last_lines"
    ~name
    ~count
    ~of_line:(fun ~path:_ line -> line)
    ~of_written:(fun written -> written.line)

(* What [select] gives for the newest row it selects. The strict search goes
   from the newest row back and stops at the first one selected, so the rows
   it passed over are newer than the value's own row and none of them was
   selected.

   An appended row that is selected is the value. One that is passed over
   leaves the value as it is: the search would pass over it too. After
   either, the newest day file the value has seen a row in is the appended
   row's. An append writes JSON; were a row not to read back as JSON, the
   files would be asked again. *)
let newest_selected ~name ~select : 'a option fact =
  { id = Type.Id.make ()
  ; name
  ; read =
      (fun t ->
        find_latest_entry_with_its_file_result t (select ~base_dir:t.base_dir)
        |> Result.map (function
          | None -> { value = None; newest = None }
          | Some (value, path) ->
            { value = Some value; newest = Some (place_of_day_file_path path) }))
  ; step =
      (fun held written ->
        match Lazy.force written.row with
        | Malformed_json _ -> None
        | Parsed _ as row ->
          (match select ~base_dir:written.store_dir row with
           | Some value -> Some (Some value)
           | None -> Some held))
  }

(* The newest row that is JSON: every row that is JSON is selected. *)
let newest_parsed_row : Yojson.Safe.t option fact =
  newest_selected ~name:"newest_parsed_row" ~select:(fun ~base_dir:_ -> function
    | Parsed json -> Some json
    | Malformed_json _ -> None)

(* The lease holder is the one writer of some stores and not of others
   ([Store.facts]): being the lease holder is a fact about the process
   ([Fact_cell.keep_in_this_process]), and who writes a store is a fact about
   the store. A fact is kept where both hold. *)
let keeps_facts_of t =
  Fact_cell.kept_in_this_process ()
  &&
  match Store.facts (Store.of_location t.location) with
  | Store.Kept_by_the_lease_holder -> true
  | Store.Read_from_the_files -> false

let fact_read_outcome = function
  | Fact_cell.Held _ -> "held"
  | Fact_cell.Read_and_kept _ -> "read_and_kept"
  | Fact_cell.Read_not_kept _ -> "read_not_kept"
  | Fact_cell.Read_failed _ -> "read_failed"

let read_fact t fact =
  let value_of = function
    | Fact_cell.Held held -> Fact_cell.Held held.value
    | Fact_cell.Read_and_kept held -> Fact_cell.Read_and_kept held.value
    | Fact_cell.Read_not_kept held -> Fact_cell.Read_not_kept held.value
    | Fact_cell.Read_failed _ as failed -> failed
  in
  let answer =
    if not (keeps_facts_of t)
    then (
      (* Another process appends to this store, or may. The files are read
         as they were before there were facts, and no cell is made. *)
      match fact.read t with
      | Ok held -> Fact_cell.Read_not_kept held.value
      | Error error -> Fact_cell.Read_failed error)
    else (
      let cell = cell_of_entry (resolve t.location).File_system_named.entry fact in
      match Fact_cell.held cell with
      | Some held -> Fact_cell.Held held.value
      | None ->
        (* The cell is seen and the files are read in one job. A cell seen
           before the wait for a worker would lose to every append that
           lands during the wait. *)
        off_fiber ~name:(job_name t) (fun () ->
          Fact_cell.fill cell ~read:(fun () -> fact.read t))
        |> value_of)
  in
  Otel_metric_store_core.inc_counter
    Otel_builtin_metric_names.metric_dated_jsonl_fact_reads
    ~labels:
      [ "store", Store.pool_job_name (Store.of_location t.location)
      ; "fact", fact.name
      ; "outcome", fact_read_outcome answer
      ]
    ();
  answer

(* Test hooks declared in the .mli — implementation lives in this
   module so tests can verify mutex-registry sharing without
   widening the public API surface. *)
module For_testing = struct
  let cross_context_mutex = store_mutex

  let in_registry location =
    File_system_named.has_entry registry (Store.absolute_dir location)

  let after_row
        ?(base_dir = Filename.current_dir_name)
        ?(line = "")
        fact
        ~value
        ~newest
        ~row
        ~written
    =
    let place (month_dir, day_file) = { month_dir; day_file } in
    after_row
      fact
      { row = Lazy.from_val row; line; place = place written; store_dir = base_dir }
      { value; newest = Option.map place newest }
    |> Option.map (fun held ->
      held.value, Option.map (fun place -> place.month_dir, place.day_file) held.newest)

end

(* A store gets its registry entry when its mutex is first asked for, and
   only the functions that write or prune ask. None of them is in [Reader]'s
   signature. *)
module Reader = struct
  type nonrec t = t

  let open_store location =
    { location; base_dir = Store.dir location; max_bytes = None }

  let base_dir = base_dir
  let read_recent_result = read_recent_result
  let read_recent_lines_result = read_recent_lines_result
end
