(** IDE Bridge — collects Keeper activity events and surfaces them in
    the [.masc-ide/] store for IDE consumption.

    RFC-0378 §5.2: the store holds addressed code facts only, keyed by
    the codebase slug. The sinks below persist [Addressed] facts and let
    everything else stay on the bus — the durable record of keeper facts
    is the keeper tool_calls/turn-records stores. *)

open Ide_event_types

let codebase_of_addressed (addressed : Agent_observation.addressed) =
  Agent_observation.Code_address.codebase addressed.address
;;

let file_path_of_addressed (addressed : Agent_observation.addressed) =
  Agent_observation.Code_address.path addressed.address
;;

type event_kind =
  | Tool
  | Turn

let event_kind_to_string = function
  | Tool -> "tool"
  | Turn -> "turn"
;;

let event_kind_of_string = function
  | "tool" -> Some Tool
  | "turn" -> Some Turn
  | _ -> None
;;

let event_file_name = function
  | Tool -> "tool_events.jsonl"
  | Turn -> "turn_events.jsonl"
;;

let event_kind_of_event = function
  | Tool_event _ -> Tool
  | Turn_event _ -> Turn
;;

(* ── Segment rotation + tail-read ────────────────────────────────────────
   The event store was a single append-only [<kind>_events.jsonl] with no
   rotation, so it grew without bound (~4.2 MB/day) and every read folded
   the whole file (a live 143 MB tool_events.jsonl stalled the main Eio
   domain for ~2 s per read). We keep the flat filename as the live segment
   and rotate it to numbered archives [<kind>_events.jsonl.<n>] (higher [n]
   = more recent rotation); reads tail the newest segment(s) only.

   Size-based rotation on the flat layout is chosen over date-sharding
   because it keeps the live filename stable (existing readers/tests still
   observe [<kind>_events.jsonl]) and because an oversized file rotates
   out on its first oversized append and then ages off under
   retention. *)

let default_max_segment_bytes = 32 * 1024 * 1024

(* Retain this many archived segments beyond the live one; older archives
   are pruned. Segment-count (not byte-budget) retention keeps rotation
   math trivial and lets an oversized segment age out over N
   rotations rather than persisting forever. *)
let default_max_retained_segments = 8

(* Filtered ([keeper_id]) reads scan a bounded tail window instead of the
   whole store, so a specific keeper's events are surfaced only from the
   recent window. This is the deliberate A3 bound: an observation panel
   shows recent activity, not an exhaustive history scan. Unfiltered reads
   only ever need [offset + limit] rows. *)
let max_keeper_filter_scan_lines = 1000

let segment_index_of_name ~live_basename name =
  let prefix = live_basename ^ "." in
  let plen = String.length prefix in
  if String.length name > plen && String.sub name 0 plen = prefix
  then int_of_string_opt (String.sub name plen (String.length name - plen))
  else None
;;

let archive_indices ~path =
  let dir = Filename.dirname path in
  let live_basename = Filename.basename path in
  match Sys.readdir dir with
  | exception Sys_error _ -> []
  | entries ->
    Array.to_list entries
    |> List.filter_map (fun name -> segment_index_of_name ~live_basename name)
;;

let archive_path ~path index = Printf.sprintf "%s.%d" path index

let rotation_mutex_registry : (string, Stdlib.Mutex.t) Hashtbl.t = Hashtbl.create 16
let rotation_mutex_registry_mu = Stdlib.Mutex.create ()

let rotation_mutex_for path =
  Stdlib.Mutex.lock rotation_mutex_registry_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock rotation_mutex_registry_mu)
    (fun () ->
       match Hashtbl.find_opt rotation_mutex_registry path with
       | Some m -> m
       | None ->
         let m = Stdlib.Mutex.create () in
         Hashtbl.replace rotation_mutex_registry path m;
         m)
;;

let with_rotation_lock ~path f =
  let m = rotation_mutex_for path in
  Stdlib.Mutex.lock m;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock m) f
;;

