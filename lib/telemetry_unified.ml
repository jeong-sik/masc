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
    - [<masc_root>/tool_usage/]              — System_internal surface tool calls
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
  | Goal_event
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

let take_first n entries =
  if n <= 0 then []
  else List.filteri (fun i _ -> i < n) entries

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
      (* [optional_when_missing] callers (Goal_event, which only materialises
         after the first goal verification) have a legitimate "file does not
         exist yet" state. Reporting that as a red [missing] alarm creates
         dashboard fatigue; report a neutral [not_yet] with an explanatory
         reason instead. Real write failures still surface via [coverage_gap]
         regardless of this flag. *)
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

let source_optional_when_missing = function
  | Goal_event -> true
  | Keeper_metric | Agent_event | Tool_call_io | Trajectory_tool_call
  | Tool_usage | Oas_event | Execution_receipt | Tool_metric -> false

let latest_coverage_gap_for_source gaps source =
  let source_name = source_to_string source in
  gaps
  |> List.rev
  |> List.find_opt (fun gap ->
       String.equal
         (Safe_ops.json_string ~default:"" "source" gap)
         source_name)

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

let agent_tool_called_signature json =
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

let suppress_shadow_agent_tool_events entries =
  let tool_call_io =
    List.filter_map tool_call_io_signature entries
  in
  if tool_call_io = [] then entries
  else
    List.filter
      (fun json ->
        match agent_tool_called_signature json with
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

let promote_agent_tool_called_scope source fields =
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
    let fields = promote_agent_tool_called_scope source fields in
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

let read_fixed_source dir source ~n ?since_ts ?until_ts () : Yojson.Safe.t list =
  match classify_store_dir source ~site:"read_fixed_source_dir" dir with
  | Store_missing | Store_invalid -> []
  | Store_directory ->
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

let dated_jsonl_entries store ~n ?since_ts ?until_ts () =
  let entries =
    match effective_day_window ?since_ts ?until_ts () with
    | Some (since_day, until_day) ->
        Dated_jsonl.read_range store ~since:since_day ~until:until_day
    | None when n <= 0 ->
        let until_ts = Unix.gettimeofday () in
        let since_day = "1970-01-01" in
        let until_day = day_string_of_unix_seconds until_ts in
        Dated_jsonl.read_range store ~since:since_day ~until:until_day
    | None -> Dated_jsonl.read_recent store n
  in
  List.filter (within_requested_window ?since_ts ?until_ts) entries

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

let read_trajectory_file path ?since_ts ?until_ts () =
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
        Fs_compat.load_file path
        |> String.split_on_char '\n'
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

let read_trajectory_tool_calls ~masc_root ?keeper_name ?since_ts ?until_ts ~n ()
    : Yojson.Safe.t list =
  let dirs = discover_trajectory_keeper_dirs masc_root in
  let dirs =
    match keeper_name with
    | None -> dirs
    | Some name -> List.filter (fun (k, _) -> String.equal k name) dirs
  in
  let entries =
    List.concat_map
      (fun (_name, dir) ->
        protect_source_read Trajectory_tool_call
          ~site:"read_trajectory_tool_calls_readdir" ~default:[] (fun () ->
          Sys.readdir dir
          |> Array.to_list
          |> List.filter (fun name -> Filename.check_suffix name ".jsonl")
          |> List.concat_map (fun name ->
               read_trajectory_file
                 (Filename.concat dir name)
                 ?since_ts ?until_ts ())))
      dirs
  in
  let entries = sort_newest_first entries in
  let entries = if n <= 0 then entries else take_first n entries in
  List.map (tag_entry Trajectory_tool_call) entries

let goal_events_path ~masc_root =
  Filename.concat masc_root "goal_events.jsonl"

let read_goal_events ~masc_root ?since_ts ?until_ts ~n () : Yojson.Safe.t list =
  let path = goal_events_path ~masc_root in
  if not (Sys.file_exists path) then []
  else
    let entries =
      protect_source_read Goal_event ~site:"read_goal_events" ~default:[]
        (fun () ->
          (* Streaming filter — the time-window predicate drops most
             entries on the typical {since_ts,until_ts} request shape,
             so folding lets us hold only the survivors instead of the
             full goal_events.jsonl content. The subsequent sort still
             needs the filtered set in memory; that part can't stream. *)
          Fs_compat.fold_jsonl_lines
            ~init:[]
            ~f:(fun acc ~line_no:_ json ->
              if within_requested_window ?since_ts ?until_ts json
              then json :: acc
              else acc)
            path
          |> List.rev)
    in
    let entries = sort_newest_first entries in
    let entries = if n <= 0 then entries else take_first n entries in
    List.map (tag_entry Goal_event) entries

(* ── Unified read ───────────────────────────────────── *)

let read_unified_result ~base_path ~masc_root ?(sources = all_sources)
    ?keeper_name ?session_id ?operation_id ?worker_run_id ?since_ts ?until_ts
    ?(n = 100) () : read_result =
  let limited = n > 0 in
  let has_filter =
    Option.is_some keeper_name || Option.is_some session_id
    || Option.is_some operation_id || Option.is_some worker_run_id
    || Option.is_some since_ts || Option.is_some until_ts
  in
  let per_source =
    if not limited then 0
    else if has_filter then max n (n * 2)
    else n + 1
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
      | Goal_event ->
        read_goal_events ~masc_root ?since_ts ?until_ts ~n:per_source ()
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
  let filtered =
    if List.mem Agent_event sources && List.mem Tool_call_io sources then
      suppress_shadow_agent_tool_events filtered
    else filtered
  in
  (* Sort by timestamp descending (newest first) *)
  let sorted = sort_newest_first filtered in
  let total_matching_entries = List.length sorted in
  let entries =
    if not limited || total_matching_entries <= n then sorted
    else take_first n sorted
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

let trajectory_tool_call_summary_stats ~masc_root =
  discover_trajectory_keeper_dirs masc_root
  |> List.fold_left
       (fun (count_acc, latest_acc) (_name, dir) ->
         let entries =
           protect_source_read Trajectory_tool_call
             ~site:"trajectory_tool_call_summary_readdir" ~default:[]
             (fun () ->
             if not (Sys.file_exists dir) then []
             else Sys.readdir dir
             |> Array.to_list
             |> List.filter (fun name -> Filename.check_suffix name ".jsonl")
             |> List.concat_map (fun name ->
                  read_trajectory_file (Filename.concat dir name) ()))
         in
         ( count_acc + List.length entries,
           match latest_ts_of_entries entries with
           | Some ts -> max_ts_opt latest_acc ts
           | None -> latest_acc ))
       (0, None)

let goal_event_summary_stats ~masc_root =
  let path = goal_events_path ~masc_root in
  if not (Sys.file_exists path) then (0, None)
  else
    let entries =
      protect_source_read Goal_event ~site:"goal_event_summary_stats"
        ~default:[] (fun () -> Fs_compat.load_jsonl path)
    in
    (List.length entries, latest_ts_of_entries entries)

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
    let coverage_gap = latest_coverage_gap_for_source coverage_gaps source in
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
      ( `Assoc
          ([
             ("source", `String (source_to_string source));
             ("path", `String trajectories_root);
             ("exists", `Bool exists);
             ("entry_count", `Int count);
           ]
          @ keeper_dir_fields dirs
          @ metadata_fields
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
      ( `Assoc
          ([
             ("source", `String (source_to_string source));
             ("path", `String (Filename.concat keepers_root "*/execution-receipts"));
             ("exists", `Bool exists);
             ("entry_count", `Int count);
           ]
          @ keeper_dir_fields dirs
          @ metadata_fields
          @ freshness_fields ~now latest_ts
          @ source_health_fields ~now ~exists ~entry_count:count ~latest_ts
              ~freshness_slo_s
              ~optional_when_missing:(source_optional_when_missing source)
              ~read_error ?coverage_gap ()),
        count )
    | Goal_event ->
      let path = goal_events_path ~masc_root in
      let exists = Sys.file_exists path in
      let count, latest_ts =
        if exists then goal_event_summary_stats ~masc_root
        else (0, None)
      in
      ( `Assoc
          ([
             ("source", `String (source_to_string source));
             ("path", `String path);
             ("exists", `Bool exists);
             ("entry_count", `Int count);
           ]
          @ metadata_fields
          @ freshness_fields ~now latest_ts
          @ source_health_fields ~now ~exists ~entry_count:count ~latest_ts
              ~freshness_slo_s
              ~optional_when_missing:(source_optional_when_missing source)
              ?coverage_gap ()),
        count )
    | _ ->
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
      ( `Assoc
          ([
             ("source", `String (source_to_string source));
             ("path", `String dir);
             ("exists", `Bool exists);
             ("entry_count", `Int count);
           ]
          @ metadata_fields
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
