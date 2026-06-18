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

(* RFC-0244 Tier 2: the keeper ids that currently have a Tier-1 fact store, for
   the cross-keeper consolidation sweep. Derived from the [*.facts.jsonl] files
   in the keepers dir (the same path keeper writes use), so it tracks exactly the
   keepers with persisted facts. The reserved shared id is excluded so a prior
   sweep's output is never folded back in as a source keeper. Sorted for
   deterministic sweep order. *)
let list_fact_store_keeper_ids () =
  let dir = keepers_dir () in
  if not (Sys.file_exists dir && Sys.is_directory dir)
  then []
  else
    Sys.readdir dir
    |> Array.to_list
    |> List.filter_map (fun name ->
      match Filename.chop_suffix_opt ~suffix:".facts.jsonl" name with
      | Some id when not (String.equal id shared_store_id) -> Some id
      | Some _ | None -> None)
    |> List.sort String.compare
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

(** Compute the next generation number for a trace's episode files.

    Scans the episodes directory for files matching [trace_id-gNNNN.json]
    and returns [max_gen + 1].  This is a **single-writer** operation:
    concurrent callers for the same [trace_id] will race on the directory
    scan and may produce duplicate generation numbers.  The caller must
    ensure at most one fiber calls [next_generation] for a given
    [trace_id] at a time (e.g. via a per-trace sequencer or by running
    all extractions for one trace on a single fiber). *)
let next_generation ~keeper_id ~trace_id =
  let dir = episodes_dir ~keeper_id in
  let prefix = Printf.sprintf "%s-g" trace_id in
  let max_gen =
    Sys.readdir dir
    |> Array.to_list
    |> List.filter_map (fun name ->
      if String.starts_with ~prefix name then
        let plen = String.length prefix in
        let rest = String.sub name plen (String.length name - plen) in
        if String.length rest >= 4 then int_of_string_opt (String.sub rest 0 4) else None
      else None)
    |> List.fold_left max (-1)
  in
  max_gen + 1
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

(* RFC-0247 §2.7 associative layer: per-keeper append-only association events,
   one file alongside the fact store. KNOWN LIMITATION (slice 1): unlike facts
   (RFC-0239 Q4 capped), edges are not yet bounded — an episode with [n] distinct
   claims appends [n*(n-1)/2] edges. Aggregation-on-write + a cap is deferred to
   the capping slice, triggered when a keeper's edges file growth warrants it;
   until then growth is disclosed here rather than silently capped. *)
let edges_path ~keeper_id =
  Filename.concat (keepers_dir ()) (keeper_id ^ ".edges.jsonl")
;;

let append_edge ~keeper_id edge =
  append_json (edges_path ~keeper_id) (Keeper_memory_os_edges.edge_to_json edge)
;;

let append_edges ~keeper_id edges = List.iter (append_edge ~keeper_id) edges

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

let rewrite_facts_atomically ~keeper_id facts =
  let path = facts_path ~keeper_id in
  let content =
    facts
    |> List.map (fun fact -> fact_to_json fact |> Yojson.Safe.to_string)
    |> String.concat "\n"
  in
  let content = if String.equal content "" then "" else content ^ "\n" in
  write_file_atomically path content
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

let read_lines_all path =
  if not (Sys.file_exists path)
  then []
  else (
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let len = in_channel_length ic in
         really_input_string ic len |> split_lines))
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

let parse_fact_json_line_strict ~path ~line_number line =
  try
    match fact_of_json (Yojson.Safe.from_string line) with
    | Some fact -> Ok fact
    | None -> Error (Printf.sprintf "%s:%d: invalid fact JSON shape" path line_number)
  with
  | Yojson.Json_error message ->
    Error (Printf.sprintf "%s:%d: invalid fact JSON: %s" path line_number message)
;;

let read_facts_all ~keeper_id =
  read_lines_all (facts_path ~keeper_id)
  |> List.filter_map (parse_json_line fact_of_json)
;;

let read_edges_all ~keeper_id =
  read_lines_all (edges_path ~keeper_id)
  |> List.filter_map (parse_json_line Keeper_memory_os_edges.edge_of_json)
;;

(* The aggregated read view: associations with Hebbian weight, the surface a
   future spreading-activation recall consumes. *)
let read_associations ~keeper_id =
  read_edges_all ~keeper_id |> Keeper_memory_os_edges.aggregate
;;

let read_facts_all_strict ~keeper_id =
  let path = facts_path ~keeper_id in
  let rec loop line_number acc = function
    | [] -> Ok (List.rev acc)
    | line :: rest ->
      (match parse_fact_json_line_strict ~path ~line_number line with
       | Ok fact -> loop (line_number + 1) (fact :: acc) rest
       | Error _ as e -> e)
  in
  loop 1 [] (read_lines_all path)
;;
let read_facts_tail ~keeper_id ~n =
  read_lines_tail (facts_path ~keeper_id) ~n
  |> List.filter_map (parse_json_line fact_of_json)
  |> take_last n
