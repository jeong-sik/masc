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

(* ---------- Append helpers ---------- *)

let append_line path line =
  ensure_dir (Filename.dirname path);
  let oc = open_out_gen [ Open_append; Open_creat; Open_text ] 0o644 path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc (line ^ "\n"))
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
  (* NDT-OK: PID is used only to avoid temp-file collisions in a single process; atomic rename guarantees correctness. *)
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let oc = open_out_bin tmp in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content);
  Sys.rename tmp path
;;

let append_episode ~keeper_id episode =
  let path =
    episode_path ~keeper_id ~trace_id:episode.trace_id ~generation:episode.generation
  in
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

let read_lines path =
  if not (Sys.file_exists path)
  then []
  else (
    let ic = open_in path in
    let rec loop acc =
      match input_line ic with
      | line -> loop (line :: acc)
      | exception End_of_file -> List.rev acc
    in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> loop []))
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
  | _ -> None
;;

let read_facts_tail ~keeper_id ~n =
  read_lines (facts_path ~keeper_id)
  |> List.filter_map (parse_json_line fact_of_json)
  |> take_last n
;;

let read_events_tail ~keeper_id ~n =
  read_lines (events_path ~keeper_id)
  |> List.filter_map (parse_json_line episode_of_json)
  |> take_last n
;;

let read_episodes_tail ~keeper_id ~n =
  let dir = Filename.concat (keepers_dir ()) (Filename.concat keeper_id "episodes") in
  if not (Sys.file_exists dir && Sys.is_directory dir)
  then []
  else (
    let entries = Array.to_list (Sys.readdir dir) in
    let paths =
      List.map (fun name -> Filename.concat dir name) entries
      |> List.filter Sys.file_exists
      |> List.sort String.compare
    in
    take_last n paths
    |> List.filter_map (fun path ->
      let ic = open_in_bin path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
           let len = in_channel_length ic in
           let buf = really_input_string ic len in
           parse_json_line episode_of_json buf)))
;;
