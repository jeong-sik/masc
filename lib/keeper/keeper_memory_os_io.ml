(** Keeper_memory_os_io — append-only atomic I/O for tiered memory files.

    All writes are append-only and best-effort atomic (temp file + rename
    for single-record files; direct append with O_APPEND semantics for
    JSONL logs). Reads are bounded tail reads to keep startup cost low. *)

open Keeper_memory_os_types
open Result.Syntax

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

let ensure_configured_keepers_dir () =
  let path = keepers_dir () in
  ensure_dir path;
  path
;;

let keeper_name_exn raw =
  match Keeper_id.Keeper_name.of_string raw with
  | Ok keeper_name -> keeper_name
  | Error detail -> invalid_arg detail
;;

let keeper_name_string = Keeper_id.Keeper_name.to_string

let trace_id_exn raw =
  match Keeper_id.Trace_id.of_string raw with
  | Ok trace_id -> trace_id
  | Error detail -> invalid_arg detail
;;

let trace_id_string = Keeper_id.Trace_id.to_string

module Anchored = Fs_compat.Anchored_dir

type root =
  { handle : Anchored.t
  ; path : string
  }

type keeper_scope =
  { root : root
  ; keeper_id : Keeper_id.Keeper_name.t
  ; keeper_name : string
  }

type episode_bundle = Episode_bundle of keeper_scope
type facts_lock = Facts_lock of keeper_scope

type lock_timeout =
  { caller : string
  ; path : string
  ; attempts : int
  }

let lock_timeout_to_string timeout =
  Printf.sprintf
    "lock timeout: caller=%s path=%s attempts=%d"
    timeout.caller
    timeout.path
    timeout.attempts
;;

let raise_lock_timeout timeout =
  raise
    (File_lock_eio.Flock_timeout
       { caller = timeout.caller
       ; path = timeout.path
       ; attempts = timeout.attempts
       })
;;

let segment_exn ~context raw =
  match Anchored.Segment.of_string raw with
  | Ok segment -> segment
  | Error error ->
    invalid_arg
      (Printf.sprintf
         "%s %S is not one filesystem segment: %s"
         context
         raw
         (Anchored.Segment.error_to_string error))
;;

let with_root path f =
  Anchored.with_open_root path @@ fun handle ->
  f { handle; path }
;;

let scope root keeper_id =
  { root; keeper_id; keeper_name = keeper_name_string keeper_id }
;;

let facts_suffix = ".facts.jsonl"
let events_suffix = ".events.jsonl"
let lock_suffix = ".lock"
let episode_bundle_lock_suffix = ".episode-bundle.lock"

let keeper_artifact_name ~suffix keeper_id =
  segment_exn
    ~context:"keeper memory artifact"
    (keeper_name_string keeper_id ^ suffix)
;;

let facts_name keeper_id = keeper_artifact_name ~suffix:facts_suffix keeper_id
let events_name keeper_id = keeper_artifact_name ~suffix:events_suffix keeper_id

let facts_lock_name keeper_id =
  keeper_artifact_name ~suffix:(facts_suffix ^ lock_suffix) keeper_id
;;

let episode_bundle_lock_name keeper_id =
  keeper_artifact_name ~suffix:episode_bundle_lock_suffix keeper_id
;;

let with_descriptor_lock ?clock root name f =
  let diagnostic_path =
    Filename.concat root.path (Anchored.Segment.to_string name)
  in
  File_lock_eio.with_anchored_file_lock
    ?clock
    ~path:diagnostic_path
    ~directory:root.handle
    ~name
    ~perm:0o644
    f
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

let facts_path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ facts_suffix)
;;

let facts_path ~keeper_id =
  facts_path_for_keepers_dir ~keepers_dir:(keepers_dir ()) ~keeper_id
;;

(* RFC-0244 Tier 2: the keeper ids that currently have a Tier-1 fact store, for
   the cross-keeper consolidation sweep. Derived from the [*.facts.jsonl] files
   in the keepers dir (the same path keeper writes use), so it tracks exactly the
   keepers with persisted facts. The reserved shared id is excluded so a prior
   sweep's output is never folded back in as a source keeper. Sorted for
   deterministic sweep order. *)
let list_fact_store_keeper_ids_for_keepers_dir ~keepers_dir =
  match
    with_root keepers_dir (fun root ->
      Anchored.read_dir root.handle
      |> List.filter_map (fun entry ->
        let name = Anchored.Segment.to_string entry in
        match Filename.chop_suffix_opt ~suffix:facts_suffix name with
        | Some id when String.equal id shared_store_id -> None
        | Some id ->
          (match Keeper_id.Keeper_name.of_string id with
           | Ok keeper_id -> Some (keeper_name_string keeper_id)
           | Error detail -> invalid_arg detail)
        | None -> None)
      |> List.sort String.compare)
  with
  | ids -> ids
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> []
;;