;;

(* RFC-0239 Q4: the per-keeper fact recall window / retention target. The store
   is bounded to this many facts by the retention sweep, and recall reads up to
   this many candidates (no longer just the last 64), so score ranking selects
   the globally best facts within the bounded store rather than the most recent
   few. *)
let fact_recall_window = 256

let take_first n xs =
  let rec aux k = function
    | x :: tl when k > 0 -> x :: aux (k - 1) tl
    | _ -> []
  in
  if n <= 0 then [] else aux n xs
;;

let read_all_facts ~keeper_id =
  read_facts_all ~keeper_id
;;

let read_facts_for_rewrite ~keeper_id =
  match read_facts_all_strict ~keeper_id with
  | Ok facts -> facts
  | Error message -> invalid_arg message
;;

(* RFC-0239 Q4 (supersedes RFC-0238 Capped_by_score): bound the append-only
   fact store. When the store exceeds [trigger], keep the [keep] highest-ranked
   facts and atomically rewrite the file; otherwise leave it untouched. The
   hysteresis ([trigger] > [keep]) keeps this off the per-turn hot path — a
   rewrite happens only once every ([trigger] - [keep]) appended facts. Returns
   the number of facts dropped. *)
let cap_facts ~keeper_id ~keep ~trigger ~rank =
  let path = facts_path ~keeper_id in
  let all = read_facts_for_rewrite ~keeper_id in
  let total = List.length all in
  if total <= trigger
  then 0
  else (
    let kept =
      all
      |> List.stable_sort (fun a b -> Float.compare (rank b) (rank a))
      |> take_first keep
    in
    let content =
      match kept with
      | [] -> ""
      | _ ->
        (kept |> List.map (fun f -> Yojson.Safe.to_string (fact_to_json f)) |> String.concat "\n")
        ^ "\n"
    in
    write_file_atomically path content;
    total - List.length kept)
;;

type fact_merge_stats =
  { merged : int
  ; appended : int
  ; dropped : int
  }

(* RFC-0243: fold a batch of newly extracted [incoming] facts into [existing] by
   normalized claim identity. An incoming fact whose normalized claim matches an
   existing row (or an earlier incoming in the same batch) is merged in place via
   [merge] (a re-observation); an incoming fact with a new identity is appended.
   Pre-existing duplicate rows in [existing] are preserved as-is — only the first
   row of each identity is a merge target, so collapsing legacy duplicates does
   not spuriously inflate a re-observation count. Existing rows keep their file
   order; genuinely new facts are appended at the end. Returns the rebuilt list
   plus (merged, appended) counts. *)
let merge_episode_facts ~merge ~existing ~incoming =
  let tbl : (string, fact ref) Hashtbl.t = Hashtbl.create 64 in
  let order = ref [] in
  List.iter
    (fun f ->
       let cell = ref f in
       order := cell :: !order;
       let key = normalize_claim f.claim in
       if not (Hashtbl.mem tbl key) then Hashtbl.add tbl key cell)
    existing;
  let merged = ref 0 in
  let appended = ref 0 in
  List.iter
    (fun inc ->
       let key = normalize_claim inc.claim in
       match Hashtbl.find_opt tbl key with
       | Some cell ->
         cell := merge ~existing:!cell ~incoming:inc;
         incr merged
       | None ->
         let cell = ref inc in
         order := cell :: !order;
         Hashtbl.add tbl key cell;
         incr appended)
    incoming;
  List.rev_map ( ! ) !order, !merged, !appended
;;

(* RFC-0243: the librarian write path. Read the store, upsert the episode's
   claims (re-observations merge in place instead of appending immortal
   duplicates — the accuracy-inversion root fix), then apply the same retention
   cap as [cap_facts] in the same read-modify-rewrite so the file is rebuilt
   once. Because the merge mutates existing rows, this rewrites on every write
   that carries claims; the librarian runs at most once per turn after an LLM
   call, so a full rewrite of at most [trigger] facts is off the hot path. An
   empty [incoming] with the store already under [trigger] is a no-op. *)
let merge_and_cap_facts ~keeper_id ~merge ~incoming ~keep ~trigger ~rank =
  let existing = read_facts_for_rewrite ~keeper_id in
  let merged_list, merged, appended = merge_episode_facts ~merge ~existing ~incoming in
  let total = List.length merged_list in
  let no_incoming = match incoming with [] -> true | _ :: _ -> false in
  if no_incoming && total <= trigger
  then { merged; appended; dropped = 0 }
  else (
    let kept, dropped =
      if total <= trigger
      then merged_list, 0
      else (
        let kept =
          merged_list
          |> List.stable_sort (fun a b -> Float.compare (rank b) (rank a))
          |> take_first keep
        in
        kept, total - List.length kept)
    in
    rewrite_facts_atomically ~keeper_id kept;
    { merged; appended; dropped })
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
