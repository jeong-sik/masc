type entity_ref = {
  kind : string;
  id : string;
}

type event = {
  seq : int;
  ts_ms : int;
  ts_iso : string;
  room_id : string;
  kind : string;
  actor : entity_ref option;
  subject : entity_ref option;
  payload : Yojson.Safe.t;
  tags : string list;
}

type graph_node = {
  id : string;
  kind : string;
  label : string;
  status : string;
  weight : int;
  semantic_weight : float;
  last_event_at : string;
  meta : Yojson.Safe.t;
}

type graph_edge = {
  id : string;
  source : string;
  target : string;
  kind : string;
  weight : int;
  active : bool;
  last_event_at : string;
  meta : Yojson.Safe.t;
}

let entity ~kind id = { kind; id }

let default_meta = `Assoc []

let entity_to_yojson (value : entity_ref) =
  `Assoc [ ("kind", `String value.kind); ("id", `String value.id) ]

let entity_of_yojson (json : Yojson.Safe.t) : entity_ref option =
  let open Yojson.Safe.Util in
  try
    Some
      {
        kind = json |> member "kind" |> to_string;
        id = json |> member "id" |> to_string;
      }
  with Type_error _ -> None

let event_to_yojson (value : event) =
  `Assoc
    [
      ("seq", `Int value.seq);
      ("ts_ms", `Int value.ts_ms);
      ("ts_iso", `String value.ts_iso);
      ("room_id", `String value.room_id);
      ("kind", `String value.kind);
      ( "actor",
        match value.actor with
        | Some actor -> entity_to_yojson actor
        | None -> `Null );
      ( "subject",
        match value.subject with
        | Some subject -> entity_to_yojson subject
        | None -> `Null );
      ("payload", value.payload);
      ("tags", `List (List.map (fun tag -> `String tag) value.tags));
    ]

let event_of_yojson (json : Yojson.Safe.t) : event option =
  let open Yojson.Safe.Util in
  try
    Some
      {
        seq = json |> member "seq" |> to_int;
        ts_ms = json |> member "ts_ms" |> to_int;
        ts_iso = json |> member "ts_iso" |> to_string;
        room_id = json |> member "room_id" |> to_string;
        kind = json |> member "kind" |> to_string;
        actor = entity_of_yojson (json |> member "actor");
        subject = entity_of_yojson (json |> member "subject");
        payload = json |> member "payload";
        tags =
          (match json |> member "tags" with
          | `List items ->
              List.filter_map
                (function `String value -> Some value | _ -> None)
                items
          | _ -> []);
      }
  with Type_error _ -> None

let graph_node_to_yojson (value : graph_node) =
  `Assoc
    [
      ("id", `String value.id);
      ("kind", `String value.kind);
      ("label", `String value.label);
      ("status", `String value.status);
      ("weight", `Int value.weight);
      ("semantic_weight", `Float value.semantic_weight);
      ("last_event_at", `String value.last_event_at);
      ("meta", value.meta);
    ]

let graph_edge_to_yojson (value : graph_edge) =
  `Assoc
    [
      ("id", `String value.id);
      ("source", `String value.source);
      ("target", `String value.target);
      ("kind", `String value.kind);
      ("weight", `Int value.weight);
      ("active", `Bool value.active);
      ("last_event_at", `String value.last_event_at);
      ("meta", value.meta);
    ]

let now_ts_ms () = int_of_float (Time_compat.now () *. 1000.0)

let root_dir (config : Room_utils.config) =
  Filename.concat (Room_utils.masc_dir config) "activity-events"

let month_dir (config : Room_utils.config) =
  let tm = Unix.gmtime (Time_compat.now ()) in
  Filename.concat (root_dir config)
    (Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1))

let day_path (config : Room_utils.config) =
  let tm = Unix.gmtime (Time_compat.now ()) in
  Filename.concat (month_dir config) (Printf.sprintf "%02d.jsonl" tm.tm_mday)

let seq_path (config : Room_utils.config) =
  Filename.concat (root_dir config) "_seq"

let lock_path (config : Room_utils.config) =
  Filename.concat (root_dir config) "_stream"

let ensure_dirs config =
  Room_utils.mkdir_p (root_dir config);
  Room_utils.mkdir_p (month_dir config)

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

type client = {
  client_id : int;
  push : string -> unit;
  room_filter : string option;
  kind_filters : string list;
  mutable last_seq : int;
  created_at : float;
}

let clients : (string, client) Hashtbl.t = Hashtbl.create 16
let registry_mutex = Eio.Mutex.create ()
let client_count_atomic = Atomic.make 0
let client_id_counter = Atomic.make 0

let with_registry_rw f =
  try Eio.Mutex.use_rw ~protect:true registry_mutex f
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Stdlib.Effect.Unhandled _ -> f ()

