(** Dashboard Tool Quality API — aggregate tool call quality metrics.

    Reads [.masc/tool_calls/] JSONL via {!Keeper_tool_call_log.read_recent}
    and produces summary statistics for dashboard consumption.

    @since 2.260.0 *)

(* The status is read back with the codec that wrote it
   ([Exec_core.process_status_of_json]) and classified by the module that
   owns the timeout convention ([Process_eio.exit_reason_of_status]). Matching
   the kind strings here had drifted from the producer: it looked for
   "signaled" and "timeout", which no tool output writes, so a signal and a
   timeout both fell to "unknown_error". *)
let classify_process_status (json : Yojson.Safe.t) : string option =
  match Json_util.assoc_member_opt "status" json with
  | None -> None
  | Some status ->
    let op = Safe_ops.json_string_opt "op" json |> Option.value ~default:"tool" in
    (match Exec_core.process_status_of_json status with
     | Error _ -> Some (Printf.sprintf "%s_status_unreadable" op)
     | Ok status ->
       (match Process_eio.exit_reason_of_status status with
        | Process_eio.Completed 0 -> None
        | Process_eio.Completed code -> Some (Printf.sprintf "%s_exit_%d" op code)
        | Process_eio.Timed_out -> Some (Printf.sprintf "%s_timeout" op)
        | Process_eio.Signaled signal -> Some (Printf.sprintf "%s_signaled_%d" op signal)
        | Process_eio.Stopped signal -> Some (Printf.sprintf "%s_stopped_%d" op signal)))

let classify_failure_output (output : string) : string =
  if String.length output = 0 then "empty_output"
  else
    match Yojson.Safe.from_string output with
    | j ->
      (match Safe_ops.json_string_opt "error" j with
       | Some error when String.trim error <> "" -> error
       | _ ->
         classify_process_status j |> Option.value ~default:"unknown_error")
    | exception Yojson.Json_error _ -> "unstructured_failure"

let bucket_key record field ~default =
  Safe_ops.json_string_opt field record |> Option.value ~default

let unknown_runtime_profile_bucket = "unknown_runtime_profile"

let runtime_bucket_key record =
  match Safe_ops.json_string_opt "runtime_profile" record with
  | Some value when String.trim value <> "" -> value
  | _ ->
    let runtime_contract = Option.value ~default:`Null (Json_util.assoc_member_opt "runtime_contract" record) in
    (match Safe_ops.json_string_opt "runtime_profile" runtime_contract with
     | Some value when String.trim value <> "" -> value
     | _ -> unknown_runtime_profile_bucket)

(* Split the two failure modes that previously collapsed to the
   bare "unknown" bucket so a non-zero count on either tells the
   operator a distinct producer fix: missing/non-bool field vs
   non-object record envelope. *)
let thinking_mode_of_record record =
  match record with
  | `Assoc fields ->
    (match List.assoc_opt "thinking_enabled" fields with
     | Some (`Bool true) -> "enabled"
     | Some (`Bool false) -> "disabled"
     | _ -> "<missing thinking_enabled field>")
  | _ -> "<non-object record envelope>"

type tool_record_outcome =
  | Settled of bool
  | Deferred
  | Unsettled
  | Lifecycle_event
  | Composition_summary
  | Malformed_outcome

(* Lifecycle markers are not invocation outcomes and never enter the quality
   denominator. Neither does a composition's summary row: each of its steps is
   already a [tool_call] row of its own, so counting the summary too would read
   one composition as the step count plus one calls. An invocation row's
   outcome is read by the rule every tool-call log reader shares
   ({!Tool_result.recorded_call_outcome}). *)
