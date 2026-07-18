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
  | Not_a_directory of { path : string }
  | Dangling_symbolic_link of { path : string }
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
  | Not_a_directory { path } -> "dated JSONL path is not a directory: " ^ path
  | Dangling_symbolic_link { path } ->
    "dated JSONL path is a dangling symbolic link: " ^ path
  | Invalid_layout_entry { parent; entry; expected } ->
    Printf.sprintf
      "invalid dated JSONL layout entry %s: expected %s"
      (Filename.concat parent entry)
      (layout_entry_kind_to_string expected)
  | Non_regular_file { path; kind } ->
    Printf.sprintf
      "dated JSONL day path is not a regular file: %s (%s)"
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
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) when missing_is_empty ->
    Ok Directory_missing
  | exception Unix.Unix_error (error, _, _) ->
    Error
      (Io_error
         { operation = Inspect; path; detail = Unix.error_message error })
  | exception Sys_error detail ->
    Error (Io_error { operation = Inspect; path; detail })
  | { Unix.st_kind = Unix.S_LNK; _ } ->
    (match Unix.stat path with
     | stat -> directory_presence_of_stat path stat
     | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
       Error (Dangling_symbolic_link { path })
     | exception Unix.Unix_error (error, _, _) ->
       Error
         (Io_error
            { operation = Inspect; path; detail = Unix.error_message error })
     | exception Sys_error detail ->
       Error (Io_error { operation = Inspect; path; detail }))
  | stat -> directory_presence_of_stat path stat
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

let year_is_leap year =
  year mod 4 = 0 && (year mod 100 <> 0 || year mod 400 = 0)
;;

let days_in_month ~year = function
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> Some 31
  | 4 | 6 | 9 | 11 -> Some 30
  | 2 -> Some (if year_is_leap year then 29 else 28)
  | _ -> None
;;

let day_file_name_is_valid ~year ~month name =
  String.length name = 8
  && String.equal (String.sub name 2 6) ".jsonl"
  && substring_is_ascii_digits name ~position:0 ~length:2
  &&
  match int_of_string_opt (String.sub name 0 2), days_in_month ~year month with
  | Some day, Some maximum -> day >= 1 && day <= maximum
  | None, _ | _, None -> false
;;

let validate_layout_entries ~parent ~expected ~is_valid entries =
  let rec loop valid_entries = function
    | [] -> Ok (List.rev valid_entries)
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
      let lines =
        combined
        |> Bytes.to_string
        |> String.split_on_char '\n'
        |> List.filter line_is_non_empty
      in
      let line_count = List.length lines in
      if line_count <= max_lines
      then lines
      else List.filteri (fun index _ -> index >= line_count - max_lines) lines
    end
;;

let load_tail_lines path ~max_lines =
  if max_lines <= 0 || not (Fs_compat.file_exists path)
  then []
  else
    let input = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr input)
      (fun () -> load_tail_lines_from_channel input ~max_lines)
;;

let load_tail_lines_result path ~max_lines =
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

let recent_entry_of_line ~path ?line_number line =
  match Yojson.Safe.from_string line with
  | json -> Parsed json
  | exception Yojson.Json_error detail ->
    Malformed_json { path; line_number; detail }
;;

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
        let* lines =
          load_tail_lines_result path ~max_lines:(requested_line_count ())
        in
        List.iter
          (fun line ->
             if !count < n
             then if !skip > 0
             then decr skip
             else begin
               collected := recent_entry_of_line ~path line :: !collected;
               incr count
             end)
          (List.rev lines);
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