let with_registry_ro f =
  try Eio.Mutex.use_ro registry_mutex f
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Stdlib.Effect.Unhandled _ -> f ()

let client_matches (client : client) (value : event) =
  let room_ok =
    match client.room_filter with
    | None -> true
    | Some room_id -> String.equal room_id value.room_id
  in
  let kind_ok =
    match client.kind_filters with
    | [] -> true
    | filters -> List.mem value.kind filters
  in
  room_ok && kind_ok

let register session_id ~push ~last_seq ?room_filter ?(kind_filters = []) () =
  with_registry_rw (fun () ->
      let created_at = Time_compat.now () in
      let client_id = Atomic.fetch_and_add client_id_counter 1 + 1 in
      let client =
        {
          client_id;
          push;
          room_filter;
          kind_filters;
          last_seq;
          created_at;
        }
      in
      let existed = Hashtbl.mem clients session_id in
      Hashtbl.replace clients session_id client;
      if not existed then Atomic.incr client_count_atomic;
      client_id)

let unregister session_id =
  with_registry_rw (fun () ->
      if Hashtbl.mem clients session_id then begin
        Hashtbl.remove clients session_id;
        Atomic.decr client_count_atomic
      end)

let unregister_if_current session_id client_id =
  with_registry_rw (fun () ->
      match Hashtbl.find_opt clients session_id with
      | Some client when client.client_id = client_id ->
          Hashtbl.remove clients session_id;
          Atomic.decr client_count_atomic
      | _ -> ())

let client_count () = Atomic.get client_count_atomic

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

let matches_filters ?room_id ?(kinds = []) (value : event) =
  let room_ok =
    match room_id with
    | None -> true
    | Some room -> String.equal room value.room_id
  in
  let kind_ok = kinds = [] || List.mem value.kind kinds in
  room_ok && kind_ok

let list_events config ?room_id ?(kinds = []) ~after_seq ~limit () =
  let all =
    read_all_events config
    |> List.filter (fun value ->
           value.seq > after_seq && matches_filters ?room_id ~kinds value)
  in
  if after_seq > 0 then
    List.take limit all
  else
    let total = List.length all in
    all |> List.drop (max 0 (total - limit))

let latest_seq config = read_current_seq config

