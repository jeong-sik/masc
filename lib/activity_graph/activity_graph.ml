(** Activity_graph — event storage, graph building, and agent spans. *)

(* Re-export sub-modules *)
include Activity_graph_types
include Activity_graph_registry
include Activity_graph_reducer

module StringMap = Set_util.StringMap
module StringSet = Set_util.StringSet

(* ================================================================ *)
(* File storage paths                                               *)
(* ================================================================ *)

(* The directory this store occupies under [.masc]. Exposed so readers of the
   same store name it from here instead of spelling the literal. *)
let store_dirname = "activity-events"

let root_dir (config : Workspace_utils.config) =
  Filename.concat (Workspace_utils.masc_dir config) store_dirname

(* [Jsonl_writer] owns the YYYY-MM/DD.jsonl layout. This module used to spell
   it out again, and it read the clock once for the month and once more for
   the day, so a write that crossed midnight on the last of a month could put
   the new day's file under the old month's directory (#27143). *)
let current_dated_path (config : Workspace_utils.config) =
  Jsonl_writer.dated_path_now ~base_dir:(root_dir config)

let day_path (config : Workspace_utils.config) =
  (current_dated_path config).Jsonl_writer.path

let seq_path (config : Workspace_utils.config) =
  Filename.concat (root_dir config) "_seq"

let lock_path (config : Workspace_utils.config) =
  Filename.concat (root_dir config) "_stream"

(* Takes the path the caller is about to append to, so the directory made and
   the file opened come from one reading of the clock. *)
let ensure_dirs config (dated : Jsonl_writer.dated_path) =
  Workspace_utils.mkdir_p (root_dir config);
  (* [month_dir] is the directory name, not a path; the full one is here. *)
  Workspace_utils.mkdir_p (Filename.dirname dated.Jsonl_writer.path)

let read_current_seq config =
  match Safe_ops.read_file_safe (seq_path config) with
  | Ok raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some value -> value
      | None -> 0)
  | Error _ -> 0

let write_current_seq config seq =
  Fs_compat.save_file (seq_path config) (string_of_int seq)

let append_line path line =
  Fs_compat.append_file path line

let sanitize_entity_ref (value : entity_ref) =
  {
    kind = Safe_ops.sanitize_text_utf8 value.kind;
    id = Safe_ops.sanitize_text_utf8 value.id;
  }

let sanitize_event (value : event) =
  {
    value with
    ts_iso = Safe_ops.sanitize_text_utf8 value.ts_iso;
    kind = Safe_ops.sanitize_text_utf8 value.kind;
    actor = Option.map sanitize_entity_ref value.actor;
    subject = Option.map sanitize_entity_ref value.subject;
    payload = Safe_ops.sanitize_json_utf8 value.payload;
    tags = List.map Safe_ops.sanitize_text_utf8 value.tags;
  }

(* P3-4: trace the upstream emitter when sanitize_event actually repairs
   invalid UTF-8.  We compare field values with physical equality (==)
   to detect whether sanitization changed any bytes.  sanitize_text_utf8
   and sanitize_json_utf8 both return the original object unchanged when
   no repair is needed, so == is a reliable O(1) change detector for
   string and json values.
   Note: entity_ref is a record and Option.map / List.map always allocate
   new wrappers, so actor/subject/tags are compared field-by-field.
   This surfaces "which kind of event / actor had invalid UTF-8 at the emit
   site" without requiring post-hoc forensics on the read-path repair log.
   Log fires once per (kind × actor) via a new call since the Warn channel
   has no built-in dedup; operators should correlate with the Otel_metric_store
   repair counter for frequency. *)
let sanitize_event_traced (value : event) : event =
  let sanitized = sanitize_event value in
  (* entity_ref fields: both sanitize_text_utf8 calls return the original
     string when no repair is needed. *)
  let entity_ref_changed (sa : entity_ref option) (oa : entity_ref option) =
    match sa, oa with
    | None, None -> false
    | Some sa', Some oa' ->
        not (sa'.kind == oa'.kind) || not (sa'.id == oa'.id)
    | _ -> true
  in
  (* Fast change detection via physical equality — sanitize_text_utf8 and
     sanitize_json_utf8 return the original object when no repair is done.
     List.map always allocates a new list, so tags are compared element-wise. *)
  let changed =
    not (sanitized.ts_iso == value.ts_iso)
    || not (sanitized.kind == value.kind)
    || entity_ref_changed sanitized.actor value.actor
    || entity_ref_changed sanitized.subject value.subject
    || not (sanitized.payload == value.payload)
    (* tags: List.map preserves length, so exists2 is safe here.  We still
       handle the length-mismatch case explicitly (returns "changed") in
       case sanitize_event is ever modified to filter items. *)
    || (let n = List.length value.tags in
        if List.length sanitized.tags <> n then true
        else
          List.exists2 (fun st ot -> not (st == ot)) sanitized.tags value.tags)
  in
  if changed then begin
    let actor_str = match value.actor with
      | Some a -> a.id
      | None -> "<none>"
    in
    Log.Misc.warn
      "[activity_graph] UTF-8 repaired at emit kind=%s actor=%s \
       — upstream emitter sent invalid UTF-8; trace the caller that \
       constructs payloads for this (kind, actor) pair"
      value.kind actor_str
  end;
  sanitized


let format_sse_event_data ~seq data =
  Printf.sprintf "id: %d\nevent: activity\ndata: %s\n\n" seq data


(* ================================================================ *)
(* Event reading                                                    *)
(* ================================================================ *)

let parse_event_line line =
  match Safe_ops.parse_json_safe ~context:"activity_graph:event_line" line with
  | Ok json -> event_of_yojson json
  | Error _ -> None

let collect_event_files config =
  let root = root_dir config in
  if not (Sys.file_exists root) then
    []
  else
    Sys.readdir root
    |> Array.to_list
    |> List.sort compare
    |> List.filter_map (fun month ->
           let month_path = Filename.concat root month in
           if Sys.file_exists month_path && Sys.is_directory month_path then
             Some
               (Sys.readdir month_path
               |> Array.to_list
               |> List.sort compare
               |> List.filter_map (fun name ->
                      if Filename.check_suffix name ".jsonl" then
                        Some (Filename.concat month_path name)
                      else
                        None))
           else
             None)
    |> List.flatten

let repair_event_file_utf8_once config path =
  let content = Fs_compat.load_file path in
  if String.is_valid_utf_8 content then
    content
  else
    Workspace_utils.with_file_lock config (lock_path config) (fun () ->
        let latest = Fs_compat.load_file path in
        if String.is_valid_utf_8 latest then
          latest
        else
          let repair =
            Safe_ops.repair_utf8_text_with_stats ~surface:"activity_graph"
              ~path:("event_file:" ^ path)
              latest
          in
          if not repair.changed then
            latest
          else begin
            (if String.equal path (day_path config) then
               Log.Misc.warn
                 "[activity_graph] UTF-8 repaired current event file in memory path=%s \
                  invalid_bytes=%d action=read_only_current_day"
                 path repair.invalid_bytes
             else
               match Fs_compat.save_file_atomic path repair.text with
               | Ok () ->
                   Log.Misc.warn
                     "[activity_graph] UTF-8 repaired persisted event file path=%s \
                      invalid_bytes=%d action=rewrite_once"
                     path repair.invalid_bytes
               | Error msg ->
                   Log.Misc.warn
                     "[activity_graph] UTF-8 repaired event file in memory path=%s \
                      invalid_bytes=%d action=rewrite_failed error=%s"
                     path repair.invalid_bytes msg);
            repair.text
          end)

let parse_events_from_file config path =
  let content = repair_event_file_utf8_once config path in
  let lines = String.split_on_char '\n' content in
  List.filter_map
    (fun line ->
      if String.trim line = "" then None else parse_event_line line)
    lines

(* RFC-0201 Step 4 — past-day file cache.

   [read_all_events] historically full-scans every activity-events
   JSONL file on every call.  With 15+ MB of historic data that
   compute dominated the background refresh fiber and undermined
   the Step 1 wait-free read (snapshot only refreshes after the
   fiber finishes one full scan).

   Past-day files are immutable: once the calendar day rolls over,
   no process appends to that JSONL again.  Cache the parsed event
   list per full file fingerprint. On re-read, if device/inode/size/mtime/ctime
   match the cached
   entry, reuse the parsed list and skip [Fs_compat.load_file] +
   line split + parse.  Only the current-day file (whose fingerprint
   changes on append) is reparsed each refresh. *)
module Past_day_path_map = Stdlib.Map.Make (String)

type file_fingerprint =
  { device : int
  ; inode : int
  ; size : int
  ; mtime : float
  ; ctime : float
  }

let file_fingerprint path =
  match Unix.stat path with
  | st ->
    Some
      { device = st.Unix.st_dev
      ; inode = st.Unix.st_ino
      ; size = st.Unix.st_size
      ; mtime = st.Unix.st_mtime
      ; ctime = st.Unix.st_ctime
      }
  | exception (Unix.Unix_error _ | Sys_error _) -> None
;;

let same_file_identity left right =
  left.device = right.device && left.inode = right.inode
;;

let same_file_fingerprint left right =
  same_file_identity left right
  && left.size = right.size
  && Float.equal left.mtime right.mtime
  && Float.equal left.ctime right.ctime
;;

let same_file_signature left right =
  List.equal
    (fun (left_path, left_fingerprint) (right_path, right_fingerprint) ->
       String.equal left_path right_path
       && Option.equal same_file_fingerprint left_fingerprint right_fingerprint)
    left
    right
;;

(* What the caches are holding, so an operator reads it instead of estimating
   it. Sizing this from outside meant taking process RSS, reading [live_words]
   off /health, and multiplying the on-disk JSONL by a guessed parse factor --
   an estimate that lands within a factor of two and settles nothing. The
   parsed record count is the number that matters: it is what a retention
   change moves, and RFC-0201 Step 4 sized this design against "15+ MB of
   historic data" that is now an order of magnitude larger.

   A read, not a gauge: this module has no metric dependency, and the caller
   that already exports gauges decides how often to look. *)
type cache_stats = {
  past_day_files : int;  (** parsed day files held *)
  past_day_records : int;  (** events across them *)
}

(* P0-4 (masc perf root-cause report, 2026-07-15, item (1)): the 2s
   [Dashboard_snapshot.refresh_loop] calls [read_all_events] up to 3x per
   tick — [json_response], [graph_json], and [agent_spans_json] each call
   [list_events_with_meta] / [list_events_with_total] independently — and
   every call full-reparsed the current-day JSONL via
   [parse_events_from_file] (measured 1.2 MB typical, 23 MB peak; Yojson
   lexing dominated idle CPU). Past-day files already get incremental
   treatment via [past_day_cache] above; this extends the same
   boundary-keyed design used by
   [Telemetry_unified.trajectory_summary_cache] (telemetry_unified.ml
   ~L791-847) and [Dated_jsonl.file_count_cache] (dated_jsonl.ml
   ~L537-598) to the current-day file. Unlike those two (which cache an
   aggregate), this caches the *parsed event list* itself, since all
   three payload builders need the raw events, not just a count — so
   caching here transparently de-duplicates all 3 per-tick calls (and any
   non-default HTTP query) without threading a shared value through
   [Dashboard_snapshot.compute]. *)
type current_day_entry = {
  cd_fingerprint : file_fingerprint;
  cd_events : event list;  (* unsorted — callers always re-sort by [seq] *)
}

type all_events_cache_entry =
  { signature : (string * file_fingerprint option) list
  ; events : event list
  }

type all_events_workspace_cache =
  { root : string
  ; mutex : Stdlib.Mutex.t
  ; mutable entry : all_events_cache_entry option
  ; (* The merged, seq-sorted events of every file EXCEPT the current day,
       keyed on those files' own signature. [entry] above is keyed on every
       file including today's, and today's grows on nearly every tick, so
       [entry] misses almost always -- 2026-08-29 measured 6,072 of 440,068
       retained events (1.4%) landing in the current-day file. Without this
       the miss re-concatenated and re-sorted all 440,068 on every miss, for
       a page of 500. Past files never change once the day rolls over, so
       their merge is computed once and reused until a file is added,
       rotated, or evicted. *)
    mutable past_merged : all_events_cache_entry option
  ; mutable past_day_cache :
      (file_fingerprint * event list) Past_day_path_map.t
  ; current_day_cache : (string, current_day_entry) Hashtbl.t
  ; mutable last_used : int
  ; mutable active_users : int
  }

(* The three default dashboard activity projections are built back-to-back.
   Per-file caches avoid JSON parsing, but [read_all_events] still rebuilt and
   sorted the complete retained event list independently for each projection.
   Cache that immutable aggregate per workspace by a full file fingerprint so
   unchanged readers share one sorted list without serializing other roots. *)
let all_events_workspace_caches :
    (string, all_events_workspace_cache) Hashtbl.t =
  Hashtbl.create 4

let all_events_workspace_caches_mu = Stdlib.Mutex.create ()
let all_events_workspace_cache_limit = 16
let all_events_workspace_use_counter = ref 0
let all_events_rebuild_counter = Atomic.make 0

(* Rebuilds of the past-day merge specifically. [all_events_rebuild_counter]
   above counts aggregate misses, which happen on nearly every append; this
   one has to stay flat across those, because the past files did not move. *)
let past_merged_rebuild_counter = Atomic.make 0

let evict_lru_idle_workspace_cache () =
  let candidate =
    Hashtbl.fold
      (fun candidate_root candidate current ->
         if candidate.active_users <> 0
         then current
         else
           match current with
           | None -> Some (candidate_root, candidate.last_used)
           | Some (_, oldest) when candidate.last_used < oldest ->
             Some (candidate_root, candidate.last_used)
           | Some _ -> current)
      all_events_workspace_caches
      None
  in
  match candidate with
  | None -> false
  | Some (root, _) ->
    Hashtbl.remove all_events_workspace_caches root;
    true
;;

let acquire_all_events_workspace_cache root =
  Stdlib.Mutex.protect all_events_workspace_caches_mu (fun () ->
    incr all_events_workspace_use_counter;
    let last_used = !all_events_workspace_use_counter in
    match Hashtbl.find_opt all_events_workspace_caches root with
    | Some cache ->
      cache.last_used <- last_used;
      cache.active_users <- cache.active_users + 1;
      cache
    | None ->
      if Hashtbl.length all_events_workspace_caches >= all_events_workspace_cache_limit
      (* See [evict_lru_idle_workspace_cache]: its boolean is diagnostic only. *)
      then ignore (evict_lru_idle_workspace_cache ());
      let cache =
        { root
        ; mutex = Stdlib.Mutex.create ()
        ; entry = None
        ; past_merged = None
        ; past_day_cache = Past_day_path_map.empty
        ; current_day_cache = Hashtbl.create 1
        ; last_used
        ; active_users = 1
        }
      in
      Hashtbl.add all_events_workspace_caches root cache;
      cache)
;;

let release_all_events_workspace_cache cache =
  Stdlib.Mutex.protect all_events_workspace_caches_mu (fun () ->
    match Hashtbl.find_opt all_events_workspace_caches cache.root with
    | Some current when current == cache ->
      cache.active_users <- max 0 (cache.active_users - 1);
      if Hashtbl.length all_events_workspace_caches > all_events_workspace_cache_limit
      (* See [evict_lru_idle_workspace_cache]: release only needs its effect. *)
      then ignore (evict_lru_idle_workspace_cache ())
    | None | Some _ -> ())
;;

let reset_all_events_cache_for_testing () =
  Stdlib.Mutex.protect all_events_workspace_caches_mu (fun () ->
    Hashtbl.reset all_events_workspace_caches;
    all_events_workspace_use_counter := 0);
  Atomic.set all_events_rebuild_counter 0;
  Atomic.set past_merged_rebuild_counter 0
;;

let current_day_rebuild_counter = Atomic.make 0

let reset_past_day_cache_for_testing () =
  let caches =
    Stdlib.Mutex.protect all_events_workspace_caches_mu (fun () ->
      Hashtbl.fold (fun _ cache acc -> cache :: acc) all_events_workspace_caches [])
  in
  List.iter
    (fun cache ->
       Stdlib.Mutex.protect cache.mutex (fun () ->
         cache.past_day_cache <- Past_day_path_map.empty;
         cache.entry <- None))
    caches
;;

let cache_stats () =
  let caches =
    Stdlib.Mutex.protect all_events_workspace_caches_mu (fun () ->
      Hashtbl.fold (fun _ cache acc -> cache :: acc) all_events_workspace_caches [])
  in
  List.fold_left
    (fun stats cache ->
       let files, records =
         Stdlib.Mutex.protect cache.mutex (fun () ->
           ( Past_day_path_map.cardinal cache.past_day_cache
           , Past_day_path_map.fold
               (fun _ (_, events) acc -> acc + List.length events)
               cache.past_day_cache
               0 ))
       in
       { past_day_files = stats.past_day_files + files
       ; past_day_records = stats.past_day_records + records
       })
    { past_day_files = 0; past_day_records = 0 }
    caches
;;

let reset_current_day_cache_for_testing () =
  reset_all_events_cache_for_testing ();
  Atomic.set current_day_rebuild_counter 0

(* The current-day file is mutable. An exact full fingerprint hit is safe to
   reuse; every change takes one repair-aware full reparse. The dashboard now
   refreshes activity projections on a bounded component TTL and the aggregate
   cache shares this parsed list, so correctness does not depend on proving an
   append-only prefix across external writers. *)
let parse_current_day_events_cached cache config path : event list =
  match file_fingerprint path with
  | None -> parse_events_from_file config path
  | Some fingerprint ->
    (match Hashtbl.find_opt cache.current_day_cache path with
     | Some entry
       when same_file_fingerprint entry.cd_fingerprint fingerprint ->
       entry.cd_events
     | None | Some _ ->
       let events = parse_events_from_file config path in
       Atomic.incr current_day_rebuild_counter;
       (match file_fingerprint path with
        | Some after when same_file_fingerprint fingerprint after ->
          Hashtbl.replace cache.current_day_cache path
            { cd_fingerprint = after; cd_events = events }
        | None | Some _ -> ());
       events)

(* P0-4 item (2): [past_day_cache] never removed an entry once inserted, so
   a file pruned from disk by the existing 24h [MASC_JSONL_RETENTION_DAYS]
   maintenance sweep (server_bootstrap_maintenance.ml, same
   activity-events directory, default 30 days) stayed cached forever —
   unbounded growth over the process lifetime (report item (6)).
   Reconcile both caches against the live file set on every
   [read_all_events] call: entries whose path is no longer present are
   dropped. This never evicts a file [collect_event_files] would still
   touch, so it cannot regress the hit rate for anything still on disk —
   it only reclaims memory for files that are gone and would never be
   looked up again. Deliberately NOT a second, independent "keep last N
   days" cap: that would require either (a) bounding [read_all_events]'s
   scan itself, which would change [total_matching_events] /
   [events_store_total] output for stores with low daily event volume (a
   real behavior change, out of scope here), or (b) a second retention
   constant parallel to [MASC_JSONL_RETENTION_DAYS] that could drift from
   it — the "Scattered Hardcoded Defaults" anti-pattern
   software-development.md warns against. Mirroring the existing knob
   instead of introducing a new one keeps a single retention SSOT. *)
let evict_stale_cache_entries cache ~live_paths =
  let live_set = StringSet.of_list live_paths in
  cache.past_day_cache <-
    Past_day_path_map.filter
      (fun path _ -> StringSet.mem path live_set)
      cache.past_day_cache;
  Hashtbl.filter_map_inplace
    (fun path entry -> if StringSet.mem path live_set then Some entry else None)
    cache.current_day_cache

let read_all_events config =
  let root = root_dir config in
  let cache = acquire_all_events_workspace_cache root in
  Fun.protect
    ~finally:(fun () -> release_all_events_workspace_cache cache)
    (fun () ->
       Stdlib.Mutex.protect cache.mutex (fun () ->
         let current_day = day_path config in
         let files = collect_event_files config in
         evict_stale_cache_entries cache ~live_paths:files;
         let signature_for paths =
           List.map (fun path -> path, file_fingerprint path) paths
         in
         let signature = signature_for files in
         match cache.entry with
         | Some cached when same_file_signature cached.signature signature ->
           cached.events
         | None | Some _ ->
           let by_seq (a : event) (b : event) = Int.compare a.seq b.seq in
           let past_files =
             List.filter (fun path -> not (String.equal path current_day)) files
           in
           let past_signature = signature_for past_files in
           let past_events =
             match cache.past_merged with
             | Some cached
               when same_file_signature cached.signature past_signature ->
               cached.events
             | None | Some _ ->
               let merged =
                 past_files
                 |> List.fold_left
                      (fun acc path ->
                         let rows =
                           match file_fingerprint path with
                           | None -> parse_events_from_file config path
                           | Some fingerprint ->
                             (match
                                Past_day_path_map.find_opt path cache.past_day_cache
                              with
                              | Some (cached_fingerprint, parsed)
                                when same_file_fingerprint
                                       cached_fingerprint
                                       fingerprint ->
                                parsed
                              | None | Some _ ->
                                let parsed = parse_events_from_file config path in
                                cache.past_day_cache <-
                                  Past_day_path_map.add
                                    path
                                    (fingerprint, parsed)
                                    cache.past_day_cache;
                                parsed)
                         in
                         List.rev_append rows acc)
                      []
                 |> List.sort by_seq
               in
               Atomic.incr past_merged_rebuild_counter;
               cache.past_merged <-
                 Some { signature = past_signature; events = merged };
               merged
           in
           let current_events =
             if List.exists (fun path -> String.equal path current_day) files
             then
               parse_current_day_events_cached cache config current_day
               |> List.sort by_seq
             else []
           in
           (* Both sides are seq-sorted, so the join is a linear merge rather
              than a sort of the concatenation. Sorting the whole retained
              history was the cost this split removes. *)
           let events = List.merge by_seq past_events current_events in
           Atomic.incr all_events_rebuild_counter;
           let files_after = collect_event_files config in
           let signature_after = signature_for files_after in
           if same_file_signature signature_after signature
           then cache.entry <- Some { signature; events };
           events))

let max_event_seq events =
  List.fold_left (fun acc (value : event) -> max acc value.seq) 0 events

let matches_filters ?(kinds = []) (value : event) =
  kinds = [] || List.mem value.kind kinds

(** Returns [(page, total_matching, latest_store_seq, latest_matching_seq)].
    [total_matching] and [latest_matching_seq] are computed before [limit].
    [latest_store_seq] is the max of the persisted sequence counter and the
    JSONL rows so a stale [_seq] file cannot make dashboard cursors move
    backward. *)
(* [keep] runs with the other filters, BEFORE [limit] pages the result, so
   [limit] counts events the caller wanted. Applying it afterwards discards
   part of the page and leaves the caller unable to say how wide a page it
   needs — the read already loads the whole log, so a caller that filtered
   later had to inflate [limit] and still lost its oldest events to a busier
   agent. *)
(* [keep] is optional so the unfiltered callers can say so. The three default
   dashboard projections ask for the whole store with no kind, no cursor and
   no time bound; running [List.filter] for them rebuilt the retained list,
   cons by cons, to hand back the same events. With nothing to filter the
   page is a suffix of the cached list and [List.drop] shares that list's
   tail, so the rebuild is gone: [List.length] still walks but allocates
   nothing, and [max_event_seq] reuses the value computed above because the
   list is the same one.

   Sizing this honestly: at 440,068 retained events the copy is roughly 10MB
   of list cells, which is not where activity_events_default's 2,909MB comes
   from. That figure is a cold parse -- the per-file parse caches are process
   memory, so the first read after a restart re-parses the whole store, and
   the warning lands exactly once per boot (measured across 8 consecutive
   boots on 2026-08-29/30, 2,905MB to 2,920MB, one per boot). masc#31722
   carries that. This removes a copy that had no reason to exist; it does not
   remove the parse. *)
let list_events_with_meta config ?(kinds = []) ~after_seq ~limit ?keep
    ?since_ms () =
  let stored = read_all_events config in
  let stored_max_seq = max_event_seq stored in
  let latest_store_seq = max (read_current_seq config) stored_max_seq in
  let filtered =
    after_seq > 0
    || kinds <> []
    || Option.is_some keep
    || Option.is_some since_ms
  in
  let all =
    if not filtered then
      stored
    else
      stored
      |> List.filter (fun value ->
             value.seq > after_seq
             && matches_filters ~kinds value
             && (match keep with None -> true | Some keep -> keep value)
             && (match since_ms with
                 | None -> true
                 | Some ms -> value.ts_ms >= ms))
  in
  let total = List.length all in
  let page =
    if after_seq > 0 then
      List.take limit all
    else
      all |> List.drop (max 0 (total - limit))
  in
  let latest_matching_seq = if filtered then max_event_seq all else stored_max_seq in
  (page, total, latest_store_seq, latest_matching_seq)

(** Returns [(page, total_matching)] where [total_matching] is the count
    of all events matching filters before [limit] is applied. *)
let list_events_with_total config ?(kinds = []) ~after_seq ~limit
    ?since_ms () =
  let page, total, _latest_store_seq, _latest_matching_seq =
    list_events_with_meta config ~kinds ~after_seq ~limit ?since_ms ()
  in
  (page, total)

let list_events config ?(kinds = []) ~after_seq ~limit ~keep () =
  let page, _total, _latest_store_seq, _latest_matching_seq =
    list_events_with_meta config ~kinds ~after_seq ~limit ~keep ()
  in
  page

let window_meta ~limit ~events_shown ~events_store_total
    ?(extra = []) () : Yojson.Safe.t =
  `Assoc ([
    ("limit", `Int limit);
    ("events_shown", `Int events_shown);
    ("events_store_total", `Int events_store_total);
    ("has_more", `Bool (events_store_total > events_shown));
  ] @ extra)


let activity_events_store_path config = root_dir config

(* ================================================================ *)
(* Event emission                                                   *)
(* ================================================================ *)

let emit config ?actor ?subject ?(tags = []) ~kind ~payload () =
  let value, json_line =
    Workspace_utils.with_file_lock config (lock_path config) (fun () ->
        let dated = current_dated_path config in
        ensure_dirs config dated;
        let seq = read_current_seq config + 1 in
        write_current_seq config seq;
        let value =
          {
            seq;
            ts_ms = now_ts_ms ();
            ts_iso = Masc_domain.now_iso ();
            kind;
            actor;
            subject;
            payload;
            tags;
          }
          |> sanitize_event_traced
        in
        let json_line = Yojson.Safe.to_string (event_to_yojson value) in
        append_line dated.Jsonl_writer.path (json_line ^ "\n");
        (value, json_line))
  in
  let encoded = format_sse_event_data ~seq:value.seq json_line in
  let snapshot =
    with_registry_ro (fun () -> Hashtbl.fold (fun key client acc -> (key, client) :: acc) clients [])
  in
  let failed = ref [] in
  List.iter
    (fun (session_id, client) ->
      if value.seq > client.last_seq && client_matches client value then
        (try
          client.push encoded;
          client.last_seq <- value.seq
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            Log.Misc.warn "SSE push failed for %s: %s" session_id (Printexc.to_string exn);
            failed := session_id :: !failed))
    snapshot;
  List.iter unregister !failed;
  value

(* ================================================================ *)
(* JSON response                                                    *)
(* ================================================================ *)

let json_response config ?(kinds = []) ~after_seq ~limit () =
  let events, total_matching, latest_store_seq, latest_matching_seq =
    list_events_with_meta config ~kinds ~after_seq ~limit ()
  in
  let next_after_seq =
    match List.rev events with
    | last :: _ -> last.seq
    | [] -> after_seq
  in
  `Assoc
    [
      ("generated_at_iso", `String (Masc_domain.now_iso ()));
      ("dashboard_surface", `String "/api/v1/activity/events");
      ("source", `String "activity_graph_jsonl");
      ( "retention",
        `Assoc
          [
            ("scope", `String "activity_events");
            ("workspace_root", `String (Workspace_utils.masc_dir config));
            ("durable_store", `String (activity_events_store_path config));
            ("file_pattern", `String "activity-events/YYYY-MM/DD.jsonl");
            ("seq_counter", `String (seq_path config));
            ( "cache_policy",
              `String
                "uncached; reads persisted JSONL rows; delta cursor via after_seq" );
          ] );
      ( "query",
        `Assoc
          [
            ("after_seq", `Int after_seq);
            ("limit", `Int limit);
            ("kinds", `List (List.map (fun value -> `String value) kinds));
          ] );
      ("events", `List (List.map event_to_yojson events));
      ("count", `Int (List.length events));
      ("total_matching_events", `Int total_matching);
      ("after_seq", `Int after_seq);
      ("next_after_seq", `Int next_after_seq);
      ("limit", `Int limit);
      ("kinds", `List (List.map (fun value -> `String value) kinds));
      ("latest_seq", `Int latest_store_seq);
      ("latest_matching_seq", `Int latest_matching_seq);
    ]

(* ================================================================ *)
(* Graph building                                                   *)
(* ================================================================ *)

let graph_json config ?(kinds = []) ?(limit = 500)
    ?(timeline_limit = 80) ?since_ms () =
  let events, events_store_total =
    list_events_with_total config ~kinds ~after_seq:0 ~limit ?since_ms ()
  in
  let kind_counts_json =
    let counts =
      List.fold_left
        (fun acc (e : event) ->
          let prev = StringMap.find_opt e.kind acc |> Option.value ~default:0 in
          StringMap.add e.kind (prev + 1) acc)
        StringMap.empty
        events
    in
    `Assoc
      (StringMap.fold
         (fun kind count acc -> (kind, `Int count) :: acc)
         counts []
      |> List.sort (fun (a, _) (b, _) -> String.compare a b))
  in
  let heatmap_json =
    let matrix = Array.init 7 (fun _ -> Array.make 24 0) in
    let max_count = ref 0 in
    List.iter
      (fun (e : event) ->
        let tm = Unix.localtime (float_of_int e.ts_ms /. 1000.0) in
        let day = if tm.tm_wday = 0 then 6 else tm.tm_wday - 1 in
        let hour = tm.tm_hour in
        let next_count = matrix.(day).(hour) + 1 in
        matrix.(day).(hour) <- next_count;
        if next_count > !max_count then max_count := next_count)
      events;
    let matrix_json =
      `List
        (Array.to_list
           (Array.map
              (fun row ->
                `List
                  (Array.to_list
                     (Array.map (fun count -> `Int count) row)))
              matrix))
    in
    `Assoc
      [
        ("matrix", matrix_json);
        ("max", `Int !max_count);
        ("total", `Int (List.length events));
      ]
  in
  let nodes = Hashtbl.create 64 in
  let edges = Hashtbl.create 96 in
  List.iter (reduce_event ~nodes ~edges) events;
  let nodes_json =
    Hashtbl.fold
      (fun _ node acc ->
        graph_node_to_yojson
          {
            id = node.node_id;
            kind = node.node_kind;
            label = node.label;
            status = node.status;
            weight = node.weight;
            last_event_at = node.last_event_at;
            meta = node.meta;
          }
        :: acc)
      nodes []
    |> List.sort (fun a b ->
           compare ((match Json_util.assoc_member_opt "id" a with Some (`String s) -> s | _ -> "")) ((match Json_util.assoc_member_opt "id" b with Some (`String s) -> s | _ -> "")))
  in
  let edges_json =
    Hashtbl.fold
      (fun _ edge acc ->
        graph_edge_to_yojson
          {
            id = edge.edge_id;
            source = edge.source;
            target = edge.target;
            kind = edge.edge_kind;
            weight = edge.weight;
            active = edge.active;
            last_event_at = edge.last_event_at;
            meta = edge.meta;
          }
        :: acc)
      edges []
    |> List.sort (fun a b ->
           compare ((match Json_util.assoc_member_opt "id" a with Some (`String s) -> s | _ -> "")) ((match Json_util.assoc_member_opt "id" b with Some (`String s) -> s | _ -> "")))
  in
  let timeline =
    let total = List.length events in
    events |> List.drop (max 0 (total - timeline_limit))
  in
  let count_kind prefix =
    nodes_json
    |> List.fold_left
         (fun acc node ->
           match Json_util.assoc_member_opt "kind" node with
           | Some (`String kind) when String.equal kind prefix -> acc + 1
           | _ -> acc)
         0
  in
  let active_agents =
    nodes_json
    |> List.fold_left
         (fun acc node ->
           match (Json_util.assoc_member_opt "kind" node, Json_util.assoc_member_opt "status" node) with
           | Some (`String "agent"), Some (`String status)
             when
               not
                 (List.mem status
                    [ "offline"; "retired"; "stopped"; "finalized" ]) ->
               acc + 1
           | _ -> acc)
         0
  in
  let stats_history =
    let num_buckets = 12 in
    match events with
    | [] -> []
    | _ ->
        let min_ts = List.fold_left (fun m e -> min m e.ts_ms) max_int events in
        let max_ts = List.fold_left (fun m e -> max m e.ts_ms) 0 events in
        let range = max 1 (max_ts - min_ts) in
        let bucket_width = max 1 (range / num_buckets) in
        let buckets = Array.make num_buckets (0, (Hashtbl.create 4 : (string, bool) Hashtbl.t), 0) in
        Array.iteri (fun i _ ->
          buckets.(i) <- (0, Hashtbl.create 4, 0)
        ) buckets;
        List.iter (fun (e : event) ->
          let idx = min (num_buckets - 1) ((e.ts_ms - min_ts) / bucket_width) in
          let (count, agents_tbl, tasks_done) = buckets.(idx) in
          let new_tasks_done =
            tasks_done
            + (if String.equal e.kind
                 (Event_kind.Task.to_string Event_kind.Task.Done)
               then 1 else 0)
          in
          (match e.actor with
           | Some actor -> Hashtbl.replace agents_tbl actor.id true
           | None -> ());
          buckets.(idx) <- (count + 1, agents_tbl, new_tasks_done)
        ) events;
        Array.to_list (Array.mapi (fun i (count, agents_tbl, tasks_done) ->
          let bucket_start = min_ts + (i * bucket_width) in
          let bucket_end = if i = num_buckets - 1 then max_ts else bucket_start + bucket_width in
          `Assoc [
            ("bucket", `Int i);
            ("start_ms", `Int bucket_start);
            ("end_ms", `Int bucket_end);
            ("events", `Int count);
            ("active_agents", `Int (Hashtbl.length agents_tbl));
            ("tasks_done", `Int tasks_done);
          ]
        ) buckets)
  in
  `Assoc
    [
      ("generated_at", `String (Masc_domain.now_iso ()));
      ( "window",
        window_meta ~limit
          ~events_shown:(List.length events)
          ~events_store_total
          ~extra:[
            ("kinds", `List (List.map (fun value -> `String value) kinds));
          ] () );
      ( "stats",
        `Assoc
          [
            ("event_count", `Int (List.length events));
            ("edge_count", `Int (List.length edges_json));
            ("agent_count", `Int (count_kind "agent"));
            ("task_count", `Int (count_kind "task"));
            ("active_agents", `Int active_agents);
          ] );
      ("stats_history", `List stats_history);
      ("kind_counts", kind_counts_json);
      ("heatmap", heatmap_json);
      ("nodes", `List nodes_json);
      ("edges", `List edges_json);
      ("timeline", `List (List.map event_to_yojson timeline));
    ]

(* ================================================================ *)
(* Agent spans                                                      *)
(* ================================================================ *)

(* Span start events paired with their matching end events *)
let span_start_kind = function
  | "task.claimed" | "task.started" -> Some "task"
  | "agent.session_bound" -> Some "presence"
  | _ -> None

(** Issue #8711: single SSOT for span-ending event kinds. The previous
    [span_end_kind] / [span_end_status] pair reproduced the same
    alphabet in two places; if either gained a constructor without the
    other being updated the catch-all in [span_end_status] would
    silently map the new kind to [Span_ended], losing semantic
    information. Combining them forces both pieces to stay in sync at
    compile time (Parse, don't validate). *)
let span_end_classification = function
  | "task.done"                 -> Some ("task",      Span_completed)
  (* RFC-0323 G-3: approve-produced Done completes the task span too. *)
  | "task.approved"             -> Some ("task",      Span_completed)
  | "task.released"             -> Some ("task",      Span_released)
  | "task.cancelled"            -> Some ("task",      Span_cancelled)
  | _                           -> None



let agent_spans_json config ?(limit = 500) ?since_ms () =
  let events, events_store_total =
    list_events_with_total config ~kinds:[] ~after_seq:0 ~limit ?since_ms ()
  in
  let now_ms = now_ts_ms () in
  let open_spans : (string * string option, int * string * string) Hashtbl.t =
    Hashtbl.create 32
  in
  let closed_spans : agent_span list ref = ref [] in
  let agents_set : (string, bool) Hashtbl.t = Hashtbl.create 16 in
  List.iter (fun (e : event) ->
    let agent_id = match e.actor with
      | Some a -> Some a.id
      | None -> None
    in
    let subject_id = match e.subject with
      | Some s -> Some s.id
      | None -> None
    in
    match agent_id with
    | None -> ()
    | Some aid ->
        Hashtbl.replace agents_set aid true;
        (match span_start_kind e.kind with
         | Some sk ->
             let label = match subject_id with
               | Some sid -> sid
               | None -> e.kind
             in
             Hashtbl.replace open_spans (aid, subject_id) (e.ts_ms, sk, label)
         | None -> ());
        (match span_end_classification e.kind with
         | Some (ek, status) ->
             (* RFC-0323 G-3: on approve-produced completion the event actor
                is the VERIFIER, but the span was opened by the ASSIGNEE, who
                rides the payload (emitted since G-3). Close the assignee's
                span and attribute it to them; fall back to the actor for
                pre-G-3 events — mirrors the works_on-edge routing in
                [Activity_graph_reducer]. *)
             let closing_aid =
               match e.kind with
               | "task.approved" ->
                   (match Json_util.assoc_member_opt "assignee" e.payload with
                    | Some (`String name) when String.trim name <> "" -> name
                    | Some _ | None -> aid)
               | _ -> aid
             in
             let key = (closing_aid, subject_id) in
             (match Hashtbl.find_opt open_spans key with
              | Some (start_ms, sk, label) when String.equal sk ek ->
                  Hashtbl.remove open_spans key;
                  closed_spans := {
                    agent = closing_aid;
                    start_ms;
                    end_ms = e.ts_ms;
                    span_kind = sk;
                    label;
                    span_status = status;
                  } :: !closed_spans
              | None | Some _ -> ())
         | None -> ())
  ) events;
  Hashtbl.iter (fun (aid, _subj) (start_ms, sk, label) ->
    closed_spans := {
      agent = aid;
      start_ms;
      end_ms = now_ms;
      span_kind = sk;
      label;
      span_status = Span_open;
    } :: !closed_spans
  ) open_spans;
  let all_spans = List.rev !closed_spans in
  let agents = Hashtbl.fold (fun k _ acc -> k :: acc) agents_set []
    |> List.sort String.compare
  in
  let min_ms = List.fold_left (fun m (s : agent_span) -> min m s.start_ms) max_int all_spans in
  let max_ms = List.fold_left (fun m (s : agent_span) -> max m s.end_ms) 0 all_spans in
  let time_range_min = if all_spans = [] then now_ms else min_ms in
  let time_range_max = if all_spans = [] then now_ms else max_ms in
  `Assoc [
    ("agents", `List (List.map (fun a -> `String a) agents));
    ("spans", `List (List.map agent_span_to_yojson all_spans));
    ("time_range", `Assoc [
      ("min_ms", `Int time_range_min);
      ("max_ms", `Int time_range_max);
    ]);
    ("window",
     window_meta ~limit
       ~events_shown:(List.length events)
       ~events_store_total
       ~extra:[("spans_count", `Int (List.length all_spans))]
       ());
  ]

module For_testing = struct
  let reset_current_day_cache_for_testing = reset_current_day_cache_for_testing
  let reset_past_day_cache_for_testing = reset_past_day_cache_for_testing
  let current_day_rebuild_count () = Atomic.get current_day_rebuild_counter
  let all_events_rebuild_count () = Atomic.get all_events_rebuild_counter
  let past_merged_rebuild_count () = Atomic.get past_merged_rebuild_counter
  let touch_workspace_cache root =
    let cache = acquire_all_events_workspace_cache root in
    release_all_events_workspace_cache cache
  ;;

  let workspace_cache_count () =
    Stdlib.Mutex.protect all_events_workspace_caches_mu (fun () ->
      Hashtbl.length all_events_workspace_caches)
  ;;

  let workspace_cache_mem root =
    Stdlib.Mutex.protect all_events_workspace_caches_mu (fun () ->
      Hashtbl.mem all_events_workspace_caches root)
  ;;

  let past_day_cache_entry_count () =
    (cache_stats ()).past_day_files
  let current_day_path = day_path
end
