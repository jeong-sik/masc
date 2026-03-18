(** Chain run store - in-memory history for visualization

    Stores recent chain executions with node-level details for UI.
    Intended for lightweight debugging (no long-term persistence).
*)

open Chain_types

let max_history () = Safe_parse.env_int ~var:"MASC_CHAIN_RUN_HISTORY" ~default:50
let max_output_chars () = Safe_parse.env_int ~var:"MASC_CHAIN_OUTPUT_MAX_CHARS" ~default:4000
let max_preview_chars () = Safe_parse.env_int ~var:"MASC_CHAIN_OUTPUT_PREVIEW_CHARS" ~default:240

let default_store_path () =
  let home =
    match Sys.getenv_opt "HOME" with
    | Some path when String.trim path <> "" -> path
    | _ -> "/tmp"
  in
  Filename.concat home "logs/masc_chain_run_store.jsonl"

let store_path () =
  match Sys.getenv_opt "MASC_CHAIN_RUN_STORE_PATH" with
  | Some path when String.trim path <> "" -> path
  | _ -> default_store_path ()

let ensure_dir path =
  Fs_compat.mkdir_p path

let read_lines_tail ~max_bytes:_ ~max_lines path =
  let content = Fs_compat.load_file path in
  let all_lines = String.split_on_char '\n' content
    |> List.filter (fun line -> String.length (String.trim line) > 0) in
  let rec take n xs =
    if n <= 0 then []
    else
      match xs with
      | [] -> []
      | hd :: tl -> hd :: take (n - 1) tl
  in
  take max_lines all_lines

let truncate s max_chars =
  let len = String.length s in
  if len <= max_chars then (s, false)
  else (String.sub s 0 max_chars ^ "...", true)

let preview s =
  let max_chars = max_preview_chars () in
  let text, _ = truncate s max_chars in
  text

let is_internal_key k =
  let starts_with ~prefix s =
    let p = String.length prefix in
    String.length s >= p && String.sub s 0 p = prefix
  in
  starts_with ~prefix:"__" k || starts_with ~prefix:"parent." k

let rec collect_nodes acc (node : node) =
  let acc = node :: acc in
  match node.node_type with
  | Pipeline nodes
  | Fanout nodes
  | Race { nodes; _ }
  | Merge { nodes; _ }
  | Quorum { nodes; _ }
  | StreamMerge { nodes; _ } ->
      List.fold_left collect_nodes acc nodes
  | Gate { then_node; else_node; _ } ->
      let acc = collect_nodes acc then_node in
      (match else_node with Some n -> collect_nodes acc n | None -> acc)
  | Subgraph c ->
      List.fold_left collect_nodes acc c.nodes
  | Map { inner; _ }
  | Bind { inner; _ }
  | Cache { inner; _ }
  | Batch { inner; _ }
  | Spawn { inner; _ } ->
      collect_nodes acc inner
  | Retry { node = inner; _ } ->
      collect_nodes acc inner
  | Fallback { primary; fallbacks; _ } ->
      let acc = collect_nodes acc primary in
      List.fold_left collect_nodes acc fallbacks
  | Threshold { input_node; on_pass; on_fail; _ } ->
      let acc = collect_nodes acc input_node in
      let acc = match on_pass with Some n -> collect_nodes acc n | None -> acc in
      let acc = match on_fail with Some n -> collect_nodes acc n | None -> acc in
      acc
  | GoalDriven { action_node; _ } ->
      collect_nodes acc action_node
  | Evaluator { candidates; _ } ->
      List.fold_left collect_nodes acc candidates
  | Mcts { strategies; simulation; _ } ->
      let acc = List.fold_left collect_nodes acc strategies in
      collect_nodes acc simulation
  | FeedbackLoop { generator; _ } ->
      collect_nodes acc generator
  | Cascade { tiers; _ } ->
      List.fold_left (fun acc t -> collect_nodes acc t.Chain_types.tier_node) acc tiers
  | Llm _ | Tool _ | ChainRef _ | ChainExec _ | Adapter _
  | Masc_broadcast _ | Masc_listen _ | Masc_claim _ ->
      acc

let collect_all_nodes (chain : chain) : node list =
  List.fold_left collect_nodes [] chain.nodes |> List.rev

let node_type_map (chain : chain) : (string, string) Hashtbl.t =
  let tbl = Hashtbl.create 32 in
  collect_all_nodes chain
  |> List.iter (fun (n : Chain_types.node) ->
      Hashtbl.replace tbl n.id (node_type_name n.node_type));
  tbl

