(** Telemetry_unified — Read-only aggregation of scattered telemetry stores.

    Reads from multiple independent {!Dated_jsonl} stores, tags each record
    with a ["source"] discriminator, and returns a merged time-sorted view.

    No existing write paths are modified.  The module creates read-only
    {!Dated_jsonl} handles (no appends, no directory creation).

    Sources (paths are relative to the cluster-aware [masc_root]):
    - [<masc_root>/keepers/<name>/metrics/]  — Per-keeper turn metrics
    - [<masc_root>/telemetry/]               — Agent lifecycle + tool call events
    - [<masc_root>/tool_calls/]              — Full I/O for keeper tool calls
    - [<masc_root>/tool_usage/]              — System_internal surface tool calls
    - [<masc_root>/oas-events/]              — Durable OAS native/custom events
    - [<base_path>/data/tool-metrics/]       — Tool duration/success metrics
    @since 2.251.0 *)

type source =
  | Keeper_metric  (** Per-keeper turn/heartbeat metrics *)
  | Agent_event    (** Agent lifecycle, task, handoff events *)
  | Tool_call_io   (** Keeper tool calls with full input/output *)
  | Tool_usage     (** System_internal surface tool invocations *)
  | Oas_event      (** Durable OAS native/custom event bus relays *)
  | Tool_metric    (** Tool duration and success metrics *)

let source_to_string = function
  | Keeper_metric -> "keeper_metric"
  | Agent_event -> "agent_event"
  | Tool_call_io -> "tool_call_io"
  | Tool_usage -> "tool_usage"
  | Oas_event -> "oas_event"
  | Tool_metric -> "tool_metric"

let source_of_string = function
  | "keeper_metric" -> Some Keeper_metric
  | "agent_event" -> Some Agent_event
  | "tool_call_io" -> Some Tool_call_io
  | "tool_usage" -> Some Tool_usage
  | "oas_event" -> Some Oas_event
  | "tool_metric" -> Some Tool_metric
  | _ -> None

let all_sources =
  [ Keeper_metric
  ; Agent_event
  ; Tool_call_io
  ; Tool_usage
  ; Oas_event
  ; Tool_metric
  ]

type read_result = {
  entries : Yojson.Safe.t list;
  total_matching_entries : int;
  truncated : bool;
}

(* ── Store paths ────────────────────────────────────── *)

(** Fixed-path sources (single directory per source).

    [masc_root] is the cluster-aware .masc directory
    (e.g. [base_path/.masc] or [base_path/.masc/clusters/<name>]).
    [base_path] is the project root, used only for [data/] paths. *)
let fixed_store_dir ~masc_root ~base_path = function
  | Agent_event  -> Some (Filename.concat masc_root "telemetry")
  | Tool_call_io -> Some (Filename.concat masc_root "tool_calls")
  | Tool_usage   -> Some (Filename.concat masc_root "tool_usage")
  | Oas_event    -> Some (Filename.concat masc_root "oas-events")
  | Tool_metric  -> Some (Filename.concat base_path "data/tool-metrics")
  | Keeper_metric -> None  (* handled separately *)

(** Discover all keeper metric directories under [masc_root/keepers/]. *)
let discover_keeper_metric_dirs masc_root : (string * string) list =
  let keepers_dir = Filename.concat masc_root "keepers" in
  if not (Sys.file_exists keepers_dir) then []
  else
    let entries =
      try Array.to_list (Sys.readdir keepers_dir)
      with Eio.Cancel.Cancelled _ as e -> raise e | _ -> []
    in
    List.filter_map (fun name ->
      let metrics_dir = Filename.concat keepers_dir (name ^ "/metrics") in
      if Sys.file_exists metrics_dir then Some (name, metrics_dir)
      else None
    ) entries

(* ── Timestamp extraction ───────────────────────────── *)

let extract_ts (json : Yojson.Safe.t) : float =
  match json with
  | `Assoc fields ->
    (* Try ts_unix first (keeper metrics), then ts, then timestamp *)
    let try_field name =
      match List.assoc_opt name fields with
      | Some (`Float f) -> Some f
      | Some (`Int i) -> Some (Float.of_int i)
      | _ -> None
    in
    (match try_field "ts_unix" with
     | Some f -> f
     | None ->
       match try_field "ts" with
       | Some f -> f
       | None ->
         match try_field "timestamp" with
         | Some f -> f
         | None ->
           (match List.assoc_opt "ts_iso" fields with
            | Some (`String iso) ->
                Option.value ~default:0.0 (Types.parse_iso8601_opt iso)
            | _ -> 0.0))
  | _ -> 0.0

let day_string_of_unix_seconds ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02d"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday

let effective_day_window ?since_ts ?until_ts () =
  match since_ts, until_ts with
  | None, None -> None
  | _ ->
    let lower = Option.value ~default:0.0 since_ts in
    let upper =
      match until_ts with
      | Some ts -> ts
      | None -> max lower (Unix.gettimeofday ())
    in
    Some (day_string_of_unix_seconds lower, day_string_of_unix_seconds upper)

