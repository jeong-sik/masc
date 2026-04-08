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
    - [<base_path>/data/tool-metrics/]       — Tool duration/success metrics

    @since 2.251.0 *)

type source =
  | Keeper_metric  (** Per-keeper turn/heartbeat metrics *)
  | Agent_event    (** Agent lifecycle, task, handoff events *)
  | Tool_call_io   (** Keeper tool calls with full input/output *)
  | Tool_usage     (** System_internal surface tool invocations *)
  | Tool_metric    (** Tool duration and success metrics *)

let source_to_string = function
  | Keeper_metric -> "keeper_metric"
  | Agent_event -> "agent_event"
  | Tool_call_io -> "tool_call_io"
  | Tool_usage -> "tool_usage"
  | Tool_metric -> "tool_metric"

let source_of_string = function
  | "keeper_metric" -> Some Keeper_metric
  | "agent_event" -> Some Agent_event
  | "tool_call_io" -> Some Tool_call_io
  | "tool_usage" -> Some Tool_usage
  | "tool_metric" -> Some Tool_metric
  | _ -> None

let all_sources = [Keeper_metric; Agent_event; Tool_call_io; Tool_usage; Tool_metric]

(* ── Store paths ────────────────────────────────────── *)

(** Fixed-path sources (single directory per source).

    [masc_root] is the cluster-aware .masc directory
    (e.g. [base_path/.masc] or [base_path/.masc/clusters/<name>]).
    [base_path] is the project root, used only for [data/] paths. *)
let fixed_store_dir ~masc_root ~base_path = function
  | Agent_event  -> Some (Filename.concat masc_root "telemetry")
  | Tool_call_io -> Some (Filename.concat masc_root "tool_calls")
  | Tool_usage   -> Some (Filename.concat masc_root "tool_usage")
  | Tool_metric  -> Some (Filename.concat base_path "data/tool-metrics")
  | Keeper_metric -> None  (* per-keeper, handled separately *)

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
         | None -> 0.0)
  | _ -> 0.0

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
    (* keeper_metric: "name" field; tool_call_io: "keeper"; tool_usage: "caller" *)
    check "name" || check "keeper" || check "caller" || check "agent_id"
  | _ -> false

(* ── Read from a single fixed-path source ───────────── *)

let read_fixed_source dir source ~n : Yojson.Safe.t list =
  if not (Sys.file_exists dir) then []
  else
    match Dated_jsonl.create ~base_dir:dir () with
    | store ->
      let entries = Dated_jsonl.read_recent store n in
      List.map (tag_entry source) entries
    | exception (Eio.Cancel.Cancelled _ as e) -> raise e
    | exception _ -> []

(* ── Read keeper metrics (per-keeper directories) ───── *)

let read_keeper_metrics ~masc_root ?keeper_name ~n () : Yojson.Safe.t list =
  let dirs = discover_keeper_metric_dirs masc_root in
  let dirs = match keeper_name with
    | None -> dirs
    | Some name -> List.filter (fun (k, _) -> String.equal k name) dirs
  in
  List.concat_map (fun (_name, dir) ->
    read_fixed_source dir Keeper_metric ~n
  ) dirs

(* ── Unified read ───────────────────────────────────── *)

let read_unified ~base_path ~masc_root ?(sources = all_sources) ?keeper_name
    ?(n = 100) () : Yojson.Safe.t list =
  let per_source = max n (n * 2) in
  let all_entries =
    List.concat_map (fun source ->
      match source with
      | Keeper_metric ->
        read_keeper_metrics ~masc_root ?keeper_name ~n:per_source ()
      | _ ->
        match fixed_store_dir ~masc_root ~base_path source with
        | Some dir -> read_fixed_source dir source ~n:per_source
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
  (* Sort by timestamp descending (newest first) *)
  let sorted = List.sort (fun a b ->
    Float.compare (extract_ts b) (extract_ts a)
  ) filtered in
  if List.length sorted <= n then sorted
  else List.filteri (fun i _ -> i < n) sorted

(* ── Summary ────────────────────────────────────────── *)

let count_fixed_source_entries ~masc_root ~base_path source : int =
  match fixed_store_dir ~masc_root ~base_path source with
  | None -> 0
  | Some dir ->
    if not (Sys.file_exists dir) then 0
    else
      (match Dated_jsonl.create ~base_dir:dir () with
       | store -> List.length (Dated_jsonl.read_recent store 10_000)
       | exception (Eio.Cancel.Cancelled _ as e) -> raise e
       | exception _ -> 0)

let summary_json ~base_path ~masc_root () : Yojson.Safe.t =
  let keeper_dirs = discover_keeper_metric_dirs masc_root in
  let keeper_total =
    List.fold_left (fun acc (_, dir) ->
      acc +
      (match Dated_jsonl.create ~base_dir:dir () with
       | store -> List.length (Dated_jsonl.read_recent store 10_000)
       | exception (Eio.Cancel.Cancelled _ as e) -> raise e
       | exception _ -> 0)
    ) 0 keeper_dirs
  in
  let source_json source =
    match source with
    | Keeper_metric ->
      `Assoc [
        ("source", `String (source_to_string source));
        ("keepers", `List (List.map (fun (name, dir) ->
           `Assoc [
             ("name", `String name);
             ("path", `String dir);
           ]) keeper_dirs));
        ("keeper_count", `Int (List.length keeper_dirs));
        ("entry_count", `Int keeper_total);
      ]
    | _ ->
      let dir = match fixed_store_dir ~masc_root ~base_path source with
        | Some d -> d | None -> "" in
      let exists = dir <> "" && Sys.file_exists dir in
      let count = if exists then count_fixed_source_entries ~masc_root ~base_path source else 0 in
      `Assoc [
        ("source", `String (source_to_string source));
        ("path", `String dir);
        ("exists", `Bool exists);
        ("entry_count", `Int count);
      ]
  in
  let fixed_total =
    List.fold_left (fun acc s ->
      acc + count_fixed_source_entries ~masc_root ~base_path s
    ) 0 (List.filter (fun s -> s <> Keeper_metric) all_sources)
  in
  `Assoc [
    ("generated_at", `String (Types.now_iso ()));
    ("sources", `List (List.map source_json all_sources));
    ("total_entries", `Int (keeper_total + fixed_total));
  ]
