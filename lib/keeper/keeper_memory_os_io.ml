(** Keeper_memory_os_io — append-only atomic I/O for tiered memory files.

    All writes are append-only and best-effort atomic (temp file + rename
    for single-record files; direct append with O_APPEND semantics for
    JSONL logs). Reads are bounded tail reads to keep startup cost low. *)

open Keeper_memory_os_types

let rec ensure_dir path =
  if path = "" || path = Filename.current_dir_name
  then ()
  else if Sys.file_exists path
  then (
    if not (Sys.is_directory path)
    then invalid_arg (Printf.sprintf "not a directory: %s" path))
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) ->
      if not (Sys.file_exists path && Sys.is_directory path)
      then invalid_arg (Printf.sprintf "not a directory: %s" path))
;;

let keepers_dir_override : string option ref = ref None

let keepers_dir () =
  match !keepers_dir_override with
  | Some path -> path
  | None -> Config_dir_resolver.keepers_dir ()
;;

module For_testing = struct
  let with_keepers_dir path f =
    ensure_dir path;
    let previous = !keepers_dir_override in
    keepers_dir_override := Some path;
    Fun.protect
      ~finally:(fun () -> keepers_dir_override := previous)
      f
  ;;
end

let facts_path ~keeper_id =
  Filename.concat (keepers_dir ()) (keeper_id ^ ".facts.jsonl")
;;

let events_path ~keeper_id =
  Filename.concat (keepers_dir ()) (keeper_id ^ ".events.jsonl")
;;

let episodes_dir ~keeper_id =
  let d = Filename.concat (keepers_dir ()) (Filename.concat keeper_id "episodes") in
  ensure_dir d;
  d
;;

let tool_results_dir ~keeper_id =
  let d = Filename.concat (keepers_dir ()) (Filename.concat keeper_id "tool-results") in
  ensure_dir d;
  d
;;

let tool_result_path ~keeper_id ~tool_call_id =
  Filename.concat (tool_results_dir ~keeper_id) (tool_call_id ^ ".json")
;;

let episode_path ~keeper_id ~trace_id ~generation =
  Filename.concat
    (episodes_dir ~keeper_id)
    (Printf.sprintf "%s-g%04d.json" trace_id generation)
;;

let unique_episode_path ~keeper_id episode =
  let created_ms =
    episode.created_at *. 1000.0 |> Float.max 0.0 |> Int64.of_float
  in
  let base =
    Filename.concat
      (episodes_dir ~keeper_id)
      (Printf.sprintf
         "%s-g%04d-t%013Ld"
         episode.trace_id
         episode.generation
         created_ms)
  in
  let rec loop suffix =
    let path =
      if suffix = 0
      then base ^ ".json"
      else Printf.sprintf "%s-%04d.json" base suffix
    in
    if Sys.file_exists path then loop (suffix + 1) else path
  in
  loop 0
;;

(* ---------- Append helpers ---------- *)

let remove_noerr path =
  try
    if Sys.file_exists path then Sys.remove path
  with
  | Sys_error _ | Unix.Unix_error _ -> ()
;;

let append_line path line =
  ensure_dir (Filename.dirname path);
  let oc = open_out_gen [ Open_append; Open_creat; Open_text ] 0o644 path in
  let close_attempted = ref false in
  try
    output_string oc (line ^ "\n");
    close_attempted := true;
    close_out oc
  with
  | exn ->
    if not !close_attempted then close_out_noerr oc;
    raise exn
;;

let append_json path json =
  append_line path (Yojson.Safe.to_string json)
;;

let append_fact ~keeper_id fact =
  append_json (facts_path ~keeper_id) (fact_to_json fact)
;;

let append_event ~keeper_id episode =
  append_json (events_path ~keeper_id) (episode_to_json episode)
;;

let write_file_atomically path content =
  ensure_dir (Filename.dirname path);
  let rec open_tmp attempt =
    (* PID/counter affect only the collision-resistant temp path;
       NDT-OK: persisted content and final path stay input-derived, and O_EXCL
       prevents accidental reuse before the checked close + rename. *)
    let tmp = Printf.sprintf "%s.tmp.%d.%d" path (Unix.getpid ()) attempt in
    try
      let fd =
        Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o644
      in
      tmp, Unix.out_channel_of_descr fd
    with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> open_tmp (attempt + 1)
  in
  let tmp, oc = open_tmp 0 in
  let close_attempted = ref false in
  try
    output_string oc content;
    close_attempted := true;
    close_out oc;
    Sys.rename tmp path
  with
  | exn ->
    if not !close_attempted then close_out_noerr oc;
    remove_noerr tmp;
    raise exn