let list_fact_store_keeper_ids () =
  list_fact_store_keeper_ids_for_keepers_dir ~keepers_dir:(keepers_dir ())
;;

let list_fact_store_keeper_ids_for_base_path ~base_path =
  list_fact_store_keeper_ids_for_keepers_dir
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path)
;;

let events_path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ events_suffix)
;;

type legacy_memory_file =
  | Legacy_facts
  | Legacy_events

let supported_legacy_memory_files = [ Legacy_facts; Legacy_events ]

let legacy_memory_filename = function
  | Legacy_facts -> "facts.jsonl"
  | Legacy_events -> "events.jsonl"
;;

let legacy_memory_file_of_filename filename =
  List.find_opt
    (fun legacy_file -> String.equal filename (legacy_memory_filename legacy_file))
    supported_legacy_memory_files
;;

let current_path_for_legacy_memory_filename ~keepers_dir ~keeper_id ~filename =
  match legacy_memory_file_of_filename filename with
  | Some Legacy_facts -> Some (facts_path_for_keepers_dir ~keepers_dir ~keeper_id)
  | Some Legacy_events -> Some (events_path_for_keepers_dir ~keepers_dir ~keeper_id)
  | None -> None
;;

let events_path ~keeper_id =
  events_path_for_keepers_dir ~keepers_dir:(keepers_dir ()) ~keeper_id
;;

let with_episode_bundle_lock_for_keepers_dir ?clock ~keepers_dir ~keeper_id f =
  with_root keepers_dir @@ fun root ->
  let keeper = scope root keeper_id in
  with_descriptor_lock
    ?clock
    root
    (episode_bundle_lock_name keeper_id)
    (fun () -> f (Episode_bundle keeper))
;;

let with_episode_bundle_lock ?clock ~keeper_id f =
  with_episode_bundle_lock_for_keepers_dir
    ?clock
    ~keepers_dir:(ensure_configured_keepers_dir ())
    ~keeper_id:(keeper_name_exn keeper_id)
    f
;;

let with_facts_lock_scope ?clock keeper f =
  with_descriptor_lock
    ?clock
    keeper.root
    (facts_lock_name keeper.keeper_id)
    (fun () -> f (Facts_lock keeper))
;;

let with_facts_lock_scope_or_timeout ?clock keeper ~on_timeout f =
  try
    with_facts_lock_scope ?clock keeper f
  with
  | File_lock_eio.Flock_timeout { caller; path; attempts } ->
    on_timeout { caller; path; attempts }
;;

let with_facts_lock_for_keepers_dir
      ?clock
      ~keepers_dir
      ~keeper_id
      ~on_timeout
      f
  =
  with_root keepers_dir @@ fun root ->
  with_facts_lock_scope_or_timeout
    ?clock
    (scope root keeper_id)
    ~on_timeout
    f
;;

let with_facts_lock_in_bundle ?clock (Episode_bundle keeper) ~on_timeout f =
  with_facts_lock_scope_or_timeout ?clock keeper ~on_timeout f
;;

let with_facts_lock ?clock ~keeper_id ~on_timeout f =
  with_facts_lock_for_keepers_dir
    ?clock
    ~keepers_dir:(ensure_configured_keepers_dir ())
    ~keeper_id:(keeper_name_exn keeper_id)
    ~on_timeout
    f
;;

let episodes_directory_name = "episodes"

let with_episodes_directory keeper f =
  let keeper_name =
    segment_exn ~context:"keeper directory" keeper.keeper_name
  in
  let episodes_name =
    segment_exn ~context:"episodes directory" episodes_directory_name
  in
  Anchored.with_ensure_dir
    keeper.root.handle
    ~name:keeper_name
    ~perm:0o755
    ~enforce_perm:false
  @@ fun keeper_dir ->
  Anchored.with_ensure_dir
    keeper_dir
    ~name:episodes_name
    ~perm:0o755
    ~enforce_perm:false
    (fun handle ->
      let path =
        Filename.concat
          keeper.root.path
          (Filename.concat keeper.keeper_name episodes_directory_name)
      in
      f { handle; path })
;;