let enrich_trace_entries ~(chain : chain) ~(outputs : (string, string) Hashtbl.t)
    (entries : trace_entry list) : trace_entry list =
  let types = node_type_map chain in
  let chain_id = chain.id in
  List.map (fun (e : trace_entry) ->
    let node_type_name =
      match Hashtbl.find_opt types e.node_id with
      | Some t -> t
      | None when String.equal e.node_id chain_id -> "chain"
      | None -> e.node_type_name
    in
    let output_preview =
      match Hashtbl.find_opt outputs e.node_id with
      | Some v -> Some (preview v)
      | None -> e.output_preview
    in
    { e with node_type_name; output_preview }
  ) entries

type output_entry = {
  id : string;
  text : string;
  size : int;
  truncated : bool;
}

type node_view = {
  id : string;
  node_type : string;
  status : string;
  start_time : float option;
  end_time : float option;
  duration_ms : int option;
  input_mapping : (string * string) list;
  depends_on : string list;
  output_preview : string option;
  output_size : int option;
  output_truncated : string option;
  error : string option;
}

type run_record = {
  run_id : string;
  chain_id : string;
  started_at : float;
  duration_ms : int;
  success : bool;
  mermaid : string;
  execution_order : string list;
  parallel_groups : string list list;
  nodes : node_view list;
  trace : trace_entry list;
  outputs : output_entry list;
  chain_json : Yojson.Safe.t;
}

let build_outputs ~(outputs : (string, string) Hashtbl.t) : output_entry list =
  let max_chars = max_output_chars () in
  Hashtbl.fold (fun k v acc ->
    if is_internal_key k then acc
    else
      let text, truncated = truncate v max_chars in
      let entry = { id = k; text; size = String.length v; truncated } in
      entry :: acc
  ) outputs []
  |> List.rev

let build_nodes ~(chain : chain) ~(outputs : (string, string) Hashtbl.t)
    ~(trace : trace_entry list) : node_view list =
  let trace_map : (string, trace_entry) Hashtbl.t = Hashtbl.create 32 in
  List.iter (fun (t : trace_entry) -> Hashtbl.replace trace_map t.node_id t) trace;

  let nodes = collect_all_nodes chain in
  List.map (fun (n : node) ->
    let trace_opt = Hashtbl.find_opt trace_map n.id in
    let status =
      match trace_opt with
      | Some (t : trace_entry) ->
          (match t.status with `Success -> "success" | `Failure -> "failure" | `Skipped -> "skipped")
      | None -> "unknown"
    in
    let start_time = Option.map (fun (t : trace_entry) -> t.start_time) trace_opt in
    let end_time = Option.map (fun (t : trace_entry) -> t.end_time) trace_opt in
    let duration_ms =
      match trace_opt with
      | Some (t : trace_entry) -> Some (int_of_float ((t.end_time -. t.start_time) *. 1000.0))
      | None -> None
    in
    let output = Hashtbl.find_opt outputs n.id in
    let output_size = Option.map String.length output in
    let output_truncated =
      match output with
      | Some v ->
          let text, _ = truncate v (max_output_chars ()) in
          Some text
      | None -> None
    in
    {
      id = n.id;
      node_type = node_type_name n.node_type;
      status;
      start_time;
      end_time;
      duration_ms;
      input_mapping = n.input_mapping;
      depends_on = List.map snd n.input_mapping;
      output_preview = Option.map preview output;
      output_size;
      output_truncated;
      error = Option.bind trace_opt (fun (t : trace_entry) -> t.error);
    }
  ) nodes

let store : run_record list ref = ref []
let mutex = Eio.Mutex.create ()

let append_persistent_json json =
  let path = store_path () in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.append_jsonl path json

let list_runs () : run_record list =
  Eio.Mutex.use_rw ~protect:true mutex (fun () -> !store)

let get_run ~(run_id : string) : run_record option =
  Eio.Mutex.use_rw ~protect:true mutex (fun () ->
    List.find_opt (fun r -> String.equal r.run_id run_id) !store
  )

let output_entry_to_json (o : output_entry) : Yojson.Safe.t =
  `Assoc [
    ("id", `String o.id);
    ("text", `String o.text);
    ("size", `Int o.size);
    ("truncated", `Bool o.truncated);
  ]

let node_view_to_json (n : node_view) : Yojson.Safe.t =
  let opt_float = function Some v -> `Float v | None -> `Null in
  let opt_int = function Some v -> `Int v | None -> `Null in
  let opt_str = function Some v -> `String v | None -> `Null in
  `Assoc [
    ("id", `String n.id);
    ("type", `String n.node_type);
    ("status", `String n.status);
    ("start_time", opt_float n.start_time);
    ("end_time", opt_float n.end_time);
    ("duration_ms", opt_int n.duration_ms);
    ("input_mapping", `List (List.map (fun (k, v) -> `List [`String k; `String v]) n.input_mapping));
    ("depends_on", `List (List.map (fun d -> `String d) n.depends_on));
    ("output_preview", opt_str n.output_preview);
    ("output_size", opt_int n.output_size);
    ("output_truncated", opt_str n.output_truncated);
    ("error", opt_str n.error);
  ]