let tool_outcome_of_record record =
  let invocation () =
    match Tool_result.recorded_call_outcome record with
    | Tool_result.Recorded_succeeded -> Settled true
    | Tool_result.Recorded_failed -> Settled false
    | Tool_result.Recorded_deferred -> Deferred
    | Tool_result.Recorded_unsettled -> Unsettled
    | Tool_result.Recorded_malformed -> Malformed_outcome
  in
  match record with
  | `Assoc fields ->
    (match List.assoc_opt "record_kind" fields with
     | None -> invocation ()
     | Some (`String kind) ->
       (match Keeper_tool_call_log.record_kind_of_string kind with
        | Some Keeper_tool_call_log.Tool_call -> invocation ()
        | Some Keeper_tool_call_log.Composition_run -> Composition_summary
        | Some Keeper_tool_call_log.Lifecycle_event -> Lifecycle_event
        | None -> Malformed_outcome)
     | Some _ -> Malformed_outcome)
  | _ -> Malformed_outcome

(* Every invocation-result producer writes [result_bytes] (the [log_call]
   callers in keeper_hooks_agent_core, keeper_tool_composition_surface_observation
   and mcp_server_eio_call_tool all pass it). A result row without it is malformed:
   it is dropped from every aggregate and counted in [malformed]. Lifecycle
   markers are classified and excluded before this requirement is applied. *)
let result_bytes_of_record record =
  match record with
  | `Assoc fields ->
    (match List.assoc_opt "result_bytes" fields with
     | Some (`Int bytes) -> Some bytes
     | _ -> None)
  | _ -> None

