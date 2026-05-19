open Dashboard_http_helpers
open Dashboard_http_keeper_types

(** Per-keeper cost/latency aggregates for the O4 cost dashboard.

    Reads each keeper's metrics JSONL, extracts cost_usd / latency_ms /
    token fields, and returns per-keeper totals plus p50/p95 latency
    percentiles and a redacted runtime cost breakdown.

    This closes the Phase-2 gap between runtime metrics (already in
    /api/v1/models/metrics) and per-agent spend (required by preview). *)
let keeper_cost_aggregates_json
    ~(config : Coord.config)
    ~(keepers : Keeper_types.keeper_meta list)
    ~(window_minutes : int)
  : Yojson.Safe.t =
  let now_ts = Unix.gettimeofday () in
  let window_sec = float_of_int window_minutes *. 60.0 in
  let start_ts = now_ts -. window_sec in
  let keeper_items =
    List.map
      (fun (m : Keeper_types.keeper_meta) ->
        let metrics_store = Keeper_types.keeper_metrics_store config m.name in
        let all_metrics_lines =
          let dated = Dated_jsonl.read_recent_lines metrics_store 500 in
          if dated <> []
          then dated
          else (
            let metrics_path = Keeper_types.keeper_metrics_path config m.name in
            Keeper_memory.read_file_tail_lines
              metrics_path
              ~max_bytes:200000
              ~max_lines:500)
        in
        let costs_rev = ref [] in
        let latencies_rev = ref [] in
        let input_tokens = ref 0 in
        let output_tokens = ref 0 in
        let total_tokens = ref 0 in
        let runtime_costs : (string, float) Hashtbl.t = Hashtbl.create 8 in
        let sample_count = ref 0 in
        List.iter
          (fun line ->
            try
              let j = Yojson.Safe.from_string line in
              let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
              if ts_unix >= start_ts
              then (
                let cost =
                  match Safe_ops.json_float_opt "cost_usd" j with
                  | Some value -> value
                  | None -> 0.0
                in
                let latency_ms = Safe_ops.json_int ~default:0 "latency_ms" j in
                let input_t =
                  match int_member_fallback "input_tokens" j with
                  | Some value -> value
                  | None -> 0
                in
                let output_t =
                  match int_member_fallback "output_tokens" j with
                  | Some value -> value
                  | None -> 0
                in
                let total_t =
                  match int_member_fallback "total_tokens" j with
                  | Some value -> value
                  | None -> 0
                in
                if keeper_cost_metric_row_is_event j && (cost > 0.0 || latency_ms > 0)
                then (
                  costs_rev := cost :: !costs_rev;
                  latencies_rev := float_of_int latency_ms :: !latencies_rev;
                  input_tokens := !input_tokens + input_t;
                  output_tokens := !output_tokens + output_t;
                  total_tokens := !total_tokens + total_t;
                  let prev =
                    Option.value
                      ~default:0.0
                      (Hashtbl.find_opt runtime_costs "runtime")
                  in
                  Hashtbl.replace runtime_costs "runtime" (prev +. cost);
                  incr sample_count))
            with
            | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> ())
          all_metrics_lines;
        let total_cost = List.fold_left ( +. ) 0.0 !costs_rev in
        let latency_arr =
          let arr = Array.of_list !latencies_rev in
          Array.sort Float.compare arr;
          arr
        in
        let p50_latency =
          if Array.length latency_arr = 0
          then None
          else Some (percentile_sorted_float latency_arr 50.0)
        in
        let p95_latency =
          if Array.length latency_arr = 0
          then None
          else Some (percentile_sorted_float latency_arr 95.0)
        in
        let runtime_breakdown_json =
          runtime_costs
          |> Hashtbl.to_seq
          |> List.of_seq
          |> List.sort (fun (_, ca) (_, cb) -> Float.compare cb ca)
          |> List.map (fun (model, cost) ->
            `Assoc [ "model", `String model; "cost_usd", `Float cost ])
        in
        `Assoc
          [ "keeper_name", `String m.name
          ; "total_cost_usd", `Float total_cost
          ; "total_input_tokens", `Int !input_tokens
          ; "total_output_tokens", `Int !output_tokens
          ; "total_tokens", `Int !total_tokens
          ; "p50_latency_ms", Json_util.float_opt_to_json p50_latency
          ; "p95_latency_ms", Json_util.float_opt_to_json p95_latency
          ; "sample_count", `Int !sample_count
          ; "model_breakdown", `List runtime_breakdown_json
          ])
      keepers
  in
  `Assoc
    [ "keepers", `List keeper_items
    ; "window_minutes", `Int window_minutes
    ; "generated_at", `Float now_ts
    ]
;;

(** Read per-keeper [.decisions.jsonl] files and return a unified,
    time-sorted stream of recent events (turn telemetry, tool_exec,
    memory_search, etc.).  Each event is normalized to a flat record so
    the dashboard can render a single chronology without knowing the
    original schema variants. *)
let keeper_decisions_json
    ~(config : Coord.config)
    ~(keepers : Keeper_types.keeper_meta list)
    ?(limit = 200)
    ()
  : Yojson.Safe.t =
  let limit = k2_feed_limit limit in
  let per_keeper_limit = limit * 2 in
  let all_events =
    List.concat_map
      (fun (m : Keeper_types.keeper_meta) ->
        let path = Keeper_types.keeper_decision_log_path config m.name in
        if not (Fs_compat.file_exists path)
        then []
        else (
          let lines =
            Keeper_memory.read_file_tail_lines
              path
              ~max_bytes:500_000
              ~max_lines:per_keeper_limit
          in
          List.filter_map
            (fun line ->
              try
                let json = Yojson.Safe.from_string line in
                let ts =
                  match Yojson.Safe.Util.member "ts_unix" json with
                  | `Float f -> f
                  | `Int i -> float_of_int i
                  | _ -> 0.0
                in
                let event_type =
                  match Yojson.Safe.Util.member "event" json with
                  | `String s -> s
                  | _ -> "turn"
                in
                let keeper_name =
                  match Yojson.Safe.Util.member "keeper_name" json with
                  | `String s -> s
                  | _ -> m.name
                in
                Some (ts, json, event_type, keeper_name)
              with
              | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None)
            lines))
      keepers
  in
  let sorted = List.sort (fun (ta, _, _, _) (tb, _, _, _) -> compare tb ta) all_events in
  let rec take n = function
    | [] -> []
    | _ when n <= 0 -> []
    | x :: xs -> x :: take (n - 1) xs
  in
  let top = take limit sorted in
  let items =
    List.map
      (fun (_ts, json, event_type, keeper_name) ->
        let m = Yojson.Safe.Util.member in
        let string_member_opt key source =
          match m key source with
          | `String s ->
            let trimmed = String.trim s in
            if String.equal trimmed "" then None else Some trimmed
          | _ -> None
        in
        let string_or_null key =
          match string_member_opt key json with
          | Some value -> `String value
          | None -> `Null
        in
        let float_or_null key =
          match m key json with
          | `Float f -> `Float f
          | `Int i -> `Float (float_of_int i)
          | _ -> `Null
        in
        let int_or_null key =
          match m key json with
          | `Int i -> `Int i
          | `Float f -> `Int (int_of_float f)
          | _ -> `Null
        in
        let int_member_opt key source =
          match m key source with
          | `Int value -> Some value
          | `Float value when Float.is_finite value -> Some (int_of_float value)
          | _ -> None
        in
        let first_string_or_null keys =
          match List.find_map (fun key -> string_member_opt key json) keys with
          | Some value -> `String value
          | None -> `Null
        in
        let context_json =
          let source =
            match m "context" json with
            | `Assoc _ as context -> context
            | _ -> json
          in
          let add_string key acc =
            match string_member_opt key source with
            | Some value -> (key, `String value) :: acc
            | None -> acc
          in
          let fields =
            []
            |> add_string "file_path"
            |> add_string "goal_id"
            |> add_string "task_id"
            |> add_string "board_post_id"
            |> add_string "comment_id"
            |> add_string "pr_id"
            |> add_string "git_ref"
            |> add_string "log_id"
            |> add_string "session_id"
            |> add_string "operation_id"
            |> add_string "worker_run_id"
          in
          let fields =
            match int_member_opt "line" source, int_member_opt "line_start" source with
            | Some line, _ -> ("line", `Int line) :: fields
            | None, Some line -> ("line", `Int line) :: fields
            | None, None -> fields
          in
          match List.rev fields with
          | [] -> `Null
          | fields -> `Assoc fields
        in
        let duration_ms =
          match float_or_null "duration_ms" with
          | `Null -> float_or_null "latency_ms"
          | value -> value
        in
        let terminal_reason_code =
          match terminal_reason_code_of_decision_json json with
          | Some value -> `String value
          | None -> `Null
        in
        `Assoc
          [ "ts_unix", float_or_null "ts_unix"
          ; "keeper_name", `String keeper_name
          ; "event_type", `String event_type
          ; "outcome", string_or_null "outcome"
          ; "terminal_reason_code", terminal_reason_code
          ; ( "choice"
            , first_string_or_null
                [ "choice"; "decision"; "selected"; "selected_tool"; "action" ] )
          ; "reason", first_string_or_null [ "reason"; "rationale"; "why" ]
          ; "context", context_json
          ; "model_used", `Null
          ; "latency_ms", float_or_null "latency_ms"
          ; "cost_usd", float_or_null "cost_usd"
          ; "input_tokens", int_or_null "input_tokens"
          ; "output_tokens", int_or_null "output_tokens"
          ; "stop_reason", string_or_null "stop_reason"
          ; "error_category", string_or_null "error_category"
          ; "tool", string_or_null "tool"
          ; "duration_ms", duration_ms
          ; "match_count", int_or_null "match_count"
          ])
      top
  in
  `Assoc
    [ "dashboard_surface", `String keeper_decisions_dashboard_surface
    ; "source", `String "keeper_decision_log"
    ; ( "retention"
      , keeper_decisions_retention_json
          ~per_keeper_limit
          ~keeper_count:(List.length keepers) )
    ; "events", `List items
    ; "limit", `Int limit
    (* NDT-OK: K2 feed metadata is an observation timestamp only; sorting and
       event identity use parsed event timestamps above. *)
    ; "generated_at", `Float (Unix.gettimeofday ())
    ; "generated_at_iso", `String (Masc_domain.now_iso ())
    ]
;;

let keeper_decisions_log_json
    ~(config : Coord.config)
    ~(keepers : Keeper_types.keeper_meta list)
    ?(limit = 200)
    ()
  : Yojson.Safe.t =
  let limit = k2_feed_limit limit in
  let per_keeper_limit = limit * 2 in
  let all_events =
    List.concat_map
      (fun (m : Keeper_types.keeper_meta) ->
        let path = Keeper_types.keeper_decision_log_path config m.name in
        if not (Fs_compat.file_exists path)
        then []
        else (
          let lines =
            Keeper_memory.read_file_tail_lines
              path
              ~max_bytes:500_000
              ~max_lines:per_keeper_limit
          in
          List.filter_map
            (fun line ->
              try
                let json = Yojson.Safe.from_string line in
                let str key =
                  match Yojson.Safe.Util.member key json with
                  | `String s -> s
                  | _ -> ""
                in
                let ts_unix =
                  match Yojson.Safe.Util.member "ts_unix" json with
                  | `Float f -> f
                  | `Int i -> float_of_int i
                  | _ -> 0.0
                in
                let keeper_name =
                  let raw = str "keeper_name" in
                  if raw = "" then m.name else raw
                in
                let id =
                  let raw = str "id" in
                  if raw <> ""
                  then raw
                  else k2_stable_id ~prefix:"dec" ~keeper_name ~ts_unix ~raw:line
                in
                let ts =
                  let raw = str "ts" in
                  if raw <> "" then raw else k2_iso8601_of_unix ts_unix
                in
                let decision_type =
                  let sa = str "speech_act" in
                  if sa <> ""
                  then sa
                  else (
                    let outcome = str "outcome" in
                    if outcome <> "" then outcome else "turn")
                in
                let terminal_reason_code = terminal_reason_code_of_decision_json json in
                let duration_ms =
                  let number key =
                    match Yojson.Safe.Util.member key json with
                    | `Float value -> Some value
                    | `Int value -> Some (float_of_int value)
                    | _ -> None
                  in
                  match number "duration_ms" with
                  | Some _ as value -> value
                  | None -> number "latency_ms"
                in
                let belief_summary = str "belief_summary" in
                let current_intention = str "current_intention" in
                let blocker = str "blocker" in
                let channel = str "channel" in
                let summary_parts =
                  List.filter
                    (fun s -> s <> "")
                    [ decision_type
                    ; (if channel <> "" then "via " ^ channel else "")
                    ; (match terminal_reason_code with
                       | Some code -> "reason: " ^ code
                       | None -> "")
                    ; (if current_intention <> "" then "\xe2\x86\x92 " ^ current_intention else "")
                    ; (if blocker <> "" then "blocked: " ^ blocker else "")
                    ; (if belief_summary <> "" then belief_summary else "")
                    ]
                in
                let summary = String.concat " \xc2\xb7 " summary_parts in
                let evidence_refs =
                  let refs = json_string_list_member "evidence_refs" json in
                  let refs =
                    if refs <> []
                    then refs
                    else json_string_list_member "raw_evidence_refs" json
                  in
                  List.map (fun value -> `String value) refs
                in
                Some
                  ( ts_unix
                  , `Assoc
                      [ "id", `String id
                      ; "ts", `String ts
                      ; "ts_unix", `Float ts_unix
                      ; "keeper", `String keeper_name
                      ; "decision_type", `String decision_type
                      ; "summary", `String summary
                      ; ( "terminal_reason_code"
                        , match terminal_reason_code with
                          | Some code -> `String code
                          | None -> `Null )
                      ; ( "duration_ms"
                        , match duration_ms with
                          | Some value -> `Float value
                          | None -> `Null )
                      ; "evidence_refs", `List evidence_refs
                      ] )
              with
              | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None)
            lines))
      keepers
  in
  let sorted = List.sort (fun (ta, _) (tb, _) -> compare tb ta) all_events in
  let rec take n = function
    | [] -> []
    | _ when n <= 0 -> []
    | x :: xs -> x :: take (n - 1) xs
  in
  let items = List.map snd (take limit sorted) in
  `Assoc
    [ "events", `List items
    ; "limit", `Int limit
    (* NDT-OK: decision-log feed metadata is wall-clock freshness only;
       event ordering uses per-row ts_unix values. *)
    ; "generated_at", `Float (Unix.gettimeofday ())
    ]
;;

let keeper_memory_log_json
    ~(config : Coord.config)
    ~(keepers : Keeper_types.keeper_meta list)
    ?(limit = 200)
    ()
  : Yojson.Safe.t =
  let limit = k2_feed_limit limit in
  let per_keeper_limit = limit * 2 in
  let all_entries =
    List.concat_map
      (fun (m : Keeper_types.keeper_meta) ->
        let path = Keeper_types.keeper_memory_bank_path config m.name in
        if not (Fs_compat.file_exists path)
        then []
        else (
          let lines =
            Keeper_memory.read_file_tail_lines
              path
              ~max_bytes:500_000
              ~max_lines:per_keeper_limit
          in
          List.filter_map
            (fun line ->
              match Keeper_memory.parse_memory_bank_row line with
              | None -> None
              | Some (row : Keeper_memory.keeper_memory_row_raw) ->
                let kind = memory_kind_for_log row.kind in
                let ts = k2_iso8601_of_unix row.ts_unix in
                let id =
                  k2_stable_id
                    ~prefix:"mem"
                    ~keeper_name:m.name
                    ~ts_unix:row.ts_unix
                    ~raw:line
                in
                Some
                  ( row.ts_unix
                  , `Assoc
                      [ "id", `String id
                      ; "ts", `String ts
                      ; "ts_unix", `Float row.ts_unix
                      ; "keeper", `String m.name
                      ; "kind", `String kind
                      ; "summary", `String row.text
                      ] ))
            lines))
      keepers
  in
  let sorted = List.sort (fun (ta, _) (tb, _) -> compare tb ta) all_entries in
  let rec take n = function
    | [] -> []
    | _ when n <= 0 -> []
    | x :: xs -> x :: take (n - 1) xs
  in
  let items = List.map snd (take limit sorted) in
  `Assoc
    [ "entries", `List items
    ; "limit", `Int limit
    (* NDT-OK: memory-log feed metadata is wall-clock freshness only;
       entry ordering uses per-row ts_unix values. *)
    ; "generated_at", `Float (Unix.gettimeofday ())
    ]
;;