let with_existing_episodes_directory keeper f =
  let keeper_name =
    segment_exn ~context:"keeper directory" keeper.keeper_name
  in
  let episodes_name =
    segment_exn ~context:"episodes directory" episodes_directory_name
  in
  match
    Anchored.with_open_dir_opt keeper.root.handle keeper_name (fun keeper_dir ->
      Anchored.with_open_dir_opt keeper_dir episodes_name (fun handle ->
        let path =
          Filename.concat
            keeper.root.path
            (Filename.concat keeper.keeper_name episodes_directory_name)
        in
        f { handle; path }))
  with
  | None | Some None -> None
  | Some (Some value) -> Some value
;;

let episodes_dir_for_keepers_dir ~keepers_dir ~keeper_id =
  with_root keepers_dir @@ fun root ->
  with_episodes_directory (scope root keeper_id) (fun episodes -> episodes.path)
;;

let episodes_dir ~keeper_id =
  episodes_dir_for_keepers_dir
    ~keepers_dir:(ensure_configured_keepers_dir ())
    ~keeper_id:(keeper_name_exn keeper_id)
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
  let trace_id = trace_id_exn trace_id in
  Filename.concat
    (episodes_dir ~keeper_id)
    (Printf.sprintf "%s-g%04d.json" (trace_id_string trace_id) generation)
;;

(* Raised when a durable atomic write fails. Distinct from [Failure] so the
   facts-lock wrapper's lock-timeout handler ([with_facts_lock]) does not
   misclassify a write error (e.g. ENOSPC) as a lock-acquisition timeout. *)
exception Atomic_write_failed of string

(* Run [f] against [oc] then close it, guaranteeing the descriptor is released
   on every exit. [close_out] runs inside the body so a flush failure (e.g.
   ENOSPC on the buffered tail) propagates to the caller; [close_out_noerr] in
   the [Fun.protect] finally is a no-op after a clean close and reclaims the fd
   when [close_out]'s flush raised before [close_out_channel] could run (OCaml's
   [close_out = flush; close_out_channel] never reaches the close on flush
   failure). [close_out_noerr] never raises, so it cannot mask the body's
   exception via [Fun.Finally_raised]. *)
let with_out_channel oc ~f =
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
       f oc;
       close_out oc)
;;

(* Durable atomic write delegated to the Fs_compat durability SSOT:
   tmp -> fsync(tmp) -> rename -> best-effort fsync(parent dir) — the same
   primitive board and event-queue persistence use. A local fsync pair here would
   duplicate (and could drift from) that durability boundary, so route through it.
   NB: the primitive's boot-time atomic-orphan sweep is depth-1 from base_path and
   does not currently reach the keepers dir, so a SIGKILL between write and rename
   still leaves an uncollected [.atomic_*.tmp] here — a pre-existing gap (the old
   hand-rolled temp was not swept either), tracked separately, not worsened here.
   The Memory OS write contract raises on failure (unit return), so map [Error] to
   [Atomic_write_failed]; the temp is already cleaned up by [save_file_atomic], and
   [Eio.Cancel.Cancelled] is re-raised by it (RFC-0143), never swallowed. *)
let write_file_atomically path content =
  ensure_dir (Filename.dirname path);
  match Fs_compat.save_file_atomic path content with
  | Ok () -> ()
  | Error msg -> raise (Atomic_write_failed msg)
;;

let atomic_replace directory name content =
  match Anchored.atomic_replace directory.handle ~name ~perm:0o644 content with
  | Ok () -> ()
  | Error error ->
    let path =
      Filename.concat directory.path (Anchored.Segment.to_string name)
    in
    raise
      (Atomic_write_failed
         (Printf.sprintf
            "%s: %s"
            path
            (Anchored.mutation_error_to_string error)))
;;

let generation_counter_name trace_id =
  segment_exn
    ~context:"episode generation counter"
    (Printf.sprintf "%s.generation" (trace_id_string trace_id))
;;

let generation_lock_name trace_id =
  segment_exn
    ~context:"episode generation lock"
    (Printf.sprintf "%s.generation.lock" (trace_id_string trace_id))
;;

let leading_decimal value =
  let rec end_index index =
    if index >= String.length value
    then index
    else
      match value.[index] with
      | '0' .. '9' -> end_index (index + 1)
      | _ -> index
  in
  match end_index 0 with
  | 0 -> None
  | length -> int_of_string_opt (String.sub value 0 length)
;;

let max_generation_from_files episodes trace_id =
  let prefix = Printf.sprintf "%s-g" (trace_id_string trace_id) in
  Anchored.read_dir episodes.handle
  |> List.filter_map (fun name ->
    let name = Anchored.Segment.to_string name in
    if String.starts_with ~prefix name then
      let plen = String.length prefix in
      let rest = String.sub name plen (String.length name - plen) in
      leading_decimal rest
    else None)
  |> List.fold_left max (-1)