let emit config ~room_id ?actor ?subject ?(tags = []) ~kind ~payload () =
  let value =
    Room_utils.with_file_lock config (lock_path config) (fun () ->
        ensure_dirs config;
        let seq = read_current_seq config + 1 in
        write_current_seq config seq;
        let value =
          {
            seq;
            ts_ms = now_ts_ms ();
            ts_iso = Types.now_iso ();
            room_id;
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

let json_response config ?room_id ?(kinds = []) ~after_seq ~limit () =
  let events = list_events config ?room_id ~kinds ~after_seq ~limit () in
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
      ("room_id", match room_id with Some value -> `String value | None -> `Null);
      ("kinds", `List (List.map (fun value -> `String value) kinds));
      ("latest_seq", `Int (latest_seq config));
    ]

type node_acc = {
  node_id : string;
  node_kind : string;
  mutable label : string;
  mutable status : string;
  mutable weight : int;
  mutable semantic_weight : float;
  mutable last_event_at : string;
  mutable meta : Yojson.Safe.t;
}

type edge_acc = {
  edge_id : string;
  source : string;
  target : string;
  edge_kind : string;
  mutable weight : int;
  mutable active : bool;
  mutable last_event_at : string;
  mutable meta : Yojson.Safe.t;
}

let entity_node_id (value : entity_ref) = value.kind ^ ":" ^ value.id

let payload_string field json =
  match Yojson.Safe.Util.member field json with
  | `String value when String.trim value <> "" -> Some value
  | _ -> None

let is_generic_status = function
  | "" | "active" | "observed" -> true
  | _ -> false

(* Semantic weight multiplier by event kind.
   Completion events score high; routine lifecycle events score low. *)
let semantic_multiplier = function
  | "task.done" | "decision.resolved" | "operation.finalized" -> 5.0
  | "task.created" | "task.claimed" | "decision.opened" -> 3.0
  | "agent.handoff" | "agent.spawned" -> 3.0
  | "board.posted" | "board.voted" -> 2.0
  | "task.started" | "task.released" | "task.cancelled" -> 1.5
  | "message.broadcast" | "message.mentioned" -> 1.0
  | "team.turn" | "team.turn_failed" -> 1.0
  | "board.commented" | "decision.voted" -> 1.0
  | "operation.started" | "operation.resumed" -> 1.0
  | "policy.approved" | "policy.denied" -> 2.0
  | "agent.joined" | "agent.left" -> 0.5
  | "agent.retired" | "agent.compacted" -> 0.5
  | "keeper.compaction" | "keeper.guardrail" -> 0.5
  | "keeper.autonomy_started" | "keeper.autonomy_completed" -> 1.5
  | "operation.paused" | "operation.stopped" -> 0.5
  | _ -> 1.0

let ensure_node (nodes : (string, node_acc) Hashtbl.t) ~(id : string)
    ~(kind : string) ~(label : string)
    ~(status : string) ~(ts_iso : string) ~(meta : Yojson.Safe.t)
    ~(sw_delta : float) =
  match Hashtbl.find_opt nodes id with
  | Some node ->
      node.weight <- node.weight + 1;
      node.semantic_weight <- node.semantic_weight +. sw_delta;
      node.last_event_at <- ts_iso;
      if node.label = id || node.label = "" then node.label <- label;
      if status <> ""
         && (not (is_generic_status status) || is_generic_status node.status)
      then
        node.status <- status;
      if meta <> default_meta then node.meta <- meta
  | None ->
      Hashtbl.add nodes id
        {
          node_id = id;
          node_kind = kind;
          label;
          status;
          weight = 1;
          semantic_weight = sw_delta;
          last_event_at = ts_iso;
          meta;
        }

let ensure_entity_node (nodes : (string, node_acc) Hashtbl.t) value
    ~fallback_status ~ts_iso ~meta ~sw_delta =
  let node_id = entity_node_id value in
  let label =
    match payload_string "label" meta with
    | Some label -> label
    | None -> value.id
  in
  ensure_node nodes ~id:node_id ~kind:value.kind ~label ~status:fallback_status
    ~ts_iso ~meta ~sw_delta;
  node_id

let ensure_edge (edges : (string, edge_acc) Hashtbl.t) ~source ~target ~kind
    ~active ~ts_iso ~meta =
  let edge_id = source ^ "|" ^ kind ^ "|" ^ target in
  match Hashtbl.find_opt edges edge_id with
  | Some edge ->
      edge.weight <- edge.weight + 1;
      edge.active <- active;
      edge.last_event_at <- ts_iso;
      if meta <> default_meta then edge.meta <- meta
  | None ->
      Hashtbl.add edges edge_id
        {
          edge_id;
          source;
          target;
          edge_kind = kind;
          weight = 1;
          active;
          last_event_at = ts_iso;
          meta;
        }

let reduce_event ~nodes ~edges (value : event) =
  let sw = semantic_multiplier value.kind in
  let room_node_id = "room:" ^ value.room_id in
  ensure_node nodes ~id:room_node_id ~kind:"room" ~label:value.room_id
    ~status:"room" ~ts_iso:value.ts_iso ~meta:default_meta ~sw_delta:sw;
  let actor_id =
    match value.actor with
    | Some actor ->
        let id =
          ensure_entity_node nodes actor ~fallback_status:"active"
            ~ts_iso:value.ts_iso ~meta:value.payload ~sw_delta:sw
        in
        ensure_edge edges ~source:id ~target:room_node_id ~kind:"belongs_to"
          ~active:true ~ts_iso:value.ts_iso ~meta:default_meta;
        Some id
    | None -> None
  in
  let subject_id =
    match value.subject with
    | Some subject ->
        let id =
          ensure_entity_node nodes subject ~fallback_status:"observed"
            ~ts_iso:value.ts_iso ~meta:value.payload ~sw_delta:sw
        in
        ensure_edge edges ~source:id ~target:room_node_id ~kind:"belongs_to"
          ~active:true ~ts_iso:value.ts_iso ~meta:default_meta;
        Some id
    | None -> None
  in
  let set_subject_status status =
    match subject_id with
    | Some id -> (
        match Hashtbl.find_opt nodes id with
        | Some node -> node.status <- status
        | None -> ())
    | None -> ()
  in
  let set_actor_status status =
    match actor_id with
    | Some id -> (
        match Hashtbl.find_opt nodes id with
        | Some node -> node.status <- status
        | None -> ())
    | None -> ()
  in
  (match value.kind with
  | "agent.joined" ->
      set_subject_status "active"
  | "agent.left" ->
      set_subject_status "offline"
  | "agent.spawned" ->
      set_subject_status "spawned"
  | "agent.retired" ->
      set_subject_status "retired"
  | "agent.compacted" ->
      set_subject_status "compacting"
  | "agent.handoff" ->
      set_actor_status "handoff";
      set_subject_status "active";
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"hands_off_to" ~active:true
            ~ts_iso:value.ts_iso ~meta:value.payload
      | _ -> ())
  | "task.created" ->
      set_subject_status "todo";
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"creates" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | _ -> ())
  | "task.claimed" ->
      set_subject_status "claimed";
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"works_on" ~active:true
            ~ts_iso:value.ts_iso ~meta:value.payload
      | _ -> ())
  | "task.started" ->
      set_subject_status "in_progress";
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"works_on" ~active:true
            ~ts_iso:value.ts_iso ~meta:value.payload
      | _ -> ())
  | "task.released" ->
      set_subject_status "todo";
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"works_on" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | _ -> ())
  | "task.done" ->
      set_subject_status "done";
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"works_on" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | _ -> ())
  | "task.cancelled" ->
      set_subject_status "cancelled";
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"works_on" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | _ -> ())
  | "message.broadcast" ->
      (match actor_id with
      | Some source ->
          ensure_edge edges ~source ~target:room_node_id ~kind:"broadcasts"
            ~active:false ~ts_iso:value.ts_iso ~meta:value.payload
      | None -> ())
  | "message.mentioned" ->
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"mentions" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | _ -> ())
  | "board.posted" ->
      set_subject_status "posted";
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"posts" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | _ -> ())
  | "board.commented" ->
      set_subject_status "discussed";
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"comments_on" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | _ -> ())
  | "board.voted" ->
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"votes_on" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | _ -> ())
  | "decision.opened" ->
      set_subject_status "open";
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"opens" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | _ -> ())
  | "decision.voted" ->
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"votes_on" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | _ -> ())
  | "decision.resolved" ->
      set_subject_status "resolved"
  | "policy.approved" ->
      set_subject_status "approved";
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"governs" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | _ -> ())
  | "policy.denied" ->
      set_subject_status "denied";
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"governs" ~active:false
            ~ts_iso:value.ts_iso ~meta:value.payload
      | _ -> ())
  | "operation.started" ->
      set_subject_status "running";
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"operates_on" ~active:true
            ~ts_iso:value.ts_iso ~meta:value.payload
      | _ -> ())
  | "operation.paused" ->
      set_subject_status "paused"
  | "operation.resumed" ->
      set_subject_status "running"
  | "operation.stopped" ->
      set_subject_status "stopped"
  | "operation.finalized" ->
      set_subject_status "finalized"
  | "team.turn" ->
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"participates_in"
            ~active:true ~ts_iso:value.ts_iso ~meta:value.payload
      | _ -> ())
  | "team.turn_failed" ->
      (match (actor_id, subject_id) with
      | Some source, Some target ->
          ensure_edge edges ~source ~target ~kind:"participates_in"
            ~active:false ~ts_iso:value.ts_iso ~meta:value.payload
      | _ -> ())
  | "keeper.autonomy_started" ->
      set_actor_status "autonomy"
  | "keeper.autonomy_completed" ->
      set_actor_status "active"
  | "keeper.guardrail" ->
      set_actor_status "guardrail"
  | "keeper.compaction" ->
      set_actor_status "compacting"
  | _ -> ())