let within_requested_window ?since_ts ?until_ts (json : Yojson.Safe.t) : bool =
  match since_ts, until_ts with
  | None, None -> true
  | _ ->
    let ts = extract_ts json in
    let after_lower =
      match since_ts with
      | None -> true
      | Some lower -> ts >= lower
    in
    let before_upper =
      match until_ts with
      | None -> true
      | Some upper -> ts <= upper
    in
    after_lower && before_upper

let max_ts_opt current candidate =
  match current with
  | Some existing when existing >= candidate -> current
  | _ -> Some candidate

let latest_ts_of_entries (entries : Yojson.Safe.t list) : float option =
  List.fold_left
    (fun acc json ->
      let ts = extract_ts json in
      if ts > 0.0 then max_ts_opt acc ts else acc)
    None entries

let latest_store_ts dir label : float option =
  if not (Sys.file_exists dir) then None
  else
    match Dated_jsonl.create ~base_dir:dir () with
    | store -> latest_ts_of_entries (Dated_jsonl.read_recent store 64)
    | exception (Eio.Cancel.Cancelled _ as e) -> raise e
    | exception exn ->
      Log.Telemetry.warn "latest_store_ts: %s store open failed: %s" label
        (Printexc.to_string exn);
      None

let freshness_fields ~now latest_ts =
  match latest_ts with
  | Some ts ->
    let age = max 0.0 (now -. ts) in
    [
      ("latest_ts_unix", `Float ts);
      ("latest_ts_iso", `String (Types.iso8601_of_unix_seconds ts));
      ("latest_age_s", `Float age);
    ]
  | None ->
    [ ("latest_ts_unix", `Null); ("latest_ts_iso", `Null); ("latest_age_s", `Null) ]

(* ── Entry tagging ──────────────────────────────────── *)

let tag_entry source (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
    `Assoc (("source", `String (source_to_string source)) :: fields)
  | other ->
    `Assoc [("source", `String (source_to_string source)); ("data", other)]

(* ── Keeper/agent name extraction for filtering ─────── *)

let matches_keeper name (json : Yojson.Safe.t) : bool =
  match json with
  | `Assoc fields ->
    let check field =
      match List.assoc_opt field fields with
      | Some (`String k) -> String.equal k name
      | _ -> false
    in
    (* keeper_metric: "name" field; tool_call_io: "keeper"; oas_event: "agent_name" *)
    check "name"
    || check "keeper"
    || check "caller"
    || check "agent_id"
    || check "agent_name"
    || check "agent"
  | _ -> false