;;

let read_generation_counter episodes name =
  match Anchored.read_file_opt episodes.handle name with
  | None -> None
  | Some content -> String.trim content |> int_of_string_opt
;;

(** Compute the next generation number for a trace's episode files.

    Scans the episodes directory for files matching [trace_id-gNNNN.json]
    and reserves [max(floor, max_gen + 1, counter_next)] under a per-trace file
    lock. The counter intentionally allows gaps when extraction later fails;
    uniqueness is more important than contiguous numbering across fibers or
    processes. *)
let next_generation_with_floor_for_keepers_dir
      ~keepers_dir
      ~floor
      ~keeper_id
      ~trace_id
  =
  with_root keepers_dir @@ fun root ->
  with_episodes_directory (scope root keeper_id) @@ fun episodes ->
  let counter_name = generation_counter_name trace_id in
  with_descriptor_lock episodes (generation_lock_name trace_id)
  @@ fun () ->
  let next_from_files = max_generation_from_files episodes trace_id + 1 in
  let next_from_counter =
    match read_generation_counter episodes counter_name with
    | Some next -> next
    | None -> 0
  in
  let generation = max floor (max next_from_files next_from_counter) in
  atomic_replace
    episodes
    counter_name
    (Printf.sprintf "%d\n" (generation + 1));
  generation
;;

let next_generation_with_floor ~floor ~keeper_id ~trace_id =
  next_generation_with_floor_for_keepers_dir
    ~keepers_dir:(ensure_configured_keepers_dir ())
    ~floor
    ~keeper_id:(keeper_name_exn keeper_id)
    ~trace_id:(trace_id_exn trace_id)
;;

let next_generation ~keeper_id ~trace_id =
  next_generation_with_floor ~floor:0 ~keeper_id ~trace_id
;;

let unique_episode_name episodes ~trace_id episode =
  let created_ms =
    episode.created_at *. 1000.0 |> Float.max 0.0 |> Int64.of_float
  in
  let base =
    Printf.sprintf
      "%s-g%04d-t%013Ld"
      (trace_id_string trace_id)
      episode.generation
      created_ms
  in
  let rec loop suffix =
    let raw =
      if suffix = 0
      then base ^ ".json"
      else Printf.sprintf "%s-%04d.json" base suffix
    in
    let name = segment_exn ~context:"episode artifact" raw in
    match Anchored.stat episodes.handle name with
    | Some _ -> loop (suffix + 1)
    | None -> name
  in
  loop 0
;;

let append_json_anchored directory name json =
  let current =
    match Anchored.read_file_opt directory.handle name with
    | Some content -> content
    | None -> ""
  in
  atomic_replace
    directory
    name
    (current ^ Yojson.Safe.to_string json ^ "\n")
;;

let append_fact ~keeper_id fact =
  with_facts_lock
    ~keeper_id
    ~on_timeout:raise_lock_timeout
    (fun (Facts_lock keeper) ->
      append_json_anchored keeper.root (facts_name keeper.keeper_id) (fact_to_json fact))
;;

let append_event_in_bundle (Episode_bundle keeper) episode =
  ignore (trace_id_exn episode.trace_id : Keeper_id.Trace_id.t);
  append_json_anchored
    keeper.root
    (events_name keeper.keeper_id)
    (episode_to_json episode)
;;

let append_episode_in_bundle (Episode_bundle keeper) episode =
  let trace_id = trace_id_exn episode.trace_id in
  with_episodes_directory keeper @@ fun episodes ->
  let name = unique_episode_name episodes ~trace_id episode in
  atomic_replace
    episodes
    name
    (Yojson.Safe.pretty_to_string (episode_to_json episode))
;;

let append_event_for_keepers_dir ~keepers_dir ~keeper_id episode =
  ignore (trace_id_exn episode.trace_id : Keeper_id.Trace_id.t);
  with_episode_bundle_lock_for_keepers_dir
    ~keepers_dir
    ~keeper_id
    (fun bundle -> append_event_in_bundle bundle episode)
;;

let append_event ~keeper_id episode =
  let keeper_id = keeper_name_exn keeper_id in
  append_event_for_keepers_dir
    ~keepers_dir:(ensure_configured_keepers_dir ())
    ~keeper_id
    episode
;;

let append_episode_for_keepers_dir ~keepers_dir ~keeper_id episode =
  ignore (trace_id_exn episode.trace_id : Keeper_id.Trace_id.t);
  with_episode_bundle_lock_for_keepers_dir
    ~keepers_dir
    ~keeper_id
    (fun bundle -> append_episode_in_bundle bundle episode)
;;

