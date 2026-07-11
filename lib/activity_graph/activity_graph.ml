(** Activity_graph — event storage, graph building, and agent spans. *)

(* Re-export sub-modules *)
include Activity_graph_types
include Activity_graph_registry
include Activity_graph_reducer

module StringMap = Set_util.StringMap

(* ================================================================ *)
(* File storage paths                                               *)
(* ================================================================ *)

let root_dir (config : Workspace_utils.config) =
  Filename.concat (Workspace_utils.masc_dir config) "activity-events"

let month_dir (config : Workspace_utils.config) =
  let tm = Unix.gmtime (Time_compat.now ()) in
  Filename.concat (root_dir config)
    (Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1))

let day_path (config : Workspace_utils.config) =
  let tm = Unix.gmtime (Time_compat.now ()) in
  Filename.concat (month_dir config) (Printf.sprintf "%02d.jsonl" tm.tm_mday)

let seq_path (config : Workspace_utils.config) =
  Filename.concat (root_dir config) "_seq"

let lock_path (config : Workspace_utils.config) =
  Filename.concat (root_dir config) "_stream"

let ensure_dirs config =
  Workspace_utils.mkdir_p (root_dir config);
  Workspace_utils.mkdir_p (month_dir config)

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
    workspace_id = Safe_ops.sanitize_text_utf8 value.workspace_id;
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
    || not (sanitized.workspace_id == value.workspace_id)
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

let event_json_string (value : event) =
  value |> sanitize_event |> event_to_yojson |> Yojson.Safe.to_string

let format_sse_event_data ~seq data =
  Printf.sprintf "id: %d\nevent: activity\ndata: %s\n\n" seq data

let format_sse_event (value : event) =
  format_sse_event_data ~seq:value.seq (event_json_string value)

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
               let report = Fs_compat.save_file_atomic_eio path repair.text in
               Fs_compat.Durable_mutation.fold_report report
                 ~not_committed:(fun report ->
                   Log.Misc.warn
                     "[activity_graph] UTF-8 repaired event file in memory path=%s \
                      invalid_bytes=%d action=rewrite_not_committed error=%s"
                     path repair.invalid_bytes
                     (Fs_compat.Durable_mutation.report_to_string report))
                 ~committed_not_durable:(fun report ->
                   Log.Misc.warn
                     "[activity_graph] UTF-8 repair committed with sync debt path=%s \
                      invalid_bytes=%d detail=%s"
                     path repair.invalid_bytes
                     (Fs_compat.Durable_mutation.report_to_string report))
                 ~durable:(fun report ->
                   Log.Misc.warn
                     "[activity_graph] UTF-8 repaired persisted event file path=%s \
                      invalid_bytes=%d action=rewrite_once detail=%s"
                     path repair.invalid_bytes
                     (Fs_compat.Durable_mutation.report_to_string report)));
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
   list per (path, mtime).  On re-read, if mtime matches the cached
   entry, reuse the parsed list and skip [Fs_compat.load_file] +
   line split + parse.  Only the current-day file (whose mtime
   changes on append) is reparsed each refresh. *)
module Past_day_path_map = Stdlib.Map.Make (String)

(* [Atomic.t] holding an immutable persistent map keeps reads
   wait-free across HTTP fibers and the refresh fiber.  CAS update
   loses only the *parse result* on contention; the underlying
   file remains the SSOT, so a lost insert just causes a re-parse
   on the next call. *)
let past_day_cache : (float * event list) Past_day_path_map.t Atomic.t =
  Atomic.make Past_day_path_map.empty

let past_day_cache_lookup path mtime =
  match Past_day_path_map.find_opt path (Atomic.get past_day_cache) with
  | Some (cached_mtime, parsed) when Float.equal cached_mtime mtime ->
    Some parsed
  | _ -> None

let rec past_day_cache_insert path mtime parsed =
  let prev = Atomic.get past_day_cache in
  let next = Past_day_path_map.add path (mtime, parsed) prev in
  if not (Atomic.compare_and_set past_day_cache prev next) then
    past_day_cache_insert path mtime parsed

let file_mtime path =
  try Some (Unix.stat path).Unix.st_mtime with _ -> None

let read_all_events config =
  let current_day = day_path config in
  collect_event_files config
  |> List.fold_left
       (fun acc path ->
         let rows =
           if String.equal path current_day then
             (* Current-day file mtime changes on every append. *)
             parse_events_from_file config path
           else
             match file_mtime path with
             | None -> parse_events_from_file config path
             | Some mtime ->
               (match past_day_cache_lookup path mtime with
                | Some cached -> cached
                | None ->
                  let parsed = parse_events_from_file config path in
                  past_day_cache_insert path mtime parsed;
                  parsed)
         in
         List.rev_append rows acc)
       []
  |> List.sort (fun a b -> Int.compare a.seq b.seq)

