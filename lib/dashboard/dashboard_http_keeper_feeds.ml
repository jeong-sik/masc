open Dashboard_http_keeper_types

(* What one turn row says about a value the runtime may or may not report.
   [Unreported] is the row's explicit [null]: the runtime gave no value
   (subscription runtimes give no cost; some give no usage). [Unread] is a
   row whose field is missing or has a shape the writer never produces. The
   three stay apart so an unknown value never reads as 0. *)
type 'a reading =
  | Reported of 'a
  | Unreported
  | Unread

type token_counts =
  { input : int
  ; output : int
  ; total : int
  }

let cost_reading_of_row json =
  match Json_util.assoc_member_opt "cost_usd" json with
  | Some (`Float value) when Float.is_finite value && value >= 0.0 -> Reported value
  | Some (`Int value) when value >= 0 -> Reported (float_of_int value)
  | Some `Null -> Unreported
  | Some _
  | None -> Unread

(* The writer ([Keeper_unified_metrics_snapshot]) puts either three integers
   or three [null]s in [usage]; any other shape is unread. *)
let token_reading_of_row json =
  match Json_util.assoc_member_opt "usage" json with
  | Some (`Assoc _ as usage) ->
      (match
         Json_util.assoc_member_opt "input_tokens" usage,
         Json_util.assoc_member_opt "output_tokens" usage,
         Json_util.assoc_member_opt "total_tokens" usage
       with
       | Some (`Int input), Some (`Int output), Some (`Int total)
         when input >= 0 && output >= 0 && total >= 0 ->
           Reported { input; output; total }
       | Some `Null, Some `Null, Some `Null -> Unreported
       | _ -> Unread)
  | Some _
  | None -> Unread

type 'a tally =
  { mutable reported : 'a
  ; mutable reported_samples : int
  ; mutable unreported_samples : int
  ; mutable unread_samples : int
  }

let empty_tally zero =
  { reported = zero; reported_samples = 0; unreported_samples = 0; unread_samples = 0 }

let reset_tally tally zero =
  tally.reported <- zero;
  tally.reported_samples <- 0;
  tally.unreported_samples <- 0;
  tally.unread_samples <- 0

let add_reading tally ~add reading =
  match reading with
  | Reported value ->
      tally.reported <- add tally.reported value;
      tally.reported_samples <- tally.reported_samples + 1
  | Unreported -> tally.unreported_samples <- tally.unreported_samples + 1
  | Unread -> tally.unread_samples <- tally.unread_samples + 1

(* A sum is known only when some sample reported a value. *)
let reported_sum_json tally to_json =
  if tally.reported_samples = 0 then `Null else to_json tally.reported

let tally_count_fields prefix tally =
  [ prefix ^ "_reported_samples", `Int tally.reported_samples
  ; prefix ^ "_unreported_samples", `Int tally.unreported_samples
  ; prefix ^ "_unread_samples", `Int tally.unread_samples
  ]

(* The longest window a keeper-costs request may ask for. Every day file the
   window touches is read on each refresh, and the route is a public read,
   so the window is bounded by what callers ask for: the web cost dashboard
   offers 30, 60, 360 and 1440 minutes, and a request with no window takes
   the default below. A view that needs a longer one raises this with it. *)
let keeper_costs_max_window_minutes = 24 * 60

let keeper_costs_default_window_minutes = keeper_costs_max_window_minutes

(* [window] as the request spelled it. Absent is the default; anything that
   is not a whole number of minutes in [1, max] is refused, never clamped:
   a clamped answer would be labelled with a window nobody asked for. *)
let keeper_costs_window_of_query = function
  | None -> Ok keeper_costs_default_window_minutes
  | Some raw -> (
      match int_of_string_opt raw with
      | Some minutes when minutes >= 1 && minutes <= keeper_costs_max_window_minutes ->
          Ok minutes
      | Some _ | None ->
          Error
            (Printf.sprintf "window must be a whole number of minutes from 1 to %d, got %S"
               keeper_costs_max_window_minutes raw))