let append_episode ~keeper_id episode =
  let keeper_id = keeper_name_exn keeper_id in
  append_episode_for_keepers_dir
    ~keepers_dir:(ensure_configured_keepers_dir ())
    ~keeper_id
    episode
;;

let facts_content facts =
  let content =
    facts
    |> List.map (fun fact -> fact_to_json fact |> Yojson.Safe.to_string)
    |> String.concat "\n"
  in
  if String.equal content "" then "" else content ^ "\n"
;;

let rewrite_facts_in_lock (Facts_lock keeper) facts =
  atomic_replace keeper.root (facts_name keeper.keeper_id) (facts_content facts)
;;

let append_episode_bundle ~keeper_id episode =
  with_episode_bundle_lock ~keeper_id (fun bundle ->
    with_facts_lock_in_bundle
      bundle
      ~on_timeout:raise_lock_timeout
      (fun (Facts_lock keeper) ->
        List.iter
          (fun fact ->
            append_json_anchored
              keeper.root
              (facts_name keeper.keeper_id)
              (fact_to_json fact))
          episode.claims);
    append_episode_in_bundle bundle episode;
    append_event_in_bundle bundle episode)
;;

let rewrite_facts_atomically_for_keepers_dir ~keepers_dir ~keeper_id facts =
  let keeper_id = keeper_name_exn keeper_id in
  with_root keepers_dir @@ fun root ->
  rewrite_facts_in_lock (Facts_lock (scope root keeper_id)) facts
;;

let rewrite_facts_atomically_for_base_path ~base_path ~keeper_id facts =
  rewrite_facts_atomically_for_keepers_dir
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path)
    ~keeper_id
    facts
;;

let rewrite_facts_atomically ~keeper_id facts =
  rewrite_facts_atomically_for_keepers_dir
    ~keepers_dir:(ensure_configured_keepers_dir ())
    ~keeper_id
    facts
;;

(* ---------- Facts snapshot CAS (optimistic concurrency) ---------- *)

(* Byte-level snapshot identity for the read-outside-lock, rewrite-under-lock
   pattern. [fact_to_json] has a stable key order (see Keeper_memory_os_types — the
   optional claim metadata keys are appended last and omitted when None,
   specifically to keep this fingerprint byte-identical for legacy rows), so a
   fact's canonical JSON is a sound content key. [same_fact_snapshot snapshot
   current] is true iff the two lists are positionally byte-identical: any
   concurrent append (longer), cap/GC (shorter), or re-observation (a row's bytes
   change) makes them differ, so a caller that classified [snapshot] outside the
   lock can re-read under the lock and abandon a stale rewrite. Line count and file
   size are NOT sound CAS keys — [cap_facts]/[merge_and_cap_facts] can hold either
   steady while rows differ. SSOT for the reconcile and consolidation rewrite
   paths. *)
let fact_fingerprint fact = fact_to_json fact |> Yojson.Safe.to_string

let rec same_fact_snapshot left right =
  match left, right with
  | [], [] -> true
  | l :: ls, r :: rs ->
    String.equal (fact_fingerprint l) (fact_fingerprint r) && same_fact_snapshot ls rs
  | [], _ :: _ | _ :: _, [] -> false
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

let read_lines_all_anchored directory name =
  match Anchored.read_file_opt directory.handle name with
  | None -> []
  | Some content -> split_lines content
;;

let read_facts_all_for_scope keeper =
  read_lines_all_anchored keeper.root (facts_name keeper.keeper_id)
  |> List.filter_map (parse_json_line fact_of_json)
;;

let read_facts_all_strict_for_scope keeper =
  let path =
    facts_path_for_keepers_dir
      ~keepers_dir:keeper.root.path
      ~keeper_id:keeper.keeper_name
  in
  let rec loop line_number acc = function
    | [] -> Ok (List.rev acc)
    | line :: rest ->
      let* fact = parse_fact_json_line_strict ~path ~line_number line in
      loop (line_number + 1) (fact :: acc) rest
  in
  loop 1 [] (read_lines_all_anchored keeper.root (facts_name keeper.keeper_id))
;;

let read_facts_all_strict_in_lock (Facts_lock keeper) =
  read_facts_all_strict_for_scope keeper
;;

let read_facts_all_for_keepers_dir ~keepers_dir ~keeper_id =
  let keeper_id = keeper_name_exn keeper_id in
  with_root keepers_dir @@ fun root ->
  read_facts_all_for_scope (scope root keeper_id)
;;

let read_facts_all ~keeper_id =
  read_facts_all_for_keepers_dir
    ~keepers_dir:(ensure_configured_keepers_dir ())
    ~keeper_id