(* Rotate the live segment out when it is at or above [max_segment_bytes].
   The new archive index is [max existing + 1], so a concurrent rotation
   never clobbers an existing archive. Caller must hold [with_rotation_lock]
   for [path]: otherwise a racing appender can recreate the live file between
   another caller's index calculation and [rename_if_exists], causing the
   second rename to overwrite the archive chosen by the first. *)
let maybe_rotate ~path ~max_segment_bytes =
  if max_segment_bytes > 0
  then (
    match Fs_compat.file_size path with
    | Some size when size >= max_segment_bytes ->
      let next = 1 + List.fold_left max 0 (archive_indices ~path) in
      ignore
        (Fs_compat.rename_if_exists ~src:path ~dst:(archive_path ~path next) : bool);
      (* The rename moves the inode out from under any cached O_APPEND channel
         for [path]. Without this the next append writes into the archive we
         just created and the live segment is never recreated, so readers that
         tail the live path see the stream stop. *)
      Fs_compat.invalidate_cached_writer path
    | Some _ | None -> ())
;;

(* Delete the oldest archives beyond [max_retained_segments]. Racing prunes
   converge: [Sys.remove] of an already-removed file raises [Sys_error],
   which is ignored. *)
let prune_segments ~path ~max_retained_segments =
  if max_retained_segments >= 0
  then (
    let indices = List.sort compare (archive_indices ~path) in
    let excess = List.length indices - max_retained_segments in
    if excess > 0
    then
      List.iteri
        (fun i index ->
          if i < excess
          then (try Sys.remove (archive_path ~path index) with Sys_error _ -> ()))
        indices)
;;

let append_rotating ~path ~max_segment_bytes ~max_retained_segments json =
  with_rotation_lock ~path (fun () ->
    maybe_rotate ~path ~max_segment_bytes;
    (* Fresh-fd append (not the fd-cached [Fs_compat.append_jsonl]): a cached
       writer keyed by the live path would keep writing into a just-renamed
       archive inode after rotation. [append_file] opens/closes per call and
       serializes concurrent writers per path, matching the prior append. *)
    Fs_compat.append_file path (Yojson.Safe.to_string json ^ "\n");
    prune_segments ~path ~max_retained_segments)
;;

(* Segment files newest-first: live segment, then archives by descending
   index. Only existing files are returned. *)
let segment_paths_newest_first ~path =
  let archives =
    archive_indices ~path
    |> List.sort (fun a b -> compare b a)
    |> List.map (fun index -> archive_path ~path index)
  in
  (if Fs_compat.file_exists path then [ path ] else []) @ archives
;;

(* Collect the newest [budget] raw JSONL lines across segments, tailing the
   newest segment first and expanding to older segments only until [budget]
   lines are gathered. [Dated_jsonl.load_tail_lines] reads each segment
   backwards in chunks, so cost scales with [budget], not with file size. *)
let tail_read_lines ~path ~budget =
  if budget <= 0
  then []
  else (
    let rec loop segments acc remaining =
      if remaining <= 0
      then acc
      else (
        match segments with
        | [] -> acc
        | seg :: rest ->
          let lines =
            try Dated_jsonl.load_tail_lines seg ~max_lines:remaining with
            | Sys_error _ -> []
          in
          loop rest (acc @ lines) (remaining - List.length lines))
    in
    loop (segment_paths_newest_first ~path) [] budget)
;;

let append_event ~base_dir ~codebase ~(event : ide_event) =
  let dir = Ide_paths.code_store_dir ~base_dir ~codebase in
  Fs_compat.mkdir_p dir;
  let file_name = event_file_name (event_kind_of_event event) in
  let path = Filename.concat dir file_name in
  let json = ide_event_to_json event in
  append_rotating
    ~path
    ~max_segment_bytes:default_max_segment_bytes
    ~max_retained_segments:default_max_retained_segments
    json

let string_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String s) when s <> "" -> Some s
     | _ -> None)
  | _ -> None
;;

