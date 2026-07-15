(** Telemetry_unified — Read-only aggregation of scattered telemetry stores.

    Reads from multiple independent {!Dated_jsonl} stores, tags each record
    with a ["source"] discriminator, and returns a merged time-sorted view.

    No existing write paths are modified.  The module creates read-only
    {!Dated_jsonl} handles (no appends, no directory creation).

    Sources (paths are relative to the cluster-aware [masc_root]):
    - [<masc_root>/keepers/<name>/metrics/]  — Per-keeper turn metrics
    - [<masc_root>/telemetry/]               — Agent lifecycle + tool call events
    - [<masc_root>/tool_calls/]              — Full I/O for keeper tool calls
    - [<masc_root>/trajectories/<keeper>/]   — Keeper trajectory tool-call rows
    - [<masc_root>/tool_usage/]              — Non-public registered tool calls
    - [<masc_root>/oas-events/]              — Durable OAS native/custom events
    - [<masc_root>/keepers/<name>/execution-receipts/]
                                             — Keeper execution receipts
    - [<base_path>/data/tool-metrics/]       — Tool duration/success metrics
    @since 2.251.0 *)

type source = Telemetry_unified_source.source =
  | Keeper_metric
  | Agent_event
  | Tool_call_io
  | Trajectory_tool_call
  | Tool_usage
  | Oas_event
  | Execution_receipt
  | Tool_metric

let source_to_string = Telemetry_unified_source.source_to_string
let source_of_string = Telemetry_unified_source.source_of_string
let all_sources = Telemetry_unified_source.all_sources

(* Source classification, metadata, and directory discovery extracted to
   [Telemetry_unified_source_meta] (godfile decomp). *)
include Telemetry_unified_source_meta

let trajectory_tool_call_json = function
  | `Assoc fields -> (
      match List.assoc_opt "type" fields with
      | Some (`String ("trajectory_summary" | "thinking")) -> false
      | _ ->
          List.mem_assoc "tool_name" fields
          && List.mem_assoc "ts" fields)
  | _ -> false

(* ── Timestamp extraction ───────────────────────────── *)

let extract_ts (json : Yojson.Safe.t) : float =
  match json with
  | `Assoc fields ->
    let try_numeric_field name =
      match List.assoc_opt name fields with
      | Some (`Float f) -> Some f
      | Some (`Int i) -> Some (Float.of_int i)
      | _ -> None
    in
    let try_iso_field name =
      match List.assoc_opt name fields with
      | Some (`String iso) -> Masc_domain.parse_iso8601_opt iso
      | _ -> None
    in
    let rec first_some f = function
      | [] -> None
      | name :: rest -> (
          match f name with
          | Some value -> Some value
          | None -> first_some f rest)
    in
    (match first_some try_numeric_field [ "ts_unix"; "ts"; "timestamp" ] with
     | Some ts -> ts
     | None ->
       first_some try_iso_field
         [ "ts_iso"; "ts"; "recorded_at"; "ended_at"; "started_at" ]
       |> Option.value ~default:0.0)
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

let latest_store_ts source dir label : float option =
  if not (Sys.file_exists dir) then None
  else
    match Dated_jsonl.create ~base_dir:dir () with
    | store -> latest_ts_of_entries (Dated_jsonl.read_recent store 64)
    | exception (Eio.Cancel.Cancelled _ as e) -> raise e
    | exception exn ->
      observe_source_read_failure_exn source ~site:"latest_store_ts" exn;
      Log.Telemetry.warn "latest_store_ts: %s store open failed" label;
      None

let sort_newest_first entries =
  List.sort (fun a b -> Float.compare (extract_ts b) (extract_ts a)) entries

let take_first = List.take

let freshness_fields ~now latest_ts =
  match latest_ts with
  | Some ts ->
    let age = max 0.0 (now -. ts) in
    [
      ("latest_ts_unix", `Float ts);
      ("latest_ts_iso", `String (Masc_domain.iso8601_of_unix_seconds ts));
      ("latest_age_s", `Float age);
    ]
  | None ->
    [ ("latest_ts_unix", `Null); ("latest_ts_iso", `Null); ("latest_age_s", `Null) ]