(** Per-keeper cost/latency aggregates for the O4 cost dashboard.

    Reads every day file of each keeper's metrics store that the window
    touches (UTC days from the window start to now) and aggregates the turn
    rows at or after the window start: p50/p95 latency and the cost and
    token sums. Cost and tokens are summed only over samples that reported
    them; [cost_*_samples] and [tokens_*_samples] say how many samples
    reported the value, gave [null], or could not be read. A sum is [null]
    when no sample in the window reported it.

    [metrics_read] says whether the whole window was read (#38364). It was
    once the last 500 lines, which a busy day outgrows: turns older than
    those lines vanished from the sums without a trace. [read] carries the
    rows that were not JSON, any of which may have been a turn, so a sum
    beside a non-zero count is a floor. [failed] is a store that could not
    be read; its sums are zeroed and say nothing.

    [read.unread_turn_rows] counts turn rows the window may hold but whose
    [ts_unix] or [latency_ms] has a shape the writer never produces: a time
    that cannot place the row, or an in-window row with no readable latency.
    Either may have been a turn in the window, so a sum beside a non-zero
    count is a floor. A row whose kind this build cannot read (another
    schema, or no [record_kind]) is counted there too: it may have been a
    turn. A row whose time places it before the window start is outside it
    and counts nowhere. The window's first day file is read whole, so an
    unreadable row from earlier that day counts as well: the count is rows
    that may be in the window, not rows known to be. *)
let keeper_cost_aggregates_json
    ~(config : Workspace.config)
    ~(keepers : Keeper_meta_contract.keeper_meta list)
    ~(window_minutes : int)
    ~(now_ts : float)
  : Yojson.Safe.t =
  let window_sec = float_of_int window_minutes *. 60.0 in
  let start_ts = now_ts -. window_sec in
  let keeper_items =
    List.map
      (fun (m : Keeper_meta_contract.keeper_meta) ->
        let metrics_store = Keeper_types_support.keeper_metrics_store config m.name in
        let cost = empty_tally 0.0 in
        let tokens = empty_tally { input = 0; output = 0; total = 0 } in
        let sample_count = ref 0 in
        let latencies_rev = ref [] in
        let malformed_rows = ref 0 in
        let unread_turn_rows = ref 0 in
        let add_row j =
          let ts = Json_util.assoc_member_opt "ts_unix" j in
          (* The first day file is read whole. Even an unknown-kind row is
             outside this window when its readable time precedes the start. *)
          match ts with
          | Some (`Float value) when Float.is_finite value && value < start_ts -> ()
          | Some _ | None ->
            (match Keeper_metrics_record.kind_of_json j with
             | Some Keeper_metrics_record.Heartbeat -> ()
             | None -> incr unread_turn_rows
             | Some Keeper_metrics_record.Turn ->
               match ts, Json_util.assoc_member_opt "latency_ms" j with
               | Some (`Float ts_unix), latency when Float.is_finite ts_unix ->
                 (match latency with
                  | Some (`Int latency_ms) when latency_ms >= 0 ->
                    incr sample_count;
                    latencies_rev := float_of_int latency_ms :: !latencies_rev;
                    add_reading cost ~add:( +. ) (cost_reading_of_row j);
                    add_reading tokens
                      ~add:(fun sum counts ->
                        { input = sum.input + counts.input
                        ; output = sum.output + counts.output
                        ; total = sum.total + counts.total
                        })
                      (token_reading_of_row j)
                  | Some _ | None -> incr unread_turn_rows)
               | Some _, _ | None, _ -> incr unread_turn_rows)
        in
        let read =
          Dated_jsonl.iter_range_entries_result metrics_store
            ~since:(Log.format_utc_date_of start_ts)
            ~until:(Log.format_utc_date_of now_ts)
            (function
              | Dated_jsonl.Parsed j -> add_row j
              | Dated_jsonl.Malformed_json _ -> incr malformed_rows)
        in
        let metrics_read =
          match read with
          | Ok () ->
              `Assoc
                [ "state", `String "read"
                ; "malformed_rows", `Int !malformed_rows
                ; "unread_turn_rows", `Int !unread_turn_rows
                ]
          | Error error ->
              (* The rows seen before the failure are a fragment of the
                 window; drawing them would pass a part for the whole. *)
              reset_tally cost 0.0;
              reset_tally tokens { input = 0; output = 0; total = 0 };
              sample_count := 0;
              latencies_rev := [];
              `Assoc
                [ "state", `String "failed"
                ; "reason", `String (Dated_jsonl.read_error_to_string error)
                ]
        in
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
        `Assoc
          ([ "keeper_name", `String m.name
           ; "total_cost_usd", reported_sum_json cost (fun sum -> `Float sum)
           ]
           @ tally_count_fields "cost" cost
           @ [ "total_input_tokens", reported_sum_json tokens (fun sum -> `Int sum.input)
             ; "total_output_tokens", reported_sum_json tokens (fun sum -> `Int sum.output)
             ; "total_tokens", reported_sum_json tokens (fun sum -> `Int sum.total)
             ]
           @ tally_count_fields "tokens" tokens
           @ [ "p50_latency_ms", Json_util.float_opt_to_json p50_latency
             ; "p95_latency_ms", Json_util.float_opt_to_json p95_latency
             ; "sample_count", `Int !sample_count
             ; "metrics_read", metrics_read
             ]))
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
    ~(config : Workspace.config)
    ~(keepers : Keeper_meta_contract.keeper_meta list)
    ?(limit = 200)
    ()
  : Yojson.Safe.t =
  let limit = k2_feed_limit limit in
  let per_keeper_limit = limit * 2 in
  let all_events =
    List.concat_map
      (fun (m : Keeper_meta_contract.keeper_meta) ->
        let path = Keeper_types_support.keeper_decision_log_path config m.name in
        if not (Fs_compat.file_exists path)
        then []
        else (
          let lines =
            Dashboard_http_helpers.keeper_tail_lines_or_empty ~site:"dashboard_keeper_decisions"
              path
              ~max_bytes:500_000
              ~max_lines:per_keeper_limit
          in
          List.filter_map
            (fun line ->
              try
                let json = Yojson.Safe.from_string line in
                let ts =
                  match Json_util.assoc_member_opt "ts_unix" json with
                  | Some (`Float f) -> f
                  | Some (`Int i) -> float_of_int i
                  | _ -> 0.0
                in
                let event_type =
                  match Json_util.assoc_member_opt "event" json with
                  | Some (`String s) -> s
                  | _ -> "turn"
                in
                let keeper_name =
                  match Json_util.assoc_member_opt "keeper_name" json with
                  | Some (`String s) -> s
                  | _ -> m.name
                in
                Some (ts, json, event_type, keeper_name)
              with
              | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None)
            lines))
      keepers
  in
  let sorted = List.sort (fun (ta, _, _, _) (tb, _, _, _) -> Float.compare tb ta) all_events in
  let rec take n = function
    | [] -> []
    | _ when n <= 0 -> []
    | x :: xs -> x :: take (n - 1) xs
  in
  let top = take limit sorted in
  let items =
    List.map
      (fun (_ts, json, event_type, keeper_name) ->
        let m key source = Option.value ~default:`Null (Json_util.assoc_member_opt key source) in
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
        (* Usage, stop reason and error category are written inside the turn
           row's [telemetry] object (Keeper_unified_metrics_decision), not at
           the top level. Rows without a [telemetry] object carry none of
           them. *)
        let telemetry =
          match m "telemetry" json with
          | `Assoc _ as telemetry -> telemetry
          | _ -> `Null
        in
        let telemetry_float_or_null key =
          match m key telemetry with
          | `Float f -> `Float f
          | `Int i -> `Float (float_of_int i)
          | _ -> `Null
        in
        let telemetry_int_or_null key =
          match m key telemetry with
          | `Int i -> `Int i
          | _ -> `Null
        in
        let telemetry_string_or_null key =
          match string_member_opt key telemetry with
          | Some value -> `String value
          | None -> `Null
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
          Json_util.string_opt_to_json (terminal_reason_code_of_decision_json json)
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
          ; "latency_ms", float_or_null "latency_ms"
          ; "cost_usd", telemetry_float_or_null "cost_usd"
          ; "input_tokens", telemetry_int_or_null "input_tokens"
          ; "output_tokens", telemetry_int_or_null "output_tokens"
          ; "stop_reason", telemetry_string_or_null "stop_reason"
          ; "error_category", telemetry_string_or_null "error_category"
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
      , keeper_decisions_retention_json ~keeper_count:(List.length keepers) )
    ; "events", `List items
    ; "limit", `Int limit
    (* NDT-OK: K2 feed metadata is an observation timestamp only; sorting and
       event identity use parsed event timestamps above. *)
    ; "generated_at", `Float (Unix.gettimeofday ())
    ; "generated_at_iso", `String (Masc_domain.now_iso ())
    ]
;;