;;

let read_facts_all_strict_for_keepers_dir ~keepers_dir ~keeper_id =
  let keeper_id = keeper_name_exn keeper_id in
  with_root keepers_dir @@ fun root ->
  read_facts_all_strict_for_scope (scope root keeper_id)
;;

let read_facts_all_strict ~keeper_id =
  read_facts_all_strict_for_keepers_dir
    ~keepers_dir:(ensure_configured_keepers_dir ())
    ~keeper_id
;;

let read_facts_tail_for_keepers_dir ~keepers_dir ~keeper_id ~n =
  let keeper_id = keeper_name_exn keeper_id in
  with_root keepers_dir @@ fun root ->
  read_facts_all_for_scope (scope root keeper_id) |> take_last n
;;

let read_facts_tail ~keeper_id ~n =
  read_facts_tail_for_keepers_dir
    ~keepers_dir:(ensure_configured_keepers_dir ())
    ~keeper_id
    ~n
;;

let read_facts_tail_for_base_path ~base_path ~keeper_id ~n =
  read_facts_tail_for_keepers_dir
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path)
    ~keeper_id
    ~n
;;

(* RFC-0239 Q4: Memory OS size policy lives in [Keeper_memory_os_policy]. These
   aliases preserve the existing IO public surface for callers/tests while
   keeping raw policy values in one module. *)
let fact_recall_window = Keeper_memory_os_policy.fact_recall_window

let fact_store_max = Keeper_memory_os_policy.fact_store_max

(* RFC-0272 (defect D): retention bounds for the append-only episode log
   ([events.jsonl] line count and [episodes/] file count). Same shape and
   hysteresis band as the facts cap ([fact_recall_window] / [fact_store_max]): a
   trim/unlink fires only when the count exceeds the high-water [*_store_max] and
   trims back to the low-water [*_recall_window], so it stays off the per-turn
   hot path. The low-water values intentionally exceed
   [Keeper_memory_os_policy.recall_episode_tail_scan], so a trim can never starve
   recall; [test_cap_events_preserves_recall_window] asserts that coupling so an
   edit to either constant cannot silently break it. *)
let event_recall_window = Keeper_memory_os_policy.event_recall_window
let event_store_max = Keeper_memory_os_policy.event_store_max
let episode_file_window = Keeper_memory_os_policy.episode_file_window
let episode_file_store_max = Keeper_memory_os_policy.episode_file_store_max

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