let graph_json config ?room_id ?(kinds = []) ?(limit = 500)
    ?(timeline_limit = 80) ?since_ms () =
  let events = list_events config ?room_id ~kinds ~after_seq:0 ~limit () in
  let events = match since_ms with
    | Some ms -> List.filter (fun e -> e.ts_ms >= ms) events
    | None -> events
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
            ( "room_id",
              match room_id with
              | Some value -> `String value
              | None -> `Null );
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
      ("nodes", `List nodes_json);
      ("edges", `List edges_json);
      ("timeline", `List (List.map event_to_yojson timeline));
    ]

type agent_span = {
  agent : string;
  start_ms : int;
  end_ms : int;
  span_kind : string;
  label : string;
  span_status : string;
}

let agent_span_to_yojson (s : agent_span) =
  `Assoc [
    ("agent", `String s.agent);
    ("start_ms", `Int s.start_ms);
    ("end_ms", `Int s.end_ms);
    ("kind", `String s.span_kind);
    ("label", `String s.label);
    ("status", `String s.span_status);
  ]

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
  | "task.done" -> "completed"
  | "task.released" -> "released"
  | "task.cancelled" -> "cancelled"
  | "agent.left" -> "left"
  | "agent.retired" -> "retired"
  | "operation.finalized" -> "finalized"
  | "operation.stopped" -> "stopped"
  | "keeper.autonomy_completed" -> "completed"
  | _ -> "ended"

let agent_spans_json config ?room_id ?(limit = 500) () =
  let events = list_events config ?room_id ~kinds:[] ~after_seq:0 ~limit () in
  let now_ms = now_ts_ms () in
  (* open_spans keyed by (agent_id, subject_id option) *)
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
  (* Close unpaired start events with now_ms *)
  Hashtbl.iter (fun (aid, _subj) (start_ms, sk, label) ->
    closed_spans := {
      agent = aid;
      start_ms;
      end_ms = now_ms;
      span_kind = sk;
      label;
      span_status = "open";
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