let source_health_fields ~now ~exists ~entry_count ~latest_ts ~freshness_slo_s
    ?(optional_when_missing = false) ?(read_error = false) ?coverage_gap () =
  match coverage_gap with
  | Some gap ->
    [
      ("health", `String "coverage_gap");
      ( "stale_reason",
        `String
          (Safe_ops.json_string ~default:"coverage_gap" "stale_reason" gap) );
    ]
  | None ->
    let health, stale_reason =
      if read_error then ("error", "read_failed")
      else if not exists && optional_when_missing then ("not_yet", "no_entries_yet")
      else if not exists then ("missing", "store_missing")
      else if entry_count = 0 then ("empty", "no_entries")
      else
        match latest_ts with
        | None -> ("empty", "no_entries")
        | Some ts ->
          let latest_age_s = max 0.0 (now -. ts) in
          if latest_age_s > freshness_slo_s then
            ("stale", "freshness_slo_exceeded")
          else ("ok", "")
    in
    [
      ("health", `String health);
      ( "stale_reason",
        if stale_reason = "" then `Null else `String stale_reason );
    ]

let source_optional_when_missing _ = false

let coverage_gap_recovered ~latest_ts gap =
  match latest_ts, extract_ts gap with
  | Some source_ts, gap_ts
    when gap_ts > 0.0 && Float.compare source_ts gap_ts >= 0 ->
      true
  | _ -> false

let coverage_gaps_for_source gaps source =
  let source_name = source_to_string source in
  gaps
  |> List.filter (fun gap ->
       String.equal
         (Safe_ops.json_string ~default:"" "source" gap)
         source_name)

let active_coverage_gaps ~latest_ts gaps =
  List.filter (fun gap -> not (coverage_gap_recovered ~latest_ts gap)) gaps

let coverage_gap_status_fields gaps source ~latest_ts =
  let source_gaps = coverage_gaps_for_source gaps source in
  let active_gaps = active_coverage_gaps ~latest_ts source_gaps in
  ( [
      ("coverage_gap_count", `Int (List.length source_gaps));
      ("active_coverage_gap_count", `Int (List.length active_gaps));
    ],
    List.rev active_gaps |> List.find_opt (fun _ -> true) )

(* ── Semantic duplicate suppression ───────────────── *)

let assoc_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let string_field name json =
  match Json_field.string json name |> Json_field.to_option with
  | None -> None
  | Some value ->
    let value = String.trim value in
    if value = "" then None else Some value
;;

let bool_field name json =
  Json_field.bool json name |> Json_field.to_option
;;

let drop_prefix prefix value =
  if String.starts_with ~prefix value then
    String.sub value (String.length prefix)
      (String.length value - String.length prefix)
  else value

let drop_suffix suffix value =
  if String.ends_with ~suffix value then
    String.sub value 0 (String.length value - String.length suffix)
  else value

let canonical_actor_name value =
  value
  |> String.trim
  |> drop_prefix "keeper-"
  |> drop_suffix "-agent"

type tool_call_signature = {
  actor : string;
  tool : string;
  success : bool option;
  ts : float;
}

let tool_call_signature ?success ~actor ~tool ~ts () =
  let actor = canonical_actor_name actor in
  let tool = String.trim tool in
  if actor = "" || tool = "" || ts <= 0.0 then None
  else Some { actor; tool; success; ts }

let tool_call_io_signature json =
  match string_field "source" json with
  | Some "tool_call_io" ->
    (match string_field "keeper" json, string_field "tool" json with
     | Some actor, Some tool ->
       tool_call_signature ?success:(bool_field "success" json) ~actor ~tool
         ~ts:(extract_ts json) ()
     | _ -> None)
  | _ -> None

let tool_called_detail_from_fields fields =
  match List.assoc_opt "event" fields with
  | Some (`List (`String tag :: detail :: _))
    when tag = "Tool_called" || tag = "tool_called" -> (
      match detail with
      | `Assoc _ -> Some detail
      | _ -> None)
  | _ -> None

let tool_called_event_detail json =
  match string_field "source" json, json with
  | Some "agent_event", `Assoc fields -> tool_called_detail_from_fields fields
  | _ -> None

let keeper_tool_called_signature json =
  match tool_called_event_detail json with
  | None -> None
  | Some detail ->
    (match string_field "agent_id" detail, string_field "tool_name" detail with
     | Some actor, Some tool ->
       tool_call_signature ?success:(bool_field "success" detail) ~actor ~tool
         ~ts:(extract_ts json) ()
     | _ -> None)

let same_tool_call_signature left right =
  String.equal left.actor right.actor
  && String.equal left.tool right.tool
  &&
  (match left.success, right.success with
   | Some a, Some b -> Bool.equal a b
   | None, None -> true
   | Some _, None | None, Some _ -> false)
  && abs_float (left.ts -. right.ts) <= 5.0

let suppress_shadow_keeper_tool_events entries =
  let tool_call_io =
    List.filter_map tool_call_io_signature entries
  in
  if tool_call_io = [] then entries
  else
    List.filter
      (fun json ->
        match keeper_tool_called_signature json with
        | None -> true
        | Some signature ->
          not (List.exists (same_tool_call_signature signature) tool_call_io))
      entries

(* ── Entry tagging ──────────────────────────────────── *)

let promote_detail_field_if_absent name detail_fields fields =
  if List.mem_assoc name fields then fields
  else
    match List.assoc_opt name detail_fields with
    | Some (`String value) when String.trim value <> "" ->
        (name, `String value) :: fields
    | Some (`Bool _ as value)
    | Some (`Int _ as value)
    | Some (`Float _ as value)
    | Some (`Intlit _ as value) ->
        (name, value) :: fields
    | Some _ | None -> fields

let promote_keeper_tool_called_scope source fields =
  match source, tool_called_detail_from_fields fields with
  | Agent_event, Some (`Assoc detail_fields) ->
      List.fold_left
        (fun acc name -> promote_detail_field_if_absent name detail_fields acc)
        fields
        [
          "agent_id";
          "tool_name";
          "success";
          "duration_ms";
          "session_id";
          "operation_id";
          "worker_run_id";
        ]
  | _ -> fields

let tag_entry source (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
    let fields = promote_keeper_tool_called_scope source fields in
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
    let check_runtime_contract () =
      match List.assoc_opt "runtime_contract" fields with
      | Some (`Assoc runtime_fields) -> (
          match List.assoc_opt "keeper_name" runtime_fields with
          | Some (`String k) -> String.equal k name
          | _ -> false)
      | _ -> false
    in
    (* keeper_metric: "name" field; tool_call_io: "keeper"; oas_event: "agent_name" *)
    check "name"
    || check "keeper"
    || check "keeper_name"
    || check "caller"
    || check "agent_id"
    || check "agent_name"
    || check "agent"
    || check_runtime_contract ()
  | _ -> false

let matches_field fields field expected =
  match List.assoc_opt field fields with
  | Some (`String value) -> String.equal value expected
  | _ -> false

let matches_scope ?session_id ?operation_id ?worker_run_id (json : Yojson.Safe.t) :
    bool =
  let matches ~top_fields ~runtime_contract_fields = function
    | None -> true
    | Some expected -> (
        match json with
        | `Assoc fields ->
          List.exists
            (fun field -> matches_field fields field expected)
            top_fields
          ||
          (match List.assoc_opt "runtime_contract" fields with
           | Some (`Assoc runtime_fields) ->
             List.exists
               (fun field -> matches_field runtime_fields field expected)
               runtime_contract_fields
           | _ -> false)
        | _ -> false)
  in
  matches ~top_fields:[ "session_id" ]
    ~runtime_contract_fields:[ "session_id" ]
    session_id
  && matches ~top_fields:[ "operation_id" ]
       ~runtime_contract_fields:[ "operation_id" ]
       operation_id
  && matches ~top_fields:[ "worker_run_id" ]
       ~runtime_contract_fields:[ "worker_run_id"; "trace_id" ]
       worker_run_id

(* ── Read from a single fixed-path source ───────────── *)

(* A non-positive [n] means "unlimited" at the call sites (dashboard /telemetry
   sends no [n], so [read_unified_result] derives per_source = 0). Scanning the
   entire store for that case Yojson-parsed every entry over 1970->today on the
   keeper's Eio domain, and major-GC starved keeper fibers (measured: a single
   no-[n] /api/v1/dashboard/telemetry request held one core at 100%+ for ~8s on
   a 224MB execution-receipts store, blocking turns). Clamp "unlimited" to this
   cap so every read goes through the tail-bounded readers instead of a
   full-store [read_range]. The cap is large enough that real dashboard windows
   never hit it; if a future caller needs more, raise it deliberately rather
   than reintroducing an unbounded scan. *)
let unbounded_window_scan_cap = 50_000

(* Shared read path for directory-backed Dated_jsonl stores. Always routes
   through the tail-bounded readers ([read_recent] / [read_range_recent]) so a
   wide window or an "unlimited" ([n] <= 0) request cannot parse the whole
   store. Returns entries filtered to the requested timestamp window, untagged;
   callers tag with their source. *)
let bounded_entries_for_window store ~n ?since_ts ?until_ts () =
  let effective_n = if n <= 0 then unbounded_window_scan_cap else n in
  let entries =
    match effective_day_window ?since_ts ?until_ts () with
    | None -> Dated_jsonl.read_recent store effective_n
    | Some (since_day, until_day) ->
      Dated_jsonl.read_range_recent store ~since:since_day ~until:until_day
        effective_n
  in
  List.filter (within_requested_window ?since_ts ?until_ts) entries

let read_fixed_source dir source ~n ?since_ts ?until_ts () : Yojson.Safe.t list =
  match classify_store_dir source ~site:"read_fixed_source_dir" dir with
  | Store_missing | Store_invalid -> []
  | Store_directory ->
    match Dated_jsonl.create ~base_dir:dir () with
    | store ->
      bounded_entries_for_window store ~n ?since_ts ?until_ts ()
      |> List.map (tag_entry source)
    | exception (Eio.Cancel.Cancelled _ as e) -> raise e
    | exception exn ->
      observe_source_read_failure_exn source ~site:"read_fixed_source" exn;
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

let read_keeper_metrics_fast_top ~masc_root ~n () : Yojson.Safe.t list =
  let target = n + 1 in
  let probe_limit = min 64 target in
  let dirs = discover_keeper_metric_dirs masc_root in
  let probes =
    List.filter_map
      (fun (name, dir) ->
        let entries = read_fixed_source dir Keeper_metric ~n:probe_limit () in
        match latest_ts_of_entries entries with
        | None -> None
        | Some latest_ts -> Some (name, dir, latest_ts, entries))
      dirs
    |> List.sort (fun (_, _, a, _) (_, _, b, _) -> Float.compare b a)
  in
  let rec loop acc = function
    | [] -> acc
    | (_name, dir, latest_ts, probe_entries) :: rest ->
      let acc = sort_newest_first acc |> take_first target in
      let cutoff =
        if List.length acc < target then None
        else List.nth_opt acc (target - 1) |> Option.map extract_ts
      in
      (match cutoff with
       | Some ts when latest_ts < ts -> acc
       | _ ->
         let entries =
           if target <= probe_limit then probe_entries
           else read_fixed_source dir Keeper_metric ~n:target ()
         in
         loop (sort_newest_first (entries @ acc) |> take_first target) rest)
  in
  loop [] probes

(* Execution-receipt stores read through the same tail-bounded helper as the
   fixed sources. Previously an "unlimited" ([n] <= 0) request here scanned
   1970->today via [read_range] — the measured GC-starvation path for the
   dashboard /telemetry endpoint. *)
let dated_jsonl_entries store ~n ?since_ts ?until_ts () =
  bounded_entries_for_window store ~n ?since_ts ?until_ts ()

let read_execution_receipts ~masc_root ?keeper_name ?since_ts ?until_ts ~n ()
    : Yojson.Safe.t list =
  let dirs = discover_execution_receipt_dirs masc_root in
  let dirs =
    match keeper_name with
    | None -> dirs
    | Some name -> List.filter (fun (k, _) -> String.equal k name) dirs
  in
  List.concat_map
    (fun (_name, dir) ->
      try
        let store = Dated_jsonl.create ~base_dir:dir () in
        dated_jsonl_entries store ~n ?since_ts ?until_ts ()
        |> List.map (tag_entry Execution_receipt)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        observe_source_read_failure_exn Execution_receipt
          ~site:"read_execution_receipts" exn;
        Log.Telemetry.warn
          "read_execution_receipts: store open failed for %s" dir;
        [])
    dirs

let read_trajectory_file path ~max_lines ?since_ts ?until_ts () =
  if
    not
      (is_jsonl_file Trajectory_tool_call
         ~site:"read_trajectory_file_stat" path)
  then []
  else
    protect_source_read Trajectory_tool_call ~site:"read_trajectory_file"
      ~default:[] (fun () ->
      let parse_error_count = ref 0 in
      let entries =
        (* Tail-bounded read: trajectory trace files grow append-only (one
           measured at 12MB); [load_file] parsed the whole file on the keeper
           Eio domain. Measured post-#20659/#20662: the trajectory source was
           ~6.9s of an 8.3s /telemetry request — the dominant keeper-fleet
           freeze cost, since [read_trajectory_tool_calls] ignored its [n] and
           full-parsed every trace. Read only the newest [max_lines] from the
           tail; trajectories are append-ordered so the tail is the recent
           window the dashboard polls. *)
        Dated_jsonl.load_tail_lines path ~max_lines
        |> List.filter_map (fun line ->
             let line = String.trim line in
             if line = "" then None
             else
               try
                 let json = Yojson.Safe.from_string line in
                 if trajectory_tool_call_json json
                    && within_requested_window ?since_ts ?until_ts json
                 then Some json
                 else None
               with Yojson.Json_error _ ->
                 incr parse_error_count;
                 None)
      in
      if !parse_error_count > 0 then
        observe_source_read_failure Trajectory_tool_call
          ~site:"read_trajectory_file_parse"
          ~error:
            (Printf.sprintf "%s has %d malformed JSONL line(s)" path
               !parse_error_count);
      entries)

(* A trace file whose last write predates [since_ts] cannot hold entries in the
   requested window: traces are append-ordered, so the file mtime tracks the
   newest entry. Skip such files without opening them. Observatory polls a 1h
   window, but the store keeps ~84 trace files across keepers (most >7d old), so
   the windowed read tail-read every one (#20665 bounded per-file lines but not
   the file fan-out — measured 3.2s windowed vs 0.25s no-window). mtime-skip
   cuts the per-call fan-out from all-files to in-window-files. Conservative on
   stat failure (keeps the file) and when no window is requested. *)
let trace_file_within_since ~since_ts path =
  match since_ts with
  | None -> true
  | Some since ->
    (match Unix.stat path with
     | st -> st.Unix.st_mtime >= since
     | exception _ -> true)

let read_trajectory_tool_calls ~masc_root ?keeper_name ?since_ts ?until_ts ~n ()
    : Yojson.Safe.t list =
  let dirs = discover_trajectory_keeper_dirs masc_root in
  let dirs =
    match keeper_name with
    | None -> dirs
    | Some name -> List.filter (fun (k, _) -> String.equal k name) dirs
  in
  (* Bound the per-file tail read. A non-positive [n] ("unlimited") clamps to
     [unbounded_window_scan_cap] so no trace file is full-parsed. The final
     [take_first n] still trims the merged set; this only stops the read itself
     from being unbounded (the freeze cause). *)
  let max_lines = if n <= 0 then unbounded_window_scan_cap else n in
  let entries =
    List.concat_map
      (fun (_name, dir) ->
        protect_source_read Trajectory_tool_call
          ~site:"read_trajectory_tool_calls_readdir" ~default:[] (fun () ->
          Sys.readdir dir
          |> Array.to_list
          |> List.filter (fun name ->
               Filename.check_suffix name ".jsonl"
               && trace_file_within_since ~since_ts (Filename.concat dir name))
          |> List.concat_map (fun name ->
               read_trajectory_file
                 (Filename.concat dir name)
                 ~max_lines ?since_ts ?until_ts ())))
      dirs
  in
  let entries = sort_newest_first entries in
  let entries = if n <= 0 then entries else take_first n entries in
  List.map (tag_entry Trajectory_tool_call) entries

(* ── Unified read ───────────────────────────────────── *)

let read_unified_result ~base_path ~masc_root ?(sources = all_sources)
    ?keeper_name ?session_id ?operation_id ?worker_run_id ?since_ts ?until_ts
    ?(n = 100) ?(offset = 0) () : read_result =
  let limited = n > 0 in
  let has_filter =
    Option.is_some keeper_name || Option.is_some session_id
    || Option.is_some operation_id || Option.is_some worker_run_id
    || Option.is_some since_ts || Option.is_some until_ts
  in
  let per_source =
    if not limited then 0
    else if has_filter then max (n + offset) ((n + offset) * 2)
    else n + offset + 1
  in
  let all_entries =
    List.concat_map (fun source ->
      match source with
      | Keeper_metric ->
        if limited && Option.is_none keeper_name && not has_filter then
          read_keeper_metrics_fast_top ~masc_root ~n ()
        else
          read_keeper_metrics ~masc_root ?keeper_name ?since_ts ?until_ts
            ~n:per_source ()
      | Trajectory_tool_call ->
        read_trajectory_tool_calls ~masc_root ?keeper_name ?since_ts ?until_ts
          ~n:per_source ()
      | Execution_receipt ->
        read_execution_receipts ~masc_root ?keeper_name ?since_ts ?until_ts
          ~n:per_source ()
      (* Fixed-path sources: Agent_event, Tool_call_io, Tool_usage,
         Oas_event, Tool_metric use directory-based storage. *)
      | Agent_event | Tool_call_io | Tool_usage | Oas_event | Tool_metric ->
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
  let filtered =
    if List.mem Agent_event sources && List.mem Tool_call_io sources then
      suppress_shadow_keeper_tool_events filtered
    else filtered
  in
  (* Sort by timestamp descending (newest first) *)
  let sorted = sort_newest_first filtered in
  let total_matching_entries = List.length sorted in
  let entries =
    if not limited || total_matching_entries <= offset + n then sorted
    else sorted |> List.drop offset |> take_first n
  in
  { entries; total_matching_entries; truncated = limited && total_matching_entries > offset + n }

let read_unified ~base_path ~masc_root ?sources ?keeper_name ?session_id
    ?operation_id ?worker_run_id ?since_ts ?until_ts ?n ?offset () :
    Yojson.Safe.t list =
  (read_unified_result ~base_path ~masc_root ?sources ?keeper_name ?session_id
     ?operation_id ?worker_run_id ?since_ts ?until_ts ?n ?offset ()).entries

(* ── Summary ────────────────────────────────────────── *)

let count_fixed_source_entries ~masc_root ~base_path source : int =
  match fixed_store_dir ~masc_root ~base_path source with
  | None -> 0
  | Some dir ->
    match classify_store_dir source ~site:"count_fixed_source_entries_dir" dir with
    | Store_missing | Store_invalid -> 0
    | Store_directory ->
      (match Dated_jsonl.create ~base_dir:dir () with
       | store -> Dated_jsonl.count_entries store
       | exception (Eio.Cancel.Cancelled _ as e) -> raise e
       | exception exn ->
         observe_source_read_failure_exn source
           ~site:"count_fixed_source_entries" exn;
         Log.Telemetry.warn "count_source_entries: %s store open failed"
           (source_to_string source);
         0)

let execution_receipt_summary_stats ~masc_root =
  discover_execution_receipt_dirs masc_root
  |> List.fold_left
       (fun (count_acc, latest_acc) (_name, dir) ->
         match Dated_jsonl.create ~base_dir:dir () with
         | store ->
           let count = Dated_jsonl.count_entries store in
           let latest = latest_store_ts Execution_receipt dir "execution_receipt" in
           ( count_acc + count,
             match latest with
             | Some ts -> max_ts_opt latest_acc ts
             | None -> latest_acc )
         | exception (Eio.Cancel.Cancelled _ as e) -> raise e
         | exception exn ->
           observe_source_read_failure_exn Execution_receipt
             ~site:"execution_receipt_summary_stats" exn;
           Log.Telemetry.warn
             "execution_receipt_summary_stats: store open failed for %s" dir;
           (count_acc, latest_acc))
       (0, None)

(* Per-trace-file incremental summary cache for the snapshot loop.

   The 2 s [Dashboard_snapshot.refresh_loop] calls [summary_json] on every
   cycle; until 2026-06-10 this path tail-re-parsed every trace file in
   every keeper dir (~480 MB store) through Yojson on each cycle, pegging
   Executor_pool worker domains from boot — the measured CPU burn behind
   the 16-keeper fleet freeze (capture:
   .tmp/masc-freeze-captures/20260610-094442).

   Trace files are append-only whole-line JSONL, so (tool-call count,
   latest tool-call ts) up to a byte boundary is a pure function of the
   file prefix: closed trace files hit the cache forever and the live
   trace file re-parses only the bytes appended since the previous cycle.
   A boundary past the current size (rotation/manual edit) rescans from
   byte 0. Entries for deleted files are dropped on the next readdir pass
   that no longer lists them only via rescan-from-zero semantics; the
   residual map entry costs one small record per departed path. *)
type trajectory_file_summary =
  { tfs_boundary : int
  ; tfs_tool_calls : int
  ; tfs_latest_ts : float option
  }

let trajectory_summary_cache : (string, trajectory_file_summary) Hashtbl.t =
  Hashtbl.create 64

let trajectory_summary_cache_mu = Stdlib.Mutex.create ()

let reset_trajectory_summary_cache_for_testing () =
  Stdlib.Mutex.protect trajectory_summary_cache_mu (fun () ->
    Hashtbl.reset trajectory_summary_cache)

let trajectory_file_summary path : trajectory_file_summary option =
  match Unix.stat path with
  | exception (Unix.Unix_error _ | Sys_error _) -> None
  | st ->
    let size = st.Unix.st_size in
    let cached =
      Stdlib.Mutex.protect trajectory_summary_cache_mu (fun () ->
        Hashtbl.find_opt trajectory_summary_cache path)
    in
    (match cached with
     | Some e when e.tfs_boundary = size -> Some e
     | cached ->
       let from, count0, latest0 =
         match cached with
         | Some e when e.tfs_boundary < size ->
           e.tfs_boundary, e.tfs_tool_calls, e.tfs_latest_ts
         | Some _ ->
           (* boundary past the file size: shrink/rotation — full re-parse *)
           Otel_metric_store_core.inc_counter
             Otel_builtin_metric_names.metric_telemetry_cache_rescans
             ~labels:[ ("store", "trajectories") ]
             ();
           0, 0, None
         | None -> 0, 0, None
       in
       let (count, latest), boundary =
         Fs_compat.fold_appended_lines ~path ~from ~init:(count0, latest0)
           ~f:(fun (count, latest) line ->
             match Yojson.Safe.from_string line with
             | exception Yojson.Json_error _ -> count, latest
             | json ->
               if trajectory_tool_call_json json
               then begin
                 let latest =
                   match extract_ts json with
                   | ts when ts > 0.0 -> max_ts_opt latest ts
                   | _ -> latest
                 in
                 count + 1, latest
               end
               else count, latest)
       in
       Otel_metric_store_core.inc_counter
         Otel_builtin_metric_names.metric_telemetry_scanned_bytes
         ~labels:[ ("store", "trajectories") ]
         ~delta:(Float.of_int (max 0 (boundary - from)))
         ();
       let entry =
         { tfs_boundary = boundary; tfs_tool_calls = count; tfs_latest_ts = latest }
       in
       Stdlib.Mutex.protect trajectory_summary_cache_mu (fun () ->
         Hashtbl.replace trajectory_summary_cache path entry);
       Some entry)

let trajectory_tool_call_summary_stats ~masc_root =
  discover_trajectory_keeper_dirs masc_root
  |> List.fold_left
       (fun (count_acc, latest_acc) (_name, dir) ->
         protect_source_read Trajectory_tool_call
           ~site:"trajectory_tool_call_summary_readdir"
           ~default:(count_acc, latest_acc)
           (fun () ->
             if not (Sys.file_exists dir) then (count_acc, latest_acc)
             else
               Sys.readdir dir
               |> Array.to_list
               |> List.filter (fun name -> Filename.check_suffix name ".jsonl")
               |> List.fold_left
                    (fun (count_acc, latest_acc) name ->
                      match
                        trajectory_file_summary (Filename.concat dir name)
                      with
                      | None -> count_acc, latest_acc
                      | Some s ->
                        ( count_acc + s.tfs_tool_calls,
                          match s.tfs_latest_ts with
                          | Some ts -> max_ts_opt latest_acc ts
                          | None -> latest_acc ))
                    (count_acc, latest_acc)))
       (0, None)

let summary_json ~base_path ~masc_root () : Yojson.Safe.t =
  let now = Unix.gettimeofday () in
  let coverage_gaps = Telemetry_coverage_gap.read_recent ~masc_root ~n:50 in
  let keeper_dirs = discover_keeper_metric_dirs masc_root in
  let keeper_total =
    List.fold_left (fun acc (name, dir) ->
      acc +
      (match Dated_jsonl.create ~base_dir:dir () with
       | store -> Dated_jsonl.count_entries store
       | exception (Eio.Cancel.Cancelled _ as e) -> raise e
       | exception exn ->
         observe_source_read_failure_exn Keeper_metric
           ~site:"summary_keeper_count" exn;
         Log.Telemetry.warn "summary_json: keeper %s store open failed" name;
         0)
    ) 0 keeper_dirs
  in
  let keeper_latest_ts =
    List.fold_left
      (fun acc (name, dir) ->
        match
          latest_store_ts Keeper_metric dir (Printf.sprintf "keeper %s" name)
        with
        | Some ts -> max_ts_opt acc ts
        | None -> acc)
      None keeper_dirs
  in
  let source_json_and_count source =
    let freshness_slo_s = source_freshness_slo_s source in
    let metadata_fields = source_metadata_fields ~base_path ~masc_root source in
    let keeper_dir_fields dirs =
      [
        ( "keepers",
          `List
            (List.map
               (fun (name, dir) ->
                 `Assoc [ ("name", `String name); ("path", `String dir) ])
               dirs) );
        ("keeper_count", `Int (List.length dirs));
      ]
    in
    match source with
    | Keeper_metric ->
      let exists = keeper_dirs <> [] in
      let coverage_gap_fields, coverage_gap =
        coverage_gap_status_fields coverage_gaps source
          ~latest_ts:keeper_latest_ts
      in
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
          @ metadata_fields
          @ coverage_gap_fields
          @ freshness_fields ~now keeper_latest_ts
          @ source_health_fields ~now ~exists ~entry_count:keeper_total
              ~latest_ts:keeper_latest_ts ~freshness_slo_s
              ~optional_when_missing:(source_optional_when_missing source)
              ?coverage_gap ()),
        keeper_total )
    | Trajectory_tool_call ->
      let trajectories_root = Filename.concat masc_root "trajectories" in
      let dir_state =
        classify_store_dir Trajectory_tool_call
          ~site:"summary_trajectory_root" trajectories_root
      in
      let dirs =
        match dir_state with
        | Store_directory ->
            discover_trajectory_keeper_dirs_in_root trajectories_root
        | Store_missing | Store_invalid -> []
      in
      let exists = match dir_state with
        | Store_directory | Store_invalid -> true
        | Store_missing -> false
      in
      let read_error = match dir_state with
        | Store_invalid -> true
        | Store_missing | Store_directory -> false
      in
      let count, latest_ts =
        if dir_state = Store_directory then trajectory_tool_call_summary_stats ~masc_root
        else (0, None)
      in
      let coverage_gap_fields, coverage_gap =
        coverage_gap_status_fields coverage_gaps source ~latest_ts
      in
      ( `Assoc
          ([
             ("source", `String (source_to_string source));
             ("path", `String trajectories_root);
             ("exists", `Bool exists);
             ("entry_count", `Int count);
          ]
          @ keeper_dir_fields dirs
          @ metadata_fields
          @ coverage_gap_fields
          @ freshness_fields ~now latest_ts
          @ source_health_fields ~now ~exists ~entry_count:count ~latest_ts
              ~freshness_slo_s
              ~optional_when_missing:(source_optional_when_missing source)
              ~read_error ?coverage_gap ()),
        count )
    | Execution_receipt ->
      let keepers_root = Filename.concat masc_root "keepers" in
      let dirs = discover_execution_receipt_dirs masc_root in
      let dir_state =
        classify_store_dir Execution_receipt
          ~site:"summary_execution_receipt_root" keepers_root
      in
      let exists = match dir_state with
        | Store_directory | Store_invalid -> true
        | Store_missing -> false
      in
      let read_error = match dir_state with
        | Store_invalid -> true
        | Store_missing | Store_directory -> false
      in
      let count, latest_ts =
        if dir_state = Store_directory then execution_receipt_summary_stats ~masc_root
        else (0, None)
      in
      let coverage_gap_fields, coverage_gap =
        coverage_gap_status_fields coverage_gaps source ~latest_ts
      in
      ( `Assoc
          ([
             ("source", `String (source_to_string source));
             ("path", `String (Filename.concat keepers_root "*/execution-receipts"));
             ("exists", `Bool exists);
             ("entry_count", `Int count);
          ]
          @ keeper_dir_fields dirs
          @ metadata_fields
          @ coverage_gap_fields
          @ freshness_fields ~now latest_ts
          @ source_health_fields ~now ~exists ~entry_count:count ~latest_ts
              ~freshness_slo_s
              ~optional_when_missing:(source_optional_when_missing source)
              ~read_error ?coverage_gap ()),
        count )
    (* Fixed-path sources: Agent_event, Tool_call_io, Tool_usage,
       Oas_event, Tool_metric use directory-based storage. *)
    | Agent_event | Tool_call_io | Tool_usage | Oas_event | Tool_metric ->
      let dir = match fixed_store_dir ~masc_root ~base_path source with
        | Some d -> d | None -> "" in
      let dir_state =
        if dir = "" then Store_missing
        else classify_store_dir source ~site:"summary_fixed_source_dir" dir
      in
      let exists = match dir_state with
        | Store_directory | Store_invalid -> true
        | Store_missing -> false
      in
      let read_error = match dir_state with
        | Store_invalid -> true
        | Store_missing | Store_directory -> false
      in
      let count =
        if dir_state = Store_directory then
          count_fixed_source_entries ~masc_root ~base_path source
        else 0
      in
      let latest_ts =
        if dir_state = Store_directory then
          latest_store_ts source dir (source_to_string source)
        else None
      in
      let coverage_gap_fields, coverage_gap =
        coverage_gap_status_fields coverage_gaps source ~latest_ts
      in
      ( `Assoc
          ([
             ("source", `String (source_to_string source));
             ("path", `String dir);
             ("exists", `Bool exists);
             ("entry_count", `Int count);
          ]
          @ metadata_fields
          @ coverage_gap_fields
          @ freshness_fields ~now latest_ts
          @ source_health_fields ~now ~exists ~entry_count:count ~latest_ts
              ~freshness_slo_s
              ~optional_when_missing:(source_optional_when_missing source)
              ~read_error ?coverage_gap ()),
        count )
  in
  let source_summaries = List.map source_json_and_count all_sources in
  let total_entries =
    List.fold_left (fun acc (_json, count) -> acc + count) 0 source_summaries
  in
  `Assoc [
    ("generated_at", `String (Masc_domain.now_iso ()));
    ("sources", `List (List.map fst source_summaries));
    ("coverage_gaps", `List coverage_gaps);
    ("total_entries", `Int total_entries);
  ]

module For_testing = struct
  let trajectory_tool_call_summary_stats = trajectory_tool_call_summary_stats

  let reset_trajectory_summary_cache_for_testing =
    reset_trajectory_summary_cache_for_testing
end
