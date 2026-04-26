(** Date-split JSONL storage.

    Extracts the [YYYY-MM/DD.jsonl] pattern originally used by
    {!Coord_utils_ops.log_event} into a reusable module.

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
}

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
      Filename.concat (Sys.getcwd ()) base_dir
    else
      base_dir
  in
  strip_trailing_slashes path

let mutex_for_base_dir ~base_dir ~injected =
  let key = mutex_key base_dir in
  Stdlib.Mutex.protect mutex_registry_mu (fun () ->
    match Hashtbl.find_opt mutex_registry key with
    | Some cell -> cell
    | None ->
        let mutex =
          match injected with
          | Some mutex -> mutex
          | None -> Eio.Mutex.create ()
        in
        let cell = Atomic.make mutex in
        Hashtbl.add mutex_registry key cell;
        cell)

let create ~base_dir ?mutex () =
  let mutex = mutex_for_base_dir ~base_dir ~injected:mutex in
  { base_dir; mutex }

let base_dir t = t.base_dir

(* ── Date helpers ─────────────────────────────────────── *)

(** Current UTC date decomposed into (month_dir, day_file). *)
let today_parts () =
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  let month = Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) in
  let day = Printf.sprintf "%02d.jsonl" tm.tm_mday in
  (month, day)

(** Full path for today's JSONL file, creating dirs as needed. *)
let today_path t =
  let month, day = today_parts () in
  let dir = Filename.concat t.base_dir month in
  Fs_compat.mkdir_p dir;
  Filename.concat dir day

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

let load_lines path =
  if not (Fs_compat.file_exists path) then []
  else
    try
      Fs_compat.load_file path
      |> String.split_on_char '\n'
      |> List.filter (fun l -> String.trim l <> "")
    with Sys_error _ -> []

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
        let truncated_prefix = ref false in
        while !pos > 0 && !total_newlines <= target_newlines do
          let read_start = max 0 (!pos - chunk_size) in
          let read_len = !pos - read_start in
          if read_start > 0 then truncated_prefix := true;
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
          if !truncated_prefix then
            match raw_lines with
            | _partial :: rest -> rest
            | [] -> []
          else raw_lines
        in
        let all_lines =
          raw_lines
          |> List.filter (fun l -> String.trim l <> "")
        in
        let all_lines =
          if !pos > 0 then
            match all_lines with
            | _resume_overlap :: rest -> rest
            | [] -> []
          else all_lines
        in
        let total = List.length all_lines in
        if total <= max_lines then all_lines
        else
          List.filteri (fun i _ -> i >= total - max_lines) all_lines
    )

(* ── Public API ───────────────────────────────────────── *)

let append t json =
  let mutex = Atomic.get t.mutex in
  Eio.Mutex.use_rw ~protect:false mutex (fun () ->
    let path = today_path t in
    Fs_compat.append_jsonl path json)

let read_recent t n =
  if n <= 0 then []
  else begin
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
           let remaining = n - !count in
           let lines = load_tail_lines path ~max_lines:remaining in
           let rev_lines = List.rev lines in
           List.iter (fun line ->
             if !count < n then begin
               (try
                  let json = Yojson.Safe.from_string line in
                  collected := json :: !collected;
                  incr count
                with Yojson.Json_error _ -> ())
             end
           ) rev_lines
         ) days
       ) months
     with Done -> ());
    !collected
  end

let read_recent_lines t n =
  if n <= 0 then []
  else begin
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
           let remaining = n - !count in
           let lines = load_tail_lines path ~max_lines:remaining in
           let rev_lines = List.rev lines in
           List.iter (fun line ->
             if !count < n then begin
               collected := line :: !collected;
               incr count
             end
           ) rev_lines
         ) days
       ) months
     with Done -> ());
    !collected
  end

let count_entries t =
  let months = list_month_dirs t.base_dir in
  List.fold_left (fun total month ->
    let month_path = Filename.concat t.base_dir month in
    let days = list_day_files month_path in
    total
    + List.fold_left (fun month_total day ->
        let path = Filename.concat month_path day in
        month_total + count_non_empty_lines path
      ) 0 days
  ) 0 months
let read_range t ~since ~until =
  match parse_date since, parse_date until with
  | None, _ | _, None -> []
  | Some (since_month, since_day), Some (until_month, until_day) ->
    let collected = ref [] in
    let months = list_month_dirs t.base_dir |> List.rev in (* ascending *)
    List.iter (fun m ->
      if String.compare m since_month >= 0
         && String.compare m until_month <= 0 then begin
        let month_path = Filename.concat t.base_dir m in
        let days = list_day_files month_path |> List.rev in (* ascending *)
        List.iter (fun d ->
          let day_num = Filename.remove_extension d in
          let dominated =
            (m = since_month && String.compare day_num since_day < 0)
            || (m = until_month && String.compare day_num until_day > 0)
          in
          if not dominated then begin
            let path = Filename.concat month_path d in
            let lines = load_lines path in
            List.iter (fun line ->
              (try
                 let json = Yojson.Safe.from_string line in
                 collected := json :: !collected
               with Yojson.Json_error _ -> ())
            ) lines
          end
        ) days
      end
    ) months;
    List.rev !collected

let prune t ~days =
  if days <= 0 then 0
  else begin
    let now = Unix.gettimeofday () in
    let cutoff = now -. (float_of_int days *. 86400.0) in
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

(* Test hooks declared in the .mli — implementation lives in this
   module so tests can verify mutex-registry sharing without
   widening the public API surface. *)
module For_testing = struct
  let mutex (t : t) = Atomic.get t.mutex

  let mutex_for_base_dir base_dir =
    let cell = mutex_for_base_dir ~base_dir ~injected:None in
    Atomic.get cell

  let registry_size () =
    Stdlib.Mutex.protect mutex_registry_mu (fun () ->
      Hashtbl.length mutex_registry)
end

(* Duplicate count_entries removed — canonical definition at line 225 *)
