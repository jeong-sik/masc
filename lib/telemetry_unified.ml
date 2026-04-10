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

type source_status =
  | Source_ok
  | Source_missing
  | Source_degraded of string

let source_status_to_string = function
  | Source_ok -> "ok"
  | Source_missing -> "missing"
  | Source_degraded _ -> "degraded"

let dir_status path =
  try
    if not (Sys.file_exists path) then Source_missing
    else if Sys.is_directory path then Source_ok
    else Source_degraded "not a directory"
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Source_degraded (Printexc.to_string exn)

let warn_source_failure ~source ~path ~action message =
  Log.Telemetry.warn
    "telemetry_unified %s failed: source=%s path=%s err=%s" action
    (source_to_string source) path message

let parse_recent_lines ~source ~path lines =
  lines
  |> List.mapi (fun index line -> (index + 1, line))
  |> List.filter_map (fun (index, line) ->
         try Some (Yojson.Safe.from_string line)
         with
         | Yojson.Json_error msg ->
             Log.Telemetry.warn
               "telemetry_unified parse failed: source=%s path=%s recent_row=%d err=%s"
               (source_to_string source) path index msg;
             None)

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
  | Keeper_metric -> None  (* handled separately *)

(** Discover all keeper metric directories under [masc_root/keepers/]. *)
let discover_keeper_metric_dirs masc_root : (string * string) list =
  let keepers_dir = Filename.concat masc_root "keepers" in
  match dir_status keepers_dir with
  | Source_missing -> []
  | Source_degraded message ->
      warn_source_failure ~source:Keeper_metric ~path:keepers_dir
        ~action:"discover" message;
      []
  | Source_ok -> (
      match Safe_ops.list_dir_safe keepers_dir with
      | Error message ->
          warn_source_failure ~source:Keeper_metric ~path:keepers_dir
            ~action:"discover" message;
          []
      | Ok entries ->
          List.filter_map
            (fun name ->
              let metrics_dir =
                Filename.concat keepers_dir (name ^ "/metrics")
              in
              match dir_status metrics_dir with
              | Source_ok -> Some (name, metrics_dir)
              | Source_missing -> None
              | Source_degraded message ->
                  warn_source_failure ~source:Keeper_metric ~path:metrics_dir
                    ~action:"discover" message;
                  None)
            entries)

(* ── Timestamp extraction ───────────────────────────── *)