let run_summary_to_json (r : run_record) : Yojson.Safe.t =
  `Assoc [
    ("run_id", `String r.run_id);
    ("chain_id", `String r.chain_id);
    ("started_at", `Float r.started_at);
    ("duration_ms", `Int r.duration_ms);
    ("success", `Bool r.success);
    ("node_count", `Int (List.length r.nodes));
  ]

let run_record_to_json (r : run_record) : Yojson.Safe.t =
  `Assoc [
    ("run_id", `String r.run_id);
    ("chain_id", `String r.chain_id);
    ("started_at", `Float r.started_at);
    ("duration_ms", `Int r.duration_ms);
    ("success", `Bool r.success);
    ("mermaid", `String r.mermaid);
    ("execution_order", `List (List.map (fun id -> `String id) r.execution_order));
    ("parallel_groups", `List (List.map (fun group -> `List (List.map (fun id -> `String id) group)) r.parallel_groups));
    ("nodes", `List (List.map node_view_to_json r.nodes));
    ("trace", `List (List.map trace_entry_to_yojson r.trace));
    ("outputs", `List (List.map output_entry_to_json r.outputs));
    ("chain", r.chain_json);
  ]

let persist_run_record (r : run_record) =
  try append_persistent_json (run_record_to_json r)
  with exn ->
    Log.Chain.error "persist failed: %s"
      (Printexc.to_string exn)

let record ~(run_id : string) ~(chain : chain) ~(plan : execution_plan)
    ~(trace : trace_entry list) ~(outputs : (string, string) Hashtbl.t)
    ~(success : bool) ~(duration_ms : int) ~(started_at : float) : unit =
  let max_keep = max_history () in
  if max_keep <= 0 then
    ()
  else begin
    let mermaid = Chain_mermaid_parser.chain_to_mermaid chain in
    let trace = enrich_trace_entries ~chain ~outputs trace in
    let nodes = build_nodes ~chain ~outputs ~trace in
    let outputs_entries = build_outputs ~outputs in
    let record = {
      run_id;
      chain_id = chain.id;
      started_at;
      duration_ms;
      success;
      mermaid;
      execution_order = plan.execution_order;
      parallel_groups = plan.parallel_groups;
      nodes;
      trace;
      outputs = outputs_entries;
      chain_json = chain_to_yojson chain;
    } in
    Eio.Mutex.use_rw ~protect:true mutex (fun () ->
      store := record :: !store;
      let rec take n xs =
        if n <= 0 then []
        else match xs with [] -> [] | h :: t -> h :: take (n - 1) t
      in
      store := take max_keep !store
    );
    persist_run_record record
  end

let read_persisted_run_json ~(run_id : string) : Yojson.Safe.t option =
  let path = store_path () in
  if not (Sys.file_exists path) then
    None
  else
    let max_bytes =
      Safe_parse.env_int ~var:"MASC_CHAIN_RUN_STORE_MAX_BYTES"
        ~default:(10 * 1024 * 1024)
    in
    let max_lines =
      Safe_parse.env_int ~var:"MASC_CHAIN_RUN_STORE_MAX_LINES" ~default:2000
    in
    read_lines_tail ~max_bytes ~max_lines path
    |> List.rev
    |> List.find_map (fun line ->
           let line = String.trim line in
           if line = "" then
             None
           else
             try
               let json = Yojson.Safe.from_string line in
               match Yojson.Safe.Util.member "run_id" json with
               | `String value when String.equal value run_id -> Some json
               | _ -> None
             with exn ->
               Log.Chain.warn "chain_run_store: run entry parse failed: %s" (Printexc.to_string exn);
               None)

let list_runs_json () : Yojson.Safe.t =
  let runs = list_runs () in
  `Assoc [
    ("count", `Int (List.length runs));
    ("runs", `List (List.map run_summary_to_json runs));
  ]

let get_run_json ~(run_id : string) : Yojson.Safe.t option =
  match get_run ~run_id with
  | Some run -> Some (run_record_to_json run)
  | None -> read_persisted_run_json ~run_id