let max_event_seq events =
  List.fold_left (fun acc (value : event) -> max acc value.seq) 0 events

let matches_filters ?(kinds = []) (value : event) =
  kinds = [] || List.mem value.kind kinds

(** Returns [(page, total_matching, latest_store_seq, latest_matching_seq)].
    [total_matching] and [latest_matching_seq] are computed before [limit].
    [latest_store_seq] is the max of the persisted sequence counter and the
    JSONL rows so a stale [_seq] file cannot make dashboard cursors move
    backward. *)
let list_events_with_meta config ?(kinds = []) ~after_seq ~limit
    ?since_ms () =
  let stored = read_all_events config in
  let latest_store_seq = max (read_current_seq config) (max_event_seq stored) in
  let all =
    stored
    |> List.filter (fun value ->
           value.seq > after_seq
           && matches_filters ~kinds value
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
  (page, total, latest_store_seq, max_event_seq all)

(** Returns [(page, total_matching)] where [total_matching] is the count
    of all events matching filters before [limit] is applied. *)
let list_events_with_total config ?(kinds = []) ~after_seq ~limit
    ?since_ms () =
  let page, total, _latest_store_seq, _latest_matching_seq =
    list_events_with_meta config ~kinds ~after_seq ~limit ?since_ms ()
  in
  (page, total)

let list_events config ?(kinds = []) ~after_seq ~limit () =
  let page, _total, _latest_store_seq, _latest_matching_seq =
    list_events_with_meta config ~kinds ~after_seq ~limit ()
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

let latest_seq config = read_current_seq config

let activity_events_store_path config = root_dir config

(* ================================================================ *)
(* Event emission                                                   *)
(* ================================================================ *)

let emit config ?actor ?subject ?(tags = []) ~kind ~payload () =
  let value, json_line =
    Workspace_utils.with_file_lock config (lock_path config) (fun () ->
        ensure_dirs config;
        let seq = read_current_seq config + 1 in
        write_current_seq config seq;
        let value =
          {
            seq;
            ts_ms = now_ts_ms ();
            ts_iso = Masc_domain.now_iso ();
            workspace_id = "default";  (* retained for JSONL backward compat *)
            kind;
            actor;
            subject;
            payload;
            tags;
          }
          |> sanitize_event_traced
        in
        let json_line = Yojson.Safe.to_string (event_to_yojson value) in
        append_line (day_path config) (json_line ^ "\n");
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
      ("workspace_id", `String "default");  (* backward compat *)
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
            semantic_weight = node.semantic_weight;
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
            ("workspace_id", `String "default");
            ("kinds", `List (List.map (fun value -> `String value) kinds));
          ] () );
      ( "stats",
        `Assoc
          [
            ("event_count", `Int (List.length events));
            ("node_count", `Int (List.length nodes_json));
            ("edge_count", `Int (List.length edges_json));
            ("agent_count", `Int (count_kind "agent"));
            ("task_count", `Int (count_kind "task"));
            ("decision_count", `Int (count_kind "decision"));
            ("operation_count", `Int (count_kind "operation"));
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
  | "operation.started" -> Some "operation"
  | "keeper.autonomy_started" -> Some "autonomy"
  | _ -> None

(** Issue #8711: single SSOT for span-ending event kinds. The previous
    [span_end_kind] / [span_end_status] pair reproduced the same
    8-symbol alphabet in two places; if either gained a constructor
    without the other being updated the catch-all in [span_end_status]
    would silently map the new kind to [Span_ended], losing semantic
    information. Combining them forces both pieces to stay in sync at
    compile time (Parse, don't validate). *)
let span_end_classification = function
  | "task.done"                 -> Some ("task",      Span_completed)
  (* RFC-0323 G-3: approve-produced Done completes the task span too. *)
  | "task.approved"             -> Some ("task",      Span_completed)
  | "task.released"             -> Some ("task",      Span_released)
  | "task.cancelled"            -> Some ("task",      Span_cancelled)
  | "agent.left"                -> Some ("presence",  Span_left)
  | "agent.retired"             -> Some ("presence",  Span_retired)
  | "operation.finalized"       -> Some ("operation", Span_finalized)
  | "operation.stopped"         -> Some ("operation", Span_stopped)
  | "keeper.autonomy_completed" -> Some ("autonomy",  Span_completed)
  | _                           -> None

let span_end_kind kind =
  Option.map fst (span_end_classification kind)

let span_end_status kind =
  match span_end_classification kind with
  | Some (_, status) -> status
  | None -> Span_ended  (* unreachable in practice — call sites first
                           check [span_end_kind] / [span_end_classification] *)

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