let matches_string_field field expected (json : Yojson.Safe.t) : bool =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt field fields with
      | Some (`String value) -> String.equal value expected
      | _ -> false)
  | _ -> false

let matches_scope ?session_id ?operation_id ?worker_run_id (json : Yojson.Safe.t) :
    bool =
  let matches field = function
    | None -> true
    | Some expected -> matches_string_field field expected json
  in
  matches "session_id" session_id
  && matches "operation_id" operation_id
  && matches "worker_run_id" worker_run_id

(* ── Read from a single fixed-path source ───────────── *)

let read_fixed_source dir source ~n ?since_ts ?until_ts () : Yojson.Safe.t list =
  if not (Sys.file_exists dir) then []
  else
    match Dated_jsonl.create ~base_dir:dir () with
    | store ->
      let entries =
        match effective_day_window ?since_ts ?until_ts () with
        | None -> Dated_jsonl.read_recent store n
        | Some (since_day, until_day) ->
          Dated_jsonl.read_range store ~since:since_day ~until:until_day
      in
      let entries =
        List.filter (within_requested_window ?since_ts ?until_ts) entries
      in
      List.map (tag_entry source) entries
    | exception (Eio.Cancel.Cancelled _ as e) -> raise e
    | exception exn ->
      Log.Telemetry.warn "read_fixed_source: %s store open failed: %s"
        (source_to_string source) (Printexc.to_string exn);
      []

(* ── Read keeper metrics (per-keeper directories) ───── *)

let read_keeper_metrics ~masc_root ?keeper_name ?since_ts ?until_ts ~n () :
    Yojson.Safe.t list =
  let dirs = discover_keeper_metric_dirs masc_root in
  let dirs = match keeper_name with
    | None -> dirs
    | Some name -> List.filter (fun (k, _) -> String.equal k name) dirs
  in
  List.concat_map (fun (_name, dir) ->
    read_fixed_source dir Keeper_metric ~n ?since_ts ?until_ts ()
  ) dirs

(* ── Unified read ───────────────────────────────────── *)

let read_unified_result ~base_path ~masc_root ?(sources = all_sources)
    ?keeper_name ?session_id ?operation_id ?worker_run_id ?since_ts ?until_ts
    ?(n = 100) () : read_result =
  let limited = n > 0 in
  let per_source = if limited then max n (n * 2) else 0 in
  let all_entries =
    List.concat_map (fun source ->
      match source with
      | Keeper_metric ->
        read_keeper_metrics ~masc_root ?keeper_name ?since_ts ?until_ts
          ~n:per_source ()
      | _ ->
        match fixed_store_dir ~masc_root ~base_path source with
        | Some dir ->
          read_fixed_source dir source ~n:per_source ?since_ts ?until_ts ()
        | None -> []
    ) sources
  in
  (* Filter by keeper_name for non-keeper-metric sources *)
  let filtered = match keeper_name with
    | None -> all_entries
    | Some name ->
      List.filter (fun json ->
        match json with
        | `Assoc fields ->
          (match List.assoc_opt "source" fields with
           | Some (`String "keeper_metric") -> true  (* already filtered *)
           | _ -> matches_keeper name json)
        | _ -> true
      ) all_entries
  in
  let filtered =
    List.filter
      (fun json -> matches_scope ?session_id ?operation_id ?worker_run_id json)
      filtered
  in
  (* Sort by timestamp descending (newest first) *)
  let sorted = List.sort (fun a b ->
    Float.compare (extract_ts b) (extract_ts a)
  ) filtered in
  let total_matching_entries = List.length sorted in
  let entries =
    if not limited || total_matching_entries <= n then sorted
    else List.filteri (fun i _ -> i < n) sorted
  in
  { entries; total_matching_entries; truncated = limited && total_matching_entries > n }

let read_unified ~base_path ~masc_root ?sources ?keeper_name ?session_id
    ?operation_id ?worker_run_id ?since_ts ?until_ts ?n () :
    Yojson.Safe.t list =
  (read_unified_result ~base_path ~masc_root ?sources ?keeper_name ?session_id
     ?operation_id ?worker_run_id ?since_ts ?until_ts ?n ()).entries

(* ── Summary ────────────────────────────────────────── *)

let count_fixed_source_entries ~masc_root ~base_path source : int =
  match fixed_store_dir ~masc_root ~base_path source with
  | None -> 0
  | Some dir ->
    if not (Sys.file_exists dir) then 0
    else
      (match Dated_jsonl.create ~base_dir:dir () with
       | store -> Dated_jsonl.count_entries store
       | exception (Eio.Cancel.Cancelled _ as e) -> raise e
       | exception exn ->
         Log.Telemetry.warn "count_source_entries: %s store open failed: %s"
           (source_to_string source) (Printexc.to_string exn);
         0)

let summary_json ~base_path ~masc_root () : Yojson.Safe.t =
  let now = Unix.gettimeofday () in
  let keeper_dirs = discover_keeper_metric_dirs masc_root in
  let keeper_total =
    List.fold_left (fun acc (name, dir) ->
      acc +
      (match Dated_jsonl.create ~base_dir:dir () with
       | store -> Dated_jsonl.count_entries store
       | exception (Eio.Cancel.Cancelled _ as e) -> raise e
       | exception exn ->
         Log.Telemetry.warn "summary_json: keeper %s store open failed: %s"
           name (Printexc.to_string exn);
         0)
    ) 0 keeper_dirs
  in
  let keeper_latest_ts =
    List.fold_left
      (fun acc (name, dir) ->
        match latest_store_ts dir (Printf.sprintf "keeper %s" name) with
        | Some ts -> max_ts_opt acc ts
        | None -> acc)
      None keeper_dirs
  in
  let source_json_and_count source =
    match source with
    | Keeper_metric ->
      ( `Assoc
          ([
             ("source", `String (source_to_string source));
             ( "keepers",
               `List
                 (List.map
                    (fun (name, dir) ->
                      `Assoc [ ("name", `String name); ("path", `String dir) ])
                    keeper_dirs) );
             ("keeper_count", `Int (List.length keeper_dirs));
             ("entry_count", `Int keeper_total);
           ]
          @ freshness_fields ~now keeper_latest_ts),
        keeper_total )
    | _ ->
      let dir = match fixed_store_dir ~masc_root ~base_path source with
        | Some d -> d | None -> "" in
      let exists = dir <> "" && Sys.file_exists dir in
      let count = if exists then count_fixed_source_entries ~masc_root ~base_path source else 0 in
      let latest_ts =
        if exists then latest_store_ts dir (source_to_string source) else None
      in
      ( `Assoc
          ([
             ("source", `String (source_to_string source));
             ("path", `String dir);
             ("exists", `Bool exists);
             ("entry_count", `Int count);
           ]
          @ freshness_fields ~now latest_ts),
        count )
  in
  let source_summaries = List.map source_json_and_count all_sources in
  let total_entries =
    List.fold_left (fun acc (_json, count) -> acc + count) 0 source_summaries
  in
  `Assoc [
    ("generated_at", `String (Types.now_iso ()));
    ("sources", `List (List.map fst source_summaries));
    ("total_entries", `Int total_entries);
  ]