let read_facts_for_rewrite_in_lock (Facts_lock keeper) =
  (* RFC-0302 (#22823) phase-2b: [keepers_dir] is resolved by the caller before
     this boundary. Offload the blocking full read + strict parse of the fact
     store off the main Eio scheduler. This is the per-write read on the
     librarian hot path ([merge_and_cap_facts]) and [cap_facts]. Callers hold a
     File_lock_eio flock on main across this (inline-in-tests) submit; the closure
     reads only the retained root capability and typed keeper name. *)
  match
    Domain_pool_ref.submit_io_or_inline (fun () ->
      read_facts_all_strict_for_scope keeper)
  with
  | Ok facts -> facts
  | Error message -> invalid_arg message
;;

(* RFC-0239 Q4 (supersedes RFC-0238 Capped_by_score): bound the append-only
   fact store. When the store exceeds [trigger], keep the [keep] highest-ranked
   facts and atomically rewrite the file; otherwise leave it untouched. The
   hysteresis ([trigger] > [keep]) keeps this off the per-turn hot path — a
   rewrite happens only once every ([trigger] - [keep]) appended facts. Returns
   the number of facts dropped. *)
let cap_facts ~now ~keeper_id ~keep ~trigger ~rank =
  with_facts_lock
    ~keeper_id
    ~on_timeout:raise_lock_timeout
  @@ fun (Facts_lock _ as lock) ->
  let all = read_facts_for_rewrite_in_lock lock in
  (* RFC-0259 §3.6 (P5): drop effective-horizon-expired rows before the trigger gate
     and before ranking, so an under-cap store does not retain expired rows on
     disk until the off-by-default GC sweep. Facts with no effective horizon
     ([Keeper_memory_os_types.fact_effective_valid_until]) are never expired. *)
  let live, expired = partition_expired ~now all in
  let total = List.length live in
  if expired = [] && total <= trigger
  then 0
  else (
    let kept =
      if total <= trigger
      then live
      else
        live
        |> List.stable_sort (fun a b -> Float.compare (rank b) (rank a))
        |> take_first keep
    in
    rewrite_facts_in_lock lock kept;
    List.length all - List.length kept)
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
       let key = claim_identity f in
       if not (Hashtbl.mem tbl key) then Hashtbl.add tbl key cell)
    existing;
  let merged = ref 0 in
  let appended = ref 0 in
  List.iter
    (fun inc ->
       let key = claim_identity inc in
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
let merge_and_cap_facts_in_lock
      (Facts_lock _ as lock)
      ~now
      ~merge
      ~incoming
      ~keep
      ~trigger
      ~rank
  =
  let existing = read_facts_for_rewrite_in_lock lock in
  let merged_list, merged, appended = merge_episode_facts ~merge ~existing ~incoming in
  (* RFC-0259 §3.6 (P5): drop effective-horizon-expired rows on the same boundary the
     GC sweep uses, before the trigger gate and ranking, so an under-cap store
     does not retain expired rows on disk. Expired rows are counted in [dropped]
     alongside rank evictions. Facts with no effective horizon (see
     [Keeper_memory_os_types.fact_effective_valid_until]) are never expired, so durable knowledge is never evicted here. *)
  let live, expired = partition_expired ~now merged_list in
  let total = List.length live in
  let no_incoming = match incoming with [] -> true | _ :: _ -> false in
  if no_incoming && expired = [] && total <= trigger
  then { merged; appended; dropped = 0 }
  else (
    let kept, rank_dropped =
      if total <= trigger
      then live, 0
      else (
        let kept =
          live
          |> List.stable_sort (fun a b -> Float.compare (rank b) (rank a))
          |> take_first keep
        in
        kept, total - List.length kept)
    in
    rewrite_facts_in_lock lock kept;
    { merged; appended; dropped = rank_dropped + List.length expired })
;;

let merge_and_cap_facts_for_keepers_dir
      ~keepers_dir
      ~now
      ~keeper_id
      ~merge
      ~incoming
      ~keep
      ~trigger
      ~rank
  =
  with_facts_lock_for_keepers_dir
    ~keepers_dir
    ~keeper_id
    ~on_timeout:raise_lock_timeout
    (fun lock ->
      merge_and_cap_facts_in_lock
        lock
        ~now
        ~merge
        ~incoming
        ~keep
        ~trigger
        ~rank)
;;

let merge_and_cap_facts
      ~now
      ~keeper_id
      ~merge
      ~incoming
      ~keep
      ~trigger
      ~rank
  =
  merge_and_cap_facts_for_keepers_dir
    ~keepers_dir:(ensure_configured_keepers_dir ())
    ~now
    ~keeper_id:(keeper_name_exn keeper_id)
    ~merge
    ~incoming
    ~keep
    ~trigger
    ~rank
;;

let read_events_tail_for_scope keeper ~n =
  read_lines_all_anchored keeper.root (events_name keeper.keeper_id)
  |> List.filter_map (parse_json_line episode_of_json)
  |> take_last n
;;

let read_events_tail ~keeper_id ~n =
  let keeper_id = keeper_name_exn keeper_id in
  with_root (ensure_configured_keepers_dir ()) @@ fun root ->
  read_events_tail_for_scope (scope root keeper_id) ~n
;;

let parse_episode_content content =
  parse_json_line episode_of_json content
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

let episode_files episodes =
  Anchored.read_dir episodes.handle
  |> List.filter (fun name ->
    Filename.check_suffix (Anchored.Segment.to_string name) ".json")
  |> List.filter_map (fun name ->
    Anchored.read_file episodes.handle name
    |> parse_episode_content
    |> Option.map (fun episode -> name, episode))
;;

let read_episode_files_tail_for_scope keeper ~n =
  if n <= 0
  then []
  else
    match
      with_existing_episodes_directory keeper (fun episodes ->
        episode_files episodes
        |> List.map snd
        |> List.sort compare_episode_recency
        |> take_last n)
    with
    | None -> []
    | Some episodes -> episodes
;;

let read_episodes_tail ~keeper_id ~n =
  let keeper_id = keeper_name_exn keeper_id in
  with_root (ensure_configured_keepers_dir ()) @@ fun root ->
  let keeper = scope root keeper_id in
  let events = read_events_tail_for_scope keeper ~n in
  if events = []
  then read_episode_files_tail_for_scope keeper ~n
  else events
;;

(* RFC-0272 (defect D): the hysteresis decision shared by the episode-log caps.
   [None] = no-op (count within the high-water [trigger]); [Some keep] = trim to
   the low-water. Pure so the watermark logic is testable without IO. *)
let trim_target ~count ~keep ~trigger = if count <= trigger then None else Some keep

(* RFC-0272 (defect D): bound the append-only [events.jsonl] by line count. When
   the line count exceeds [trigger], keep the last [keep] RAW lines (newest, in
   append order) and atomically rewrite. Raw-line trim — not parse / filter /
   re-serialize — preserves byte fidelity and the malformed-line tolerance
   [read_lines_tail] has: a line [episode_of_json] cannot parse is tail-trimmed
   like any other, never silently dropped mid-file. Returns the number dropped
   (diagnostic; the rewrite is the mechanism). *)
let cap_events_in_bundle (Episode_bundle keeper) ~keep ~trigger =
  (* RFC-0302 (#22823): submit the blocking full read to the domain pool so it
     does not starve the main Eio scheduler when a pool is installed. The
     closure retains the opened root capability, so an ancestor substitution
     cannot redirect the read. *)
  let name = events_name keeper.keeper_id in
  let all =
    Domain_pool_ref.submit_io_or_inline (fun () ->
      read_lines_all_anchored keeper.root name)
  in
  match trim_target ~count:(List.length all) ~keep ~trigger with
  | None -> 0
  | Some keep_n ->
    let kept = take_last keep_n all in
    let content =
      match kept with
      | [] -> ""
      | _ -> String.concat "\n" kept ^ "\n"
    in
    atomic_replace keeper.root name content;
    List.length all - List.length kept
;;

let cap_events_for_keepers_dir ~keepers_dir ~keeper_id ~keep ~trigger =
  with_episode_bundle_lock_for_keepers_dir
    ~keepers_dir
    ~keeper_id
    (fun bundle -> cap_events_in_bundle bundle ~keep ~trigger)
;;

let cap_events ~keeper_id ~keep ~trigger =
  let keeper_id = keeper_name_exn keeper_id in
  cap_events_for_keepers_dir
    ~keepers_dir:(ensure_configured_keepers_dir ())
    ~keeper_id
    ~keep
    ~trigger
;;

(* RFC-0272 (defect D): bound the [episodes/] directory by file count. When the
   parseable-file count exceeds [trigger], keep the [keep] most-recent files by
   [compare_episode_recency] (the order recall uses) and unlink the rest. Only
   parseable files are counted and ordered — an unparseable file has no recency
   to rank, so it is left untouched rather than blindly deleted. Each unlink is
   descriptor-relative and durably published; an I/O failure is surfaced rather
   than treated as a successful trim. The caller already holds the bundle lock,
   so no second lock is acquired. Returns the number unlinked. *)
let cap_episode_files_in_bundle (Episode_bundle keeper) ~keep ~trigger =
  (* RFC-0302 (#22823): resolve and create [episodes_dir] from the explicit root
     on the main domain, then offload the blocking readdir + per-file episode read
     + best-effort unlink scan to the shared domain pool. The closure captures
     only immutable [dir]/[keep]/[trigger]; no mutable OCaml state is shared, so
     it is domain-safe. The caller's bundle flock stays held on main across the
     (inline-fallback in tests) submit. *)
  match
    with_existing_episodes_directory keeper (fun episodes ->
      let parsed =
        Domain_pool_ref.submit_io_or_inline (fun () -> episode_files episodes)
      in
      match trim_target ~count:(List.length parsed) ~keep ~trigger with
      | None -> 0
      | Some keep_n ->
        let sorted =
          List.sort
            (fun (_, left) (_, right) ->
               compare_episode_recency left right)
            parsed
        in
        let n_drop = List.length sorted - keep_n in
        sorted
        |> List.filteri (fun index _ -> index < n_drop)
        |> List.fold_left
             (fun removed (name, _) ->
                match Anchored.unlink_if_exists episodes.handle name with
                | Ok `Removed -> removed + 1
                | Ok `Missing -> removed
                | Error error ->
                  raise
                    (Atomic_write_failed
                       (Printf.sprintf
                          "%s: %s"
                          (Filename.concat
                             episodes.path
                             (Anchored.Segment.to_string name))
                          (Anchored.mutation_error_to_string error))))
             0)
  with
  | None -> 0
  | Some removed -> removed
;;

let cap_episode_files_for_keepers_dir ~keepers_dir ~keeper_id ~keep ~trigger =
  with_episode_bundle_lock_for_keepers_dir
    ~keepers_dir
    ~keeper_id
    (fun bundle -> cap_episode_files_in_bundle bundle ~keep ~trigger)
;;

let cap_episode_files ~keeper_id ~keep ~trigger =
  let keeper_id = keeper_name_exn keeper_id in
  cap_episode_files_for_keepers_dir
    ~keepers_dir:(ensure_configured_keepers_dir ())
    ~keeper_id
    ~keep
    ~trigger
;;