let extract_ts_opt (json : Yojson.Safe.t) : float option =
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
     | Some f -> Some f
     | None ->
       match try_field "ts" with
       | Some f -> Some f
       | None ->
         match try_field "timestamp" with
         | Some f -> Some f
         | None ->
           (match List.assoc_opt "ts_iso" fields with
            | Some (`String iso) ->
                Types.parse_iso8601_opt iso
            | _ -> None))
  | _ -> None

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

let read_fixed_source dir source ~n : Yojson.Safe.t list =
  match dir_status dir with
  | Source_missing -> []
  | Source_degraded message ->
      warn_source_failure ~source ~path:dir ~action:"read" message;
      []
  | Source_ok -> (
      match Dated_jsonl.create ~base_dir:dir () with
      | store ->
          let entries =
            Dated_jsonl.read_recent_lines store n
            |> parse_recent_lines ~source ~path:dir
          in
          List.map (tag_entry source) entries
      | exception (Eio.Cancel.Cancelled _ as e) -> raise e
      | exception exn ->
          warn_source_failure ~source ~path:dir ~action:"read"
            (Printexc.to_string exn);
          [])

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
    ?session_id ?operation_id ?worker_run_id ?(n = 100) () :
    Yojson.Safe.t list =
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
  let filtered =
    List.filter
      (fun json -> matches_scope ?session_id ?operation_id ?worker_run_id json)
      filtered
  in
  (* Sort by timestamp descending (newest first) *)
  let sorted =
    List.sort
      (fun a b ->
        match (extract_ts_opt a, extract_ts_opt b) with
        | Some ta, Some tb -> Float.compare tb ta
        | Some _, None -> -1
        | None, Some _ -> 1
        | None, None -> 0)
      filtered
  in
  if List.length sorted <= n then sorted
  else List.filteri (fun i _ -> i < n) sorted

(* ── Summary ────────────────────────────────────────── *)

let fixed_source_status_json ~masc_root ~base_path source =
  match fixed_store_dir ~masc_root ~base_path source with
  | None ->
      `Assoc
        [
          ("source", `String (source_to_string source));
          ("path", `String "");
          ("exists", `Bool false);
          ("status", `String "missing");
          ("entry_count", `Int 0);
        ]
  | Some dir ->
      let base_fields status entry_count =
        [
          ("source", `String (source_to_string source));
          ("path", `String dir);
          ("exists", `Bool (status <> Source_missing));
          ("status", `String (source_status_to_string status));
          ("entry_count", `Int entry_count);
        ]
      in
      (match dir_status dir with
       | Source_missing -> `Assoc (base_fields Source_missing 0)
       | Source_degraded message ->
           `Assoc
             (base_fields (Source_degraded message) 0
             @ [ ("error", `String message) ])
       | Source_ok -> (
           match Dated_jsonl.create ~base_dir:dir () with
           | store -> `Assoc (base_fields Source_ok (Dated_jsonl.count_entries store))
           | exception (Eio.Cancel.Cancelled _ as e) -> raise e
           | exception exn ->
               let message = Printexc.to_string exn in
               `Assoc
                 (base_fields (Source_degraded message) 0
                 @ [ ("error", `String message) ])))

let keeper_metrics_status_json ~masc_root =
  let keepers_dir = Filename.concat masc_root "keepers" in
  let base_fields status keeper_count entry_count =
    [
      ("source", `String (source_to_string Keeper_metric));
      ("path", `String keepers_dir);
      ("exists", `Bool (status <> Source_missing));
      ("status", `String (source_status_to_string status));
      ("keeper_count", `Int keeper_count);
      ("entry_count", `Int entry_count);
    ]
  in
  match dir_status keepers_dir with
  | Source_missing ->
      `Assoc (base_fields Source_missing 0 0 @ [ ("keepers", `List []) ])
  | Source_degraded message ->
      `Assoc
        (base_fields (Source_degraded message) 0 0
        @ [ ("error", `String message); ("keepers", `List []) ])
  | Source_ok -> (
      match Safe_ops.list_dir_safe keepers_dir with
      | Error message ->
          `Assoc
            (base_fields (Source_degraded message) 0 0
            @ [ ("error", `String message); ("keepers", `List []) ])
      | Ok entries ->
          let keeper_items, degraded_count, total_entries =
            List.fold_left
              (fun (items, degraded_count, total_entries) name ->
                let metrics_dir = Filename.concat keepers_dir (name ^ "/metrics") in
                match dir_status metrics_dir with
                | Source_missing -> (items, degraded_count, total_entries)
                | Source_degraded message ->
                    ( `Assoc
                        [
                          ("name", `String name);
                          ("path", `String metrics_dir);
                          ("status", `String "degraded");
                          ("entry_count", `Int 0);
                          ("error", `String message);
                        ]
                      :: items,
                      degraded_count + 1,
                      total_entries )
                | Source_ok -> (
                    match Dated_jsonl.create ~base_dir:metrics_dir () with
                    | store ->
                        let entry_count = Dated_jsonl.count_entries store in
                        ( `Assoc
                            [
                              ("name", `String name);
                              ("path", `String metrics_dir);
                              ("status", `String "ok");
                              ("entry_count", `Int entry_count);
                            ]
                          :: items,
                          degraded_count,
                          total_entries + entry_count )
                    | exception (Eio.Cancel.Cancelled _ as e) -> raise e
                    | exception exn ->
                        let message = Printexc.to_string exn in
                        ( `Assoc
                            [
                              ("name", `String name);
                              ("path", `String metrics_dir);
                              ("status", `String "degraded");
                              ("entry_count", `Int 0);
                              ("error", `String message);
                            ]
                          :: items,
                          degraded_count + 1,
                          total_entries )))
              ([], 0, 0) entries
          in
          let keeper_items = List.rev keeper_items in
          let status =
            if degraded_count > 0 then Source_degraded "one or more keeper metric stores degraded"
            else Source_ok
          in
          let extra_fields =
            match status with
            | Source_ok | Source_missing -> []
            | Source_degraded message -> [ ("error", `String message) ]
          in
          `Assoc
            (base_fields status (List.length keeper_items) total_entries
            @ extra_fields
            @ [ ("keepers", `List keeper_items) ]))

let summary_json ~base_path ~masc_root () : Yojson.Safe.t =
  let sources_json =
    List.map
      (function
        | Keeper_metric -> keeper_metrics_status_json ~masc_root
        | source -> fixed_source_status_json ~masc_root ~base_path source)
      all_sources
  in
  let degraded_sources =
    List.fold_left
      (fun acc -> function
        | `Assoc fields -> (
            match List.assoc_opt "status" fields with
            | Some (`String "degraded") -> acc + 1
            | _ -> acc)
        | _ -> acc)
      0 sources_json
  in
  let total_entries =
    List.fold_left
      (fun acc -> function
        | `Assoc fields -> (
            match List.assoc_opt "entry_count" fields with
            | Some (`Int count) -> acc + count
            | _ -> acc)
        | _ -> acc)
      0 sources_json
  in
  `Assoc [
    ("generated_at", `String (Types.now_iso ()));
    ("status", `String (if degraded_sources > 0 then "degraded" else "ok"));
    ("degraded_source_count", `Int degraded_sources);
    ("sources", `List sources_json);
    ("total_entries", `Int total_entries);
  ]