let int64_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Int i) -> Some (Int64.of_int i)
     | Some (`Intlit s) -> Int64.of_string_opt s
     | _ -> None)
  | _ -> None
;;

let event_timestamp_ms json =
  match int64_field "timestamp_ms" json with
  | Some ts -> ts
  | None ->
    (* DET-OK: malformed or historical bridge rows without timestamps sort last;
       the reader does not synthesize event identity or mutate the stored row. *)
    0L
;;

let event_matches_kind kind json =
  match string_field "type" json with
  | Some wire_kind -> String.equal wire_kind (event_kind_to_string kind)
  | None -> false
;;

let event_matches_keeper keeper_id json =
  match keeper_id with
  | None -> true
  | Some expected ->
    (match string_field "keeper_id" json with
     | Some actual -> String.equal actual expected
     | None -> false)
;;

let normalize_limit = function
  | Some n when n > 0 -> min n 200
  | _ -> 50
;;

let normalize_offset = function
  | Some n when n > 0 -> n
  | _ -> 0
;;

let drop n items =
  let rec loop remaining = function
    | [] -> []
    | rest when remaining <= 0 -> rest
    | _ :: rest -> loop (remaining - 1) rest
  in
  loop n items
;;

let take n items =
  let rec loop remaining acc = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | item :: rest -> loop (remaining - 1) (item :: acc) rest
  in
  loop n [] items
;;

let compare_event_json left right =
  let by_time = Int64.compare (event_timestamp_ms right) (event_timestamp_ms left) in
  if by_time <> 0 then by_time else compare left right
;;

let now_ms () =
  (* NDT-OK: IDE bridge timestamps are runtime telemetry for operator ordering;
     they are not used to make deterministic build or scheduling decisions. *)
  Int64.of_float (Unix.gettimeofday () *. 1000.0)
;;

(* Tail-read at most [scan_budget] newest rows for one kind, then filter.
   Replaces the previous whole-file [fold_jsonl_lines] fold (O(file size))
   with a segment tail-read (O(scan_budget)). Order of the result is not
   significant — [list_events] sorts by timestamp before paging. *)
let list_kind_events ~base_path ~codebase ~kind ?keeper_id ~scan_budget () =
  let dir = Ide_paths.code_store_dir ~base_dir:base_path ~codebase in
  let path = Filename.concat dir (event_file_name kind) in
  let lines = tail_read_lines ~path ~budget:scan_budget in
  let jsons, _malformed = Fs_compat.parse_jsonl_lines ~source:path lines in
  List.filter
    (fun json -> event_matches_kind kind json && event_matches_keeper keeper_id json)
    jsons
;;

let list_events
    ~base_path
    ~codebase
    ?kind
    ?keeper_id
    ?limit
    ?offset
    ()
  =
  let kinds =
    match kind with
    | Some k -> [ k ]
    | None -> [ Tool; Turn ]
  in
  let limit = normalize_limit limit in
  let offset = normalize_offset offset in
  (* A keeper-filtered read scans a bounded tail window so a sparse keeper
     still surfaces recent events; an unfiltered read only needs the page. *)
  let scan_budget =
    let page = offset + limit in
    match keeper_id with
    | None -> page
    | Some _ -> max page max_keeper_filter_scan_lines
  in
  let events =
    List.concat_map
      (fun kind -> list_kind_events ~base_path ~codebase ~kind ?keeper_id ~scan_budget ())
      kinds
    |> List.sort compare_event_json
  in
  events |> drop offset |> take limit

let ingest_tool_event
    ~base_path
    ~codebase
    ~tool_name
    ~keeper_id
    ~turn_id
    ~outcome
    ~typed_outcome
    ~latency_ms
    ~summary
    ~file_path
    ~timestamp_ms
    ()
  =
  (* [String.sub] cuts at a byte, which splits a multi-byte character: a
     Korean summary is 3 bytes per character, so a raw cut at 200 emits an
     incomplete sequence roughly two times in three. [utf8_safe] backs the
     cut up to a character boundary and budgets for the suffix. *)
  let truncated_summary =
    String_util.utf8_safe ~max_bytes:200 ~suffix:"..." summary
    |> String_util.to_string
  in
  let event =
    Tool_event
      { tool_name
      ; keeper_id
      ; turn_id
      ; outcome
      ; typed_outcome
      ; latency_ms
      ; summary = truncated_summary
      ; file_path
      ; timestamp_ms
      }
  in
  (try append_event ~base_dir:base_path ~codebase ~event
   with
   | Eio.Cancel.Cancelled _ as e ->
     Printexc.raise_with_backtrace e (Printexc.get_raw_backtrace ())
   | exn ->
     Log.Ide.error "ingest_tool_event: %s" (Printexc.to_string exn))

(** Extract tool event parameters from raw hook data and ingest.
    This is the function called from [keeper_run_tools_hooks.on_tool_executed].
    Separated for direct testability. *)
let ingest_tool_event_from_hook
    ~base_path
    ~attribution
    ~tool_name
    ~keeper_id
    ~turn_id
    ~outcome
    ~typed_outcome_str
    ~duration_ms
    ~output_text
    ~(input : Yojson.Safe.t)
  =
  (* The attribution arrives minted (RFC-0378 §5.1); store directory and
     file path are both projections of it. Re-deriving the path from
     [input] here is what put absolute host paths, sandbox-rooted
     [repos/<id>/…] paths, and repo-relative paths in one store, none
     of which a reader can join against the rows the same resolver
     produced (masc#28582).

     RFC-0378 §5.2: the ide store persists addressed code facts only.
     Pathless and unaddressed tool facts stay on the bus; their durable
     record is the keeper tool_calls store. *)
  match attribution with
  | Agent_observation.Pathless
  | Agent_observation.File (Agent_observation.Unaddressed _) -> ()
  | Agent_observation.File (Agent_observation.Addressed addressed) ->
  let codebase = codebase_of_addressed addressed in
  let file_path = Some (file_path_of_addressed addressed) in
  let summary =
    String_util.utf8_safe ~max_bytes:200 ~suffix:"" output_text
    |> String_util.to_string
  in
  let timestamp_ms = now_ms () in
  ingest_tool_event
    ~base_path
    ~codebase
    ~tool_name
    ~keeper_id
    ~turn_id
    ~outcome
    ~typed_outcome:typed_outcome_str
    ~latency_ms:(int_of_float duration_ms)
    ~summary
    ~file_path
    ~timestamp_ms
    ()

let install_agent_observation_sinks () =
  (* Tool/turn sinks fire on the keeper turn fiber (main Eio domain). Their
     bodies parse tool output (Yojson) and append JSONL — synchronous I/O that
     stalls the fleet under load. Defer that work to the ingestion writer fiber
     via [Ide_ingest_queue.submit]: the hot path only allocates a closure and
     enqueues; the parse+append run off-domain. When no writer is installed
     (tests, pre-bootstrap) [submit] runs inline, preserving prior behavior. *)
  Agent_observation.register_tool_event_sink
    (fun (event : Agent_observation.tool_event) ->
      Ide_ingest_queue.submit (fun () ->
        ingest_tool_event_from_hook
          ~base_path:event.base_path
          ~attribution:event.attribution
          ~tool_name:event.tool_name
          ~keeper_id:event.keeper_id
          ~turn_id:event.turn_id
          ~outcome:event.outcome
          ~typed_outcome_str:event.typed_outcome
          ~duration_ms:event.duration_ms
          ~output_text:event.output_text
          ~input:event.input))
;;

(* Expose the rotation/tail-read internals so tests can drive them with
   small thresholds without writing multi-megabyte segments. Not part of
   the production surface. *)
module For_testing = struct
  let append_rotating = append_rotating
  let tail_read_lines = tail_read_lines
  let segment_paths_newest_first = segment_paths_newest_first
  let archive_indices = archive_indices
end

let () = install_agent_observation_sinks ()
