(** Activity_graph — event storage, graph building, and agent spans. *)

(* Re-export sub-modules *)
include Activity_graph_types
include Activity_graph_registry
include Activity_graph_reducer

(* ================================================================ *)
(* File storage paths                                               *)
(* ================================================================ *)

let root_dir (config : Coord_utils.config) =
  Filename.concat (Coord_utils.masc_dir config) "activity-events"

let month_dir (config : Coord_utils.config) =
  let tm = Unix.gmtime (Time_compat.now ()) in
  Filename.concat (root_dir config)
    (Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1))

let day_path (config : Coord_utils.config) =
  let tm = Unix.gmtime (Time_compat.now ()) in
  Filename.concat (month_dir config) (Printf.sprintf "%02d.jsonl" tm.tm_mday)

let seq_path (config : Coord_utils.config) =
  Filename.concat (root_dir config) "_seq"

let lock_path (config : Coord_utils.config) =
  Filename.concat (root_dir config) "_stream"

let ensure_dirs config =
  Coord_utils.mkdir_p (root_dir config);
  Coord_utils.mkdir_p (month_dir config)

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

let format_sse_event (value : event) =
  let data = Yojson.Safe.to_string (event_to_yojson value) in
  Printf.sprintf "id: %d\nevent: activity\ndata: %s\n\n" value.seq data

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

let read_all_events config =
  collect_event_files config
  |> List.fold_left
       (fun acc path ->
         let content = Fs_compat.load_file path in
         let lines = String.split_on_char '\n' content in
         let rows =
           List.filter_map (fun line ->
             if String.trim line = "" then None
             else parse_event_line line) lines
         in
         List.rev_append rows acc)
       []
  |> List.sort (fun a b -> Int.compare a.seq b.seq)

let matches_filters ?(kinds = []) (value : event) =
  kinds = [] || List.mem value.kind kinds

let list_events config ?(kinds = []) ~after_seq ~limit () =
  let all =
    read_all_events config
    |> List.filter (fun value ->
           value.seq > after_seq && matches_filters ~kinds value)
  in
  if after_seq > 0 then
    List.take limit all
  else
    let total = List.length all in
    all |> List.drop (max 0 (total - limit))

let latest_seq config = read_current_seq config

(* ================================================================ *)
(* Event emission                                                   *)
(* ================================================================ *)

let emit config ?actor ?subject ?(tags = []) ~kind ~payload () =
  let value =
    Coord_utils.with_file_lock config (lock_path config) (fun () ->
        ensure_dirs config;
        let seq = read_current_seq config + 1 in
        write_current_seq config seq;
        let value =
          {
            seq;
            ts_ms = now_ts_ms ();
            ts_iso = Types.now_iso ();
            room_id = "default";  (* retained for JSONL backward compat *)
            kind;
            actor;
            subject;
            payload;
            tags;
          }
        in
        append_line (day_path config)
          (Yojson.Safe.to_string (event_to_yojson value) ^ "\n");
        value)
  in
  let encoded = format_sse_event value in
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
  let events = list_events config ~kinds ~after_seq ~limit () in
  let next_after_seq =
    match List.rev events with
    | last :: _ -> last.seq
    | [] -> after_seq
  in
  `Assoc
    [
      ("events", `List (List.map event_to_yojson events));
      ("count", `Int (List.length events));
      ("after_seq", `Int after_seq);
      ("next_after_seq", `Int next_after_seq);
      ("limit", `Int limit);
      ("room_id", `String "default");  (* backward compat *)
      ("kinds", `List (List.map (fun value -> `String value) kinds));
      ("latest_seq", `Int (latest_seq config));
    ]

(* ================================================================ *)
(* Graph building                                                   *)
(* ================================================================ *)

let graph_json config ?(kinds = []) ?(limit = 500)
    ?(timeline_limit = 80) ?since_ms () =
  let events = list_events config ~kinds ~after_seq:0 ~limit () in
  let events = match since_ms with
    | Some ms -> List.filter (fun e -> e.ts_ms >= ms) events
    | None -> events
  in
  let kind_counts_json =
    let counts = Hashtbl.create 16 in
    List.iter
      (fun (e : event) ->
        let prev = Option.value (Hashtbl.find_opt counts e.kind) ~default:0 in
        Hashtbl.replace counts e.kind (prev + 1))
      events;
    `Assoc
      (Hashtbl.fold
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
           let open Yojson.Safe.Util in
           compare (a |> member "id" |> to_string) (b |> member "id" |> to_string))
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
           let open Yojson.Safe.Util in
           compare (a |> member "id" |> to_string) (b |> member "id" |> to_string))
  in
  let timeline =
    let total = List.length events in
    events |> List.drop (max 0 (total - timeline_limit))
  in
  let count_kind prefix =
    nodes_json
    |> List.fold_left
         (fun acc node ->
           match Yojson.Safe.Util.member "kind" node with
           | `String kind when String.equal kind prefix -> acc + 1
           | _ -> acc)
         0
  in
  let active_agents =
    nodes_json
    |> List.fold_left
         (fun acc node ->
           let open Yojson.Safe.Util in
           match (member "kind" node, member "status" node) with
           | `String "agent", `String status
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
          let new_tasks_done = tasks_done + (if e.kind = "task.done" then 1 else 0) in
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
      ("generated_at", `String (Types.now_iso ()));
      ( "window",
        `Assoc
          [
            ("limit", `Int limit);
            ("room_id", `String "default");  (* backward compat *)
            ("kinds", `List (List.map (fun value -> `String value) kinds));
          ] );
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
  | "agent.joined" -> Some "presence"
  | "operation.started" -> Some "operation"
  | "keeper.autonomy_started" -> Some "autonomy"
  | _ -> None

let span_end_kind = function
  | "task.done" | "task.released" | "task.cancelled" -> Some "task"
  | "agent.left" | "agent.retired" -> Some "presence"
  | "operation.finalized" | "operation.stopped" -> Some "operation"
  | "keeper.autonomy_completed" -> Some "autonomy"
  | _ -> None

let span_end_status = function
  | "task.done" -> Span_completed
  | "task.released" -> Span_released
  | "task.cancelled" -> Span_cancelled
  | "agent.left" -> Span_left
  | "agent.retired" -> Span_retired
  | "operation.finalized" -> Span_finalized
  | "operation.stopped" -> Span_stopped
  | "keeper.autonomy_completed" -> Span_completed
  | _ -> Span_ended

let agent_spans_json config ?(limit = 500) ?since_ms () =
  let events = list_events config ~kinds:[] ~after_seq:0 ~limit () in
  let events = match since_ms with
    | Some ms -> List.filter (fun e -> e.ts_ms >= ms) events
    | None -> events
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
        (match span_end_kind e.kind with
         | Some ek ->
             let key = (aid, subject_id) in
             (match Hashtbl.find_opt open_spans key with
              | Some (start_ms, sk, label) when String.equal sk ek ->
                  Hashtbl.remove open_spans key;
                  closed_spans := {
                    agent = aid;
                    start_ms;
                    end_ms = e.ts_ms;
                    span_kind = sk;
                    label;
                    span_status = span_end_status e.kind;
                  } :: !closed_spans
              | _ -> ())
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
  ]