let hour_key_of_record record =
  let hour_of_unix ts =
    let tm = Unix.gmtime ts in
    Printf.sprintf "%04d-%02d-%02dT%02d"
      (tm.Unix.tm_year + 1900)
      (tm.Unix.tm_mon + 1)
      tm.Unix.tm_mday
      tm.Unix.tm_hour
  in
  match record with
  | `Assoc fields ->
    (match List.assoc_opt "ts" fields with
     | Some (`Float f) -> hour_of_unix f
     | Some (`Int i) -> hour_of_unix (Float.of_int i)
     | Some (`String s) when String.length s >= 13 -> String.sub s 0 13
     | Some (`String s) -> s
     | _ -> "<missing or non-numeric ts field>")
  | _ -> "<non-object record envelope>"

module String_map = Map.Make (String)

(* One hour of the trend: its calls and successes, and the bytes of the
   results those calls returned (the ledger rows' [result_bytes]). *)
type hour_entry =
  { hour_calls : int
  ; hour_successes : int
  ; hour_result_bytes : int
  }

type rate_entry =
  { calls : int
  ; successes : int
  }

type tool_entry =
  { calls : int
  ; successes : int
  ; total_ms : float
  ; truncated_count : int
  ; total_output_chars : int
  }

let empty_tool_entry =
  { calls = 0
  ; successes = 0
  ; total_ms = 0.0
  ; truncated_count = 0
  ; total_output_chars = 0
  }

let update_rate_map map key ok =
  let key = if String.trim key = "" then "unknown" else key in
  let cur =
    String_map.find_opt key map
    |> Option.value ~default:{ calls = 0; successes = 0 }
  in
  String_map.add
    key
    { calls = cur.calls + 1
    ; successes = cur.successes + (if ok then 1 else 0)
    }
    map

let update_hour_map map key ok result_bytes =
  let cur =
    String_map.find_opt key map
    |> Option.value
         ~default:{ hour_calls = 0; hour_successes = 0; hour_result_bytes = 0 }
  in
  String_map.add
    key
    { hour_calls = cur.hour_calls + 1
    ; hour_successes = cur.hour_successes + (if ok then 1 else 0)
    ; hour_result_bytes = cur.hour_result_bytes + result_bytes
    }
    map

let render_rate_map ~field map =
  String_map.fold
    (fun name ({ calls; successes } : rate_entry) acc ->
      let pct =
        if calls > 0
        then Float.of_int successes /. Float.of_int calls *. 100.0
        else 0.0
      in
      (calls, `Assoc [
        (field, `String name);
        ("calls", `Int calls);
        ("success_pct", `Float pct);
      ]) :: acc)
    map
    []
  |> List.sort (fun (a, _) (b, _) -> Int.compare b a)
  |> List.map snd

type summary_acc =
  { total : int
  ; success : int
  ; hourly_trend : hour_entry String_map.t
  ; tool_stats : tool_entry String_map.t
  ; keeper_stats : rate_entry String_map.t
  ; runtime_stats : rate_entry String_map.t
  ; model_stats : rate_entry String_map.t
  ; lane_stats : rate_entry String_map.t
  ; thinking_mode_stats : rate_entry String_map.t
  ; tool_choice_stats : rate_entry String_map.t
  ; failure_cats : int String_map.t
  }

let empty_summary_acc =
  { total = 0
  ; success = 0
  ; hourly_trend = String_map.empty
  ; tool_stats = String_map.empty
  ; keeper_stats = String_map.empty
  ; runtime_stats = String_map.empty
  ; model_stats = String_map.empty
  ; lane_stats = String_map.empty
  ; thinking_mode_stats = String_map.empty
  ; tool_choice_stats = String_map.empty
  ; failure_cats = String_map.empty
  }

let dashboard_surface = "/api/v1/dashboard/tool-quality"

let source_metadata_fields () =
  Dashboard_tool_source_freshness.keeper_tool_call_io_fields
    ~dashboard_surface ()

(* What the records are a sample of: every call of the last [hours], or the
   most recent [n]. It used to travel as a label string beside an optional
   window and a limit, which could name one mode and carry the other's
   number. *)
type sampling =
  | Window_hours of float
  | Recent_n of int

let select_sampling ?(n = 5000) ?window_hours () =
  match window_hours with
  | Some hours when hours > 0.0 -> Window_hours hours
  | Some _ | None -> Recent_n n

let sampling_fields = function
  | Window_hours hours ->
    [ ("sampling_mode", `String "window_hours")
    ; ("sample_limit", `Null)
    ; ("window_hours", `Float hours)
    ]
  | Recent_n n ->
    [ ("sampling_mode", `String "recent_n")
    ; ("sample_limit", `Int n)
    ; ("window_hours", `Null)
    ]

let empty_summary ~sampling ~deferred ~unsettled ~malformed =
  `Assoc
    (source_metadata_fields ()
    @ [ ("generated_at", `String (Masc_domain.now_iso ())) ]
    @ sampling_fields sampling
    @ [ ("total", `Int 0)
    ; ("success", `Int 0)
    ; ("failure", `Int 0)
    ; ("deferred", `Int deferred)
    ; ("unsettled", `Int unsettled)
    ; ("malformed", `Int malformed)
    ; ("success_rate", `Float 0.0)
    ; ("by_tool", `List [])
    ; ("by_keeper", `List [])
    ; ("by_runtime", `List [])
    ; ("by_model", `List [])
    ; ("by_lane", `List [])
    ; ("by_thinking_mode", `List [])
    ; ("by_tool_choice", `List [])
    ; ("failure_categories", `List [])
    ; ("hourly_trend", `List [])
    ])

(* The payload over already-read [records]; the read is [aggregate]'s. *)
let summarize ~sampling records : Yojson.Safe.t =
  let deferred, unsettled, malformed, records =
    List.fold_left
      (fun (deferred, unsettled, malformed, acc) record ->
        match tool_outcome_of_record record, result_bytes_of_record record with
        | (Lifecycle_event | Composition_summary), _ -> deferred, unsettled, malformed, acc
        | _, None -> deferred, unsettled, malformed + 1, acc
        | Settled success, Some result_bytes ->
          deferred, unsettled, malformed, (record, result_bytes, success) :: acc
        | Deferred, Some _ -> deferred + 1, unsettled, malformed, acc
        | Unsettled, Some _ -> deferred, unsettled + 1, malformed, acc
        | Malformed_outcome, Some _ -> deferred, unsettled, malformed + 1, acc)
      (0, 0, 0, []) records
  in
  let records = List.rev records in
  if records = [] then
    empty_summary ~sampling ~deferred ~unsettled ~malformed
  else
  let acc =
    List.fold_left
      (fun acc (record, output_chars, ok) ->
        (* [tool] and [keeper] become bucket keys in the dashboard
           histogram.  A bare "unknown" bucket appears in the same column
           as a legitimate tool named "unknown", so the operator cannot
           tell "the tool field was missing from N records" apart from
           "tool 'unknown' was invoked N times".  Use structured markers
           so a non-zero bucket on either is a producer-side fix
           signal. *)
        let tool =
          Safe_ops.json_string_opt "tool" record
          |> Option.value ~default:"<missing tool field>"
        in
        let keeper =
          Safe_ops.json_string_opt "keeper" record
          |> Option.value ~default:"<missing keeper field>"
        in
        let dur =
          match record with
          | `Assoc fields ->
            (match List.assoc_opt "duration_ms" fields with
             | Some (`Float f) -> f
             | Some (`Int i) -> Float.of_int i
             | _ -> 0.0)
          | _ -> 0.0
        in
        let was_truncated =
          match record with
          | `Assoc fields -> Option.is_some (List.assoc_opt "truncated_to" fields)
          | _ -> false
        in
        let hour_key = hour_key_of_record record in
        let cur_tool =
          String_map.find_opt tool acc.tool_stats
          |> Option.value ~default:empty_tool_entry
        in
        let tool_stats =
          String_map.add
            tool
            { calls = cur_tool.calls + 1
            ; successes = cur_tool.successes + (if ok then 1 else 0)
            ; total_ms = cur_tool.total_ms +. dur
            ; truncated_count =
                cur_tool.truncated_count + (if was_truncated then 1 else 0)
            ; total_output_chars = cur_tool.total_output_chars + output_chars
            }
            acc.tool_stats
        in
        let failure_cats =
          if ok then acc.failure_cats
          else
            let output =
              match record with
              | `Assoc fields ->
                (match List.assoc_opt "output" fields with
                 | Some (`String s) -> s
                 | Some (`Assoc [("_blob", `Assoc blob)]) ->
                   (* Normalized blob object — failure classifier wants the
                      preview (where the error JSON body lives) rather than
                      the marker envelope. *)
                   (match List.assoc_opt "preview" blob with
                    | Some (`String p) -> p
                    | _ -> "")
                 | _ -> "")
              | _ -> ""
            in
            let cat = classify_failure_output output in
            let cur_cat =
              String_map.find_opt cat acc.failure_cats
              |> Option.value ~default:0
            in
            String_map.add cat (cur_cat + 1) acc.failure_cats
        in
        { total = acc.total + 1
        ; success = acc.success + (if ok then 1 else 0)
        ; hourly_trend =
            update_hour_map acc.hourly_trend hour_key ok output_chars
        ; tool_stats
        ; keeper_stats = update_rate_map acc.keeper_stats keeper ok
        ; runtime_stats =
            update_rate_map acc.runtime_stats (runtime_bucket_key record) ok
        ; model_stats =
            update_rate_map
              acc.model_stats
              (bucket_key record "model" ~default:"unknown")
              ok
        ; lane_stats =
            update_rate_map
              acc.lane_stats
              (bucket_key record "lane" ~default:"unknown")
              ok
        ; thinking_mode_stats =
            update_rate_map
              acc.thinking_mode_stats
              (thinking_mode_of_record record)
              ok
        ; tool_choice_stats =
            update_rate_map
              acc.tool_choice_stats
              (bucket_key record "tool_choice" ~default:"unknown")
              ok
        ; failure_cats
        })
      empty_summary_acc
      records
  in
  let total_n = acc.total in
  let success_n = acc.success in
  let rate =
    if total_n = 0 then 0.0
    else Float.of_int success_n /. Float.of_int total_n *. 100.0
  in
  (* Sort by call count descending *)
  let by_tool =
    String_map.fold
      (fun name { calls; successes; total_ms; truncated_count; total_output_chars } out ->
        let avg_ms = if calls > 0 then total_ms /. Float.of_int calls else 0.0 in
        let pct =
          if calls > 0
          then Float.of_int successes /. Float.of_int calls *. 100.0
          else 0.0
        in
        let avg_output =
          if calls > 0
          then Float.of_int total_output_chars /. Float.of_int calls
          else 0.0
        in
        (calls, `Assoc [
          ("name", `String name);
          ("calls", `Int calls);
          ("success_pct", `Float pct);
          ("avg_ms", `Float (Float.round (avg_ms *. 10.0) /. 10.0));
          ("output_truncated_count", `Int truncated_count);
          ("avg_output_chars", `Float (Float.round (avg_output *. 10.0) /. 10.0));
        ]) :: out)
      acc.tool_stats
      []
    |> List.sort (fun (a, _) (b, _) -> Int.compare b a)
    |> List.map snd
  in
  let by_keeper = render_rate_map ~field:"name" acc.keeper_stats in
  let by_runtime = render_rate_map ~field:"name" acc.runtime_stats in
  let by_model = render_rate_map ~field:"name" acc.model_stats in
  let by_lane = render_rate_map ~field:"name" acc.lane_stats in
  let by_thinking_mode =
    render_rate_map ~field:"name" acc.thinking_mode_stats
  in
  let by_tool_choice =
    render_rate_map ~field:"name" acc.tool_choice_stats
  in
  let failure_categories =
    String_map.fold
      (fun cat count out ->
        (count, `Assoc [("category", `String cat); ("count", `Int count)]) :: out)
      acc.failure_cats
      []
    |> List.sort (fun (a, _) (b, _) -> Int.compare b a)
    |> List.map snd
  in
  let hourly =
    String_map.fold
      (fun hour
           ({ hour_calls; hour_successes; hour_result_bytes } : hour_entry)
           out ->
        let pct =
          if hour_calls > 0
          then Float.of_int hour_successes /. Float.of_int hour_calls *. 100.0
          else 0.0
        in
        (hour, `Assoc [
          ("hour", `String hour);
          ("calls", `Int hour_calls);
          ("success", `Int hour_successes);
          ("success_rate", `Float (Float.round (pct *. 10.0) /. 10.0));
          ("result_bytes", `Int hour_result_bytes);
        ]) :: out)
      acc.hourly_trend
      []
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
    |> List.map snd
  in
  `Assoc (
    source_metadata_fields ()
    @ [ ("generated_at", `String (Masc_domain.now_iso ())) ]
    @ sampling_fields sampling
    @ [
    ("total", `Int total_n);
    ("success", `Int success_n);
    ("failure", `Int (total_n - success_n));
    ("deferred", `Int deferred);
    ("unsettled", `Int unsettled);
    ("malformed", `Int malformed);
    ("success_rate", `Float (Float.round (rate *. 100.0) /. 100.0));
    ("by_tool", `List by_tool);
    ("by_keeper", `List by_keeper);
    ("by_runtime", `List by_runtime);
    ("by_model", `List by_model);
    ("by_lane", `List by_lane);
    ("by_thinking_mode", `List by_thinking_mode);
    ("by_tool_choice", `List by_tool_choice);
    ("failure_categories", `List failure_categories);
    ("hourly_trend", `List hourly);
  ])

let aggregate sampling : (Yojson.Safe.t, Keeper_tool_call_log.index_error) result =
  match sampling with
  | Window_hours hours ->
    Ok
      (summarize ~sampling:(Window_hours hours)
         (Keeper_tool_call_log.read_window ~window_hours:hours ()))
  | Recent_n n ->
    (match Keeper_tool_call_log.read_recent ~n () with
     | Ok records ->
       Ok (summarize ~sampling:(Recent_n n) records)
     | Error (Keeper_tool_call_log.Index_unavailable _ as error) -> Error error)
;;