;;

let append_episode ~keeper_id episode =
  let path = unique_episode_path ~keeper_id episode in
  write_file_atomically path (Yojson.Safe.pretty_to_string (episode_to_json episode))
;;

let append_episode_bundle ~keeper_id episode =
  append_episode ~keeper_id episode;
  append_event ~keeper_id episode;
  List.iter (append_fact ~keeper_id) episode.claims
;;

let save_tool_result ~keeper_id ~tool_call_id json =
  let path = tool_result_path ~keeper_id ~tool_call_id in
  write_file_atomically path (Yojson.Safe.pretty_to_string json)
;;

let load_tool_result ~keeper_id ~tool_call_id =
  let path = tool_result_path ~keeper_id ~tool_call_id in
  if Sys.file_exists path
  then (
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let len = in_channel_length ic in
         let buf = really_input_string ic len in
         Some (Yojson.Safe.from_string buf)))
  else None
;;

(* ---------- Tail reads ---------- *)

let count_newlines s =
  let count = ref 0 in
  String.iter (fun ch -> if Char.equal ch '\n' then incr count) s;
  !count
;;

let split_lines s =
  let len = String.length s in
  let rec loop start i acc =
    if i = len
    then (
      let acc =
        if start = len
        then acc
        else String.sub s start (len - start) :: acc
      in
      List.rev acc)
    else if Char.equal s.[i] '\n'
    then (
      let line_len = i - start in
      let line =
        if line_len > 0 && Char.equal s.[i - 1] '\r'
        then String.sub s start (line_len - 1)
        else String.sub s start line_len
      in
      loop (i + 1) (i + 1) (line :: acc))
    else
      loop start (i + 1) acc
  in
  loop 0 0 []
;;

let read_lines_tail path ~n =
  if n <= 0 || not (Sys.file_exists path)
  then []
  else (
    let ic = open_in_bin path in
    let rec loop pos chunks newline_count =
      if pos <= 0 || newline_count > n
      then chunks
      else (
        let chunk_len = min 8192 pos in
        let next_pos = pos - chunk_len in
        seek_in ic next_pos;
        let chunk = really_input_string ic chunk_len in
        loop next_pos (chunk :: chunks) (newline_count + count_newlines chunk))
    in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let len = in_channel_length ic in
         loop len [] 0 |> String.concat "" |> split_lines))
;;

let take_last n xs =
  let rec drop k = function
    | xs when k <= 0 -> xs
    | [] -> []
    | _ :: tl -> drop (k - 1) tl
  in
  let len = List.length xs in
  if n <= 0 then [] else if len <= n then xs else drop (len - n) xs
;;

let parse_json_line parse line =
  try parse (Yojson.Safe.from_string line) with
  | Yojson.Json_error _ -> None
;;

let read_facts_tail ~keeper_id ~n =
  read_lines_tail (facts_path ~keeper_id) ~n
  |> List.filter_map (parse_json_line fact_of_json)
  |> take_last n
;;

let read_events_tail ~keeper_id ~n =
  read_lines_tail (events_path ~keeper_id) ~n
  |> List.filter_map (parse_json_line episode_of_json)
  |> take_last n
;;

let read_episode_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let len = in_channel_length ic in
       let buf = really_input_string ic len in
       parse_json_line episode_of_json buf)
;;

let compare_episode_recency a b =
  let by_created = Float.compare a.created_at b.created_at in
  if by_created <> 0
  then by_created
  else (
    let by_trace = String.compare a.trace_id b.trace_id in
    if by_trace <> 0
    then by_trace
    else (
      let by_generation = Int.compare a.generation b.generation in
      if by_generation <> 0
      then by_generation
      else String.compare a.episode_summary b.episode_summary))
;;

let read_episode_files_tail ~keeper_id ~n =
  let dir = Filename.concat (keepers_dir ()) (Filename.concat keeper_id "episodes") in
  if n <= 0 || not (Sys.file_exists dir && Sys.is_directory dir)
  then []
  else (
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".json")
    |> List.map (fun name -> Filename.concat dir name)
    |> List.filter Sys.file_exists
    |> List.filter_map read_episode_file
    |> List.sort compare_episode_recency
    |> take_last n)
;;

let read_episodes_tail ~keeper_id ~n =
  let events = read_events_tail ~keeper_id ~n in
  if events = [] then read_episode_files_tail ~keeper_id ~n else events
;;
