(** Dashboard_harness_health — read model for Lab safety harness.

    Aggregates evaluator calibration stats with recent runtime safety signals
    so the Lab surface can explain what the harness is watching. *)

type rail_status =
  | Healthy
  | Warning
  | Stale
  | Idle

type harness_verdict_item =
  { timestamp : float
  ; task_id : string
  ; task_title : string
  ; agent_name : string
  ; gate : string
  ; verdict : string
  ; evaluator_runtime : string
  ; fallback_reason : string option
  ; notes_hash : string
    (** The calibration correlation key: a human label recorded against this
        hash joins this verdict in {!Eval_calibration.find_divergences}. *)
  }

(** Wake-time payload observation.

    Captured once per keeper turn, just before [Keeper_turn_driver.run_named] fires.
    Component byte fields are exact measurements of the canonical values MASC
    owns; they do not claim to represent a provider-specific HTTP request body.

    [message_count] and [role_counts] include the synthesized user turn
    that AGENT_CORE will append from [~goal], matching the wire-level message
    list the LLM will receive. *)
type wake_payload_event =
  { timestamp : float
  ; keeper_name : string
  ; trace_id : string
  ; turn_index : int
  ; context_window : int
  ; system_prompt_bytes : int
  ; tool_schema_json_bytes : int
  ; message_content_bytes : int
  ; message_count : int
  ; role_counts : (string * int) list
  ; tool_count : int
  }

type handoff_event =
  { timestamp : float
  ; keeper_name : string
  ; trace_id : string
  ; generation : int
  ; next_generation : int option
  ; prev_trace_id : string option
  ; new_trace_id : string option
  }

let max_runtime_events = 12
let max_recent_verdicts = 8
let max_signal_scan = 500
let runtime_stale_after_s = 30. *. 60.
let evaluator_stale_after_s = 12. *. Masc_time_constants.hour

(* Fraction of an evaluator's verdicts that came back Invalid_verdict or
   Evaluator_unavailable before the rail stops reading Healthy. The two
   thresholds above are named, this one was a bare 0.8 at its comparison, so
   the number nobody had to look at was the one that decides whether four
   failures in five still read as fine. Named here so changing it is a
   reviewed edit. *)
let evaluator_fallback_warning_ratio = 0.8

(** Store for wake-time payload observations. Populated lazily on the first
    [record_wake_payload] call. *)
let wake_payload_store_ref : Dated_jsonl.t option Atomic.t = Atomic.make None
let wake_payload_store_mu = Eio.Mutex.create ()

let status_to_string = function
  | Healthy -> "healthy"
  | Warning -> "warning"
  | Stale -> "stale"
  | Idle -> "idle"
;;

let trim_recent (type a) max_items (values : a list) : a list =
  if List.length values <= max_items
  then values
  else List.filteri (fun idx _ -> idx < max_items) values
;;


let wake_payload_store_base_dir () =
  Filename.concat (Env_config.base_path ()) "data/keeper-wake-payload"
;;

let get_or_create_store ~store_ref ~store_mu base_dir_fn =
  match Atomic.get store_ref with
  | Some store -> store
  | None ->
    Eio.Mutex.use_rw ~protect:true store_mu @@ fun () ->
    (match Atomic.get store_ref with
     | Some store -> store
     | None ->
       let store = Dated_jsonl.create ~base_dir:(base_dir_fn ()) () in
       Atomic.set store_ref (Some store);
       store)
;;

let append_store_json_fail_open ~store_ref ~store_name get_store json =
  try Dated_jsonl.append (get_store ()) json with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    (* Health/event persistence is observability only. If the backing JSONL
         append fails, drop the poisoned store so the next call can recreate
         it instead of leaking Eio_mutex.Poisoned into keeper control flow. *)
    Atomic.set store_ref None;
    Log.Harness.warn "[%s] append failed: %s" store_name (Printexc.to_string exn)
;;


let get_wake_payload_store () =
  get_or_create_store
    ~store_ref:wake_payload_store_ref
    ~store_mu:wake_payload_store_mu
    wake_payload_store_base_dir
;;



let set_wake_payload_store_for_testing ~base_dir =
  Atomic.set wake_payload_store_ref (Some (Dated_jsonl.create ~base_dir ()))
;;

let string_field json key = Safe_ops.json_string ~default:"" key json
let is_stale ~threshold_s timestamp = Time_compat.now () -. timestamp > threshold_s

let date_bounds ?since ?until () =
  let since =
    match since with
    | Some value -> value
    | None -> ""
  in
  let until =
    match until with
    | Some value -> value
    | None -> ""
  in
  since, until
;;

(* Both branches read at most [max_signal_scan] rows. They did not: the
   unfiltered branch was bounded and the filtered one was not, so supplying a
   date — which a caller does to narrow the result — removed the row cap and
   scanned every day-file in range. A one-sided bound widens further, since the
   missing side is filled with 2020-01-01 / 2099-12-31 below.

   [read_range_recent] is the bounded reader for a date range and takes the
   same cap the unfiltered branch already uses. *)
let read_store_records store ?since ?until ~f () =
  let since, until = date_bounds ?since ?until () in
  if since = "" && until = ""
  then Dated_jsonl.filter_map_recent store max_signal_scan ~f
  else (
    let start_date = if since = "" then "2020-01-01" else since in
    let end_date = if until = "" then "2099-12-31" else until in
    Dated_jsonl.filter_map_range_recent
      store
      ~since:start_date
      ~until:end_date
      max_signal_scan
      ~f)
;;

let max_timestamp left right =
  match left, right with
  | Some l, Some r -> Some (Float.max l r)
  | (Some _ as value), None | None, (Some _ as value) -> value
  | None, None -> None
;;

let verdict_item_json (item : harness_verdict_item) =
  `Assoc
    [ "timestamp", `Float item.timestamp
    ; "task_id", `String item.task_id
    ; "task_title", `String item.task_title
    ; "agent_name", `String item.agent_name
    ; "gate", `String item.gate
    ; "verdict", `String item.verdict
    ; "evaluator_runtime", `String item.evaluator_runtime
    ; "fallback_reason", Json_util.string_opt_to_json item.fallback_reason
    ; "notes_hash", `String item.notes_hash
    ]
;;

let verdict_item_of_json json =
  if not (String.equal (string_field json "record_type") "verdict")
  then None
  else
    Some
      { timestamp = Safe_ops.json_float ~default:0.0 "timestamp" json
      ; task_id = string_field json "task_id"
      ; task_title = string_field json "task_title"
      ; agent_name = string_field json "agent_name"
      ; gate = string_field json "gate"
      ; verdict = string_field json "verdict"
      ; evaluator_runtime = string_field json "evaluator_runtime"
      ; fallback_reason = Safe_ops.json_string_opt "fallback_reason" json
      ; notes_hash = string_field json "notes_hash"
      }
;;




let role_counts_to_json (counts : (string * int) list) : Yojson.Safe.t =
  `Assoc (List.map (fun (role, n) -> role, `Int n) counts)
;;

let ( let* ) result f = Result.bind result f

let required_member fields key =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing required field %S" key)
;;

let required_string fields key =
  let* value = required_member fields key in
  match value with
  | `String value -> Ok value
  | _ -> Error (Printf.sprintf "field %S must be a string" key)
;;

let required_non_empty_string fields key =
  let* value = required_string fields key in
  if String.equal value ""
  then Error (Printf.sprintf "field %S must be non-empty" key)
  else Ok value
;;

let int_json ~field = function
  | `Int value -> Ok value
  | `Intlit raw ->
    (match int_of_string_opt raw with
     | Some value -> Ok value
     | None -> Error (Printf.sprintf "field %S has an invalid integer" field))
  | _ -> Error (Printf.sprintf "field %S must be an integer" field)
;;

let required_int fields key =
  let* value = required_member fields key in
  int_json ~field:key value
;;

let required_nonnegative_int fields key =
  let* value = required_int fields key in
  if value < 0
  then Error (Printf.sprintf "field %S must be non-negative" key)
  else Ok value
;;

let required_positive_int fields key =
  let* value = required_int fields key in
  if value <= 0
  then Error (Printf.sprintf "field %S must be positive" key)
  else Ok value
;;

let required_float fields key =
  let* value = required_member fields key in
  let* value =
    match value with
    | `Float value -> Ok value
    | `Int value -> Ok (Float.of_int value)
    | `Intlit raw ->
      (match float_of_string_opt raw with
       | Some value -> Ok value
       | None -> Error (Printf.sprintf "field %S has an invalid number" key))
    | _ -> Error (Printf.sprintf "field %S must be a number" key)
  in
  if Float.is_finite value
  then Ok value
  else Error (Printf.sprintf "field %S must be finite" key)
;;

let required_role_counts fields =
  let* value = required_member fields "role_counts" in
  match value with
  | `Assoc counts ->
    List.fold_left
      (fun result (role, value) ->
         let* counts = result in
         let* count = int_json ~field:("role_counts." ^ role) value in
         if count < 0
         then Error (Printf.sprintf "field %S must be non-negative" ("role_counts." ^ role))
         else Ok ((role, count) :: counts))
      (Ok [])
      counts
    |> Result.map List.rev
  | _ -> Error "field \"role_counts\" must be an object of integer counts"
;;

let wake_payload_record_type = "wake_payload"

let wake_payload_record_json (event : wake_payload_event) =
  `Assoc
    [ "record_type", `String wake_payload_record_type
    ; "timestamp", `Float event.timestamp
    ; "keeper_name", `String event.keeper_name
    ; "trace_id", `String event.trace_id
    ; "turn_index", `Int event.turn_index
    ; "context_window", `Int event.context_window
    ; "system_prompt_bytes", `Int event.system_prompt_bytes
    ; "tool_schema_json_bytes", `Int event.tool_schema_json_bytes
    ; "message_content_bytes", `Int event.message_content_bytes
    ; "message_count", `Int event.message_count
    ; "role_counts", role_counts_to_json event.role_counts
    ; "tool_count", `Int event.tool_count
    ]
;;

let wake_payload_event_of_json json =
  match json with
  | `Assoc fields ->
    let* record_type = required_string fields "record_type" in
    if not (String.equal record_type wake_payload_record_type)
    then Error (Printf.sprintf "unexpected record_type %S" record_type)
    else
      let* timestamp = required_float fields "timestamp" in
      let* keeper_name = required_non_empty_string fields "keeper_name" in
      let* trace_id = required_non_empty_string fields "trace_id" in
      let* turn_index = required_nonnegative_int fields "turn_index" in
      let* context_window = required_positive_int fields "context_window" in
      let* system_prompt_bytes = required_nonnegative_int fields "system_prompt_bytes" in
      let* tool_schema_json_bytes =
        required_nonnegative_int fields "tool_schema_json_bytes"
      in
      let* message_content_bytes =
        required_nonnegative_int fields "message_content_bytes"
      in
      let* message_count = required_positive_int fields "message_count" in
      let* role_counts = required_role_counts fields in
      let* () =
        let role_count_sum =
          List.fold_left (fun sum (_, count) -> sum + count) 0 role_counts
        in
        if role_count_sum = message_count
        then Ok ()
        else
          Error
            (Printf.sprintf
               "role_counts sum %d does not equal message_count %d"
               role_count_sum
               message_count)
      in
      let* tool_count = required_nonnegative_int fields "tool_count" in
      Ok
        { timestamp
        ; keeper_name
        ; trace_id
        ; turn_index
        ; context_window
        ; system_prompt_bytes
        ; tool_schema_json_bytes
        ; message_content_bytes
        ; message_count
        ; role_counts
        ; tool_count
        }
  | _ -> Error "wake-payload record must be a JSON object"
;;

let wake_payload_record_identity json =
  match json with
  | `Assoc fields ->
    let string_or_missing key =
      match List.assoc_opt key fields with
      | Some (`String value) -> value
      | _ -> "<missing>"
    in
    string_or_missing "keeper_name", string_or_missing "trace_id"
  | _ -> "<missing>", "<missing>"
;;

let read_recent_verdicts ?since ?until ?(limit = max_recent_verdicts) ()
  : harness_verdict_item list
  =
  let verdicts : harness_verdict_item list =
    read_store_records
      (Eval_calibration.get_store ())
      ?since
      ?until
      ~f:verdict_item_of_json
      ()
  in
  let verdicts =
    List.sort
      (fun (left : harness_verdict_item) (right : harness_verdict_item) ->
         Float.compare right.timestamp left.timestamp)
      verdicts
  in
  trim_recent limit verdicts
;;

let read_recent_verdicts_for_agents
      ?since
      ?until
      ?(limit = max_recent_verdicts)
      ~agent_names
      ()
  : harness_verdict_item list
  =
  let wanted =
    agent_names |> List.map String.trim |> List.filter (fun name -> name <> "")
  in
  if wanted = []
  then []
  else (
    let is_wanted name = List.exists (String.equal name) wanted in
    let verdicts : harness_verdict_item list =
      read_store_records
        (Eval_calibration.get_store ())
        ?since
        ?until
        ~f:verdict_item_of_json
        ()
      |> List.filter (fun verdict -> is_wanted verdict.agent_name)
    in
    let verdicts =
      List.sort
        (fun (left : harness_verdict_item) (right : harness_verdict_item) ->
           Float.compare right.timestamp left.timestamp)
        verdicts
    in
    trim_recent limit verdicts)
;;


let read_wake_payload_events ?since ?until () =
  let events : wake_payload_event list =
    read_store_records
      (get_wake_payload_store ())
      ?since
      ?until
      ~f:(fun json ->
        match wake_payload_event_of_json json with
        | Ok event -> Some event
        | Error detail ->
          let keeper_name, trace_id = wake_payload_record_identity json in
          (* Unconditional per-row warn: no quota and no early stop, so it does
             not care that the reader calls this newest-first. *)
          Log.Harness.warn
            "[wake_payload] rejected persisted record keeper=%s trace=%s: %s"
            keeper_name
            trace_id
            detail;
          None)
      ()
  in
  List.sort
    (fun (left : wake_payload_event) (right : wake_payload_event) ->
       Float.compare right.timestamp left.timestamp)
    events
;;

let handoff_event_of_metrics_json json =
  let nonempty_string key source =
    match Safe_ops.json_string_opt key source with
    | Some value ->
        let value = String.trim value in
        if value = "" then None else Some value
    | None -> None
  in
  match Keeper_metrics_record.kind_of_json json with
  | Some Keeper_metrics_record.Turn ->
      (match
         Safe_ops.json_bool_opt "handoff_performed" json,
         Json_util.assoc_member_opt "handoff" json
       with
       | Some false, _ -> None
       | Some true, Some (`Assoc _ as handoff) ->
           (match
              Safe_ops.json_float_opt "ts_unix" json,
              nonempty_string "name" json,
              nonempty_string "trace_id" json,
              Safe_ops.json_int_opt "generation" json
            with
            | Some timestamp, Some keeper_name, Some trace_id, Some generation ->
                Some
                  { timestamp
                  ; keeper_name
                  ; trace_id
                  ; generation
                  ; next_generation =
                      Safe_ops.json_int_opt "to_generation" handoff
                  ; prev_trace_id =
                      nonempty_string "prev_trace_id" handoff
                  ; new_trace_id =
                      nonempty_string "new_trace_id" handoff
                  }
            | _ -> None)
       | Some true, _
       | None, _ -> None)
  | Some Keeper_metrics_record.Heartbeat
  | None -> None
;;

let handoff_event_json (event : handoff_event) =
  `Assoc
    [ "timestamp", `Float event.timestamp
    ; "keeper_name", `String event.keeper_name
    ; "trace_id", `String event.trace_id
    ; "generation", `Int event.generation
    ; "next_generation", Json_util.int_opt_to_json event.next_generation
    ; "prev_trace_id", Json_util.string_opt_to_json event.prev_trace_id
    ; "new_trace_id", Json_util.string_opt_to_json event.new_trace_id
    ]
;;

let read_keeper_metric_records ?since ?until (config : Workspace.config) keeper_name =
  let store = Keeper_types_support.keeper_metrics_store config keeper_name in
  match since, until with
  | Some _, _ | _, Some _ ->
    let since, until = date_bounds ?since ?until () in
    let start_date = if since = "" then "2020-01-01" else since in
    let end_date = if until = "" then "2099-12-31" else until in
    (* Same cap as the unfiltered branch below; see [read_store_records]. *)
    Dated_jsonl.read_range_recent
      store
      ~since:start_date
      ~until:end_date
      max_signal_scan
  | None, None -> Dated_jsonl.read_recent store max_signal_scan
;;

let read_handoff_events ?since ?until (config : Workspace.config) =
  let events =
    Keeper_meta_store.keeper_names config
    |> List.concat_map (fun keeper_name ->
      read_keeper_metric_records ?since ?until config keeper_name
      |> List.filter_map handoff_event_of_metrics_json)
  in
  List.sort
    (fun (left : handoff_event) (right : handoff_event) ->
       Float.compare right.timestamp left.timestamp)
    events
;;

let has_any_handoff_events (config : Workspace.config) =
  Keeper_meta_store.keeper_names config
  |> List.exists (fun keeper_name ->
    read_keeper_metric_records config keeper_name
    |> List.exists (fun json -> Option.is_some (handoff_event_of_metrics_json json)))
;;

let empty_reason ~has_any ?since ?until () =
  let since, until = date_bounds ?since ?until () in
  if has_any && (since <> "" || until <> "")
  then Some "window_empty"
  else if has_any
  then Some "no_recent_events"
  else Some "no_runtime_activity"
;;


let handoff_status (latest_event : handoff_event option) =
  match latest_event with
  | None -> Idle
  | Some event ->
    if is_stale ~threshold_s:runtime_stale_after_s event.timestamp
    then Stale
    else if
      Option.is_none event.prev_trace_id
      || Option.is_none event.new_trace_id
      || Option.is_none event.next_generation
    then Warning
    else Healthy
;;

let evaluator_status ~calibration latest_timestamp =
  let total_verdicts = Safe_ops.json_int ~default:0 "total_verdicts" calibration in
  let fallback_count = Safe_ops.json_int ~default:0 "fallback_count" calibration in
  if total_verdicts = 0
  then Idle
  else (
    match latest_timestamp with
    | Some ts when is_stale ~threshold_s:evaluator_stale_after_s ts -> Stale
    | _ ->
      let fallback_ratio =
        float_of_int fallback_count /. float_of_int (max 1 total_verdicts)
      in
      if fallback_ratio > evaluator_fallback_warning_ratio
      then Warning
      else Healthy)
;;

let latest_timestamp_of_verdicts (verdicts : harness_verdict_item list) =
  match verdicts with
  | item :: _ -> Some item.timestamp
  | [] -> None
;;

let latest_by_timestamp timestamp_of items =
  List.fold_left
    (fun acc item ->
       match acc with
       | Some current when timestamp_of current >= timestamp_of item -> acc
       | _ -> Some item)
    None
    items
;;

let handoff_timestamp (event : handoff_event) = event.timestamp
let handoff_generation (event : handoff_event) = event.next_generation




let record_wake_payload_at
      ~timestamp
      ~keeper_name
      ~trace_id
      ~turn_index
      ~context_window
      ~system_prompt_bytes
      ~tool_schema_json_bytes
      ~message_content_bytes
      ~message_count
      ~role_counts
      ~tool_count
  =
  let event =
    { timestamp
    ; keeper_name
    ; trace_id
    ; turn_index
    ; context_window
    ; system_prompt_bytes
    ; tool_schema_json_bytes
    ; message_content_bytes
    ; message_count
    ; role_counts
    ; tool_count
    }
  in
  append_store_json_fail_open
    ~store_ref:wake_payload_store_ref
    ~store_name:"wake_payload"
    get_wake_payload_store
    (wake_payload_record_json event);
  event
;;

let record_wake_payload
      ~keeper_name
      ~trace_id
      ~turn_index
      ~context_window
      ~system_prompt_bytes
      ~tool_schema_json_bytes
      ~message_content_bytes
      ~message_count
      ~role_counts
      ~tool_count
  =
  record_wake_payload_at
    ~timestamp:(Time_compat.now ())
    ~keeper_name
    ~trace_id
    ~turn_index
    ~context_window
    ~system_prompt_bytes
    ~tool_schema_json_bytes
    ~message_content_bytes
    ~message_count
    ~role_counts
    ~tool_count
;;


let recent_handoffs_json
      ?since
      ?until
      ~has_any
      ~(latest : handoff_event option)
      ~(events : handoff_event list)
      ()
  =
  let status = status_to_string (handoff_status latest) in
  let recent_events = trim_recent max_runtime_events events in
  `Assoc
    [ ( "description"
      , `String
          "Shows recent keeper checkpoint rollovers sourced from keeper metrics \
           snapshots." )
    ; "status", `String status
    ; "last_event_at", Json_util.float_opt_to_json (Option.map handoff_timestamp latest)
    ; ( "empty_reason"
      , match recent_events with
        | _ :: _ -> `Null
        | [] -> Json_util.string_opt_to_json (empty_reason ~has_any ?since ?until ()) )
    ; "recent_events", `List (List.map handoff_event_json recent_events)
    ; "total_recent", `Int (List.length events)
    ]
;;


let overview_json
      ~(calibration : Yojson.Safe.t)
      ~(recent_verdicts : harness_verdict_item list)
      ~(latest_handoff : handoff_event option)
  =
  let verdict_last = latest_timestamp_of_verdicts recent_verdicts in
  let handoff_last = Option.map handoff_timestamp latest_handoff in
  let fallback_count = Safe_ops.json_int ~default:0 "fallback_count" calibration in
  let total_verdicts = Safe_ops.json_int ~default:0 "total_verdicts" calibration in
  let fallback_ratio =
    if total_verdicts = 0
    then 0.0
    else float_of_int fallback_count /. float_of_int total_verdicts
  in
  (* Cross-model enforcement ratio: of verdicts that recorded both a
     generator and an evaluator runtime, what fraction used distinct
     runtimes? This is the *runtime* rate at which the cross-model
     review policy (anti_rationalization.mli, #3067) actually fired. *)
  let verdicts_with_generator =
    Safe_ops.json_int ~default:0 "verdicts_with_generator_runtime" calibration
  in
  let cross_model_match =
    Safe_ops.json_int ~default:0 "cross_model_match_count" calibration
  in
  let cross_model_rate =
    if verdicts_with_generator = 0
    then 0.0
    else float_of_int cross_model_match /. float_of_int verdicts_with_generator
  in
  let last_signal_at = max_timestamp verdict_last handoff_last in
  `Assoc
    [ ( "evaluator_status"
      , `String (status_to_string (evaluator_status ~calibration verdict_last)) )
    ; "handoff_status", `String (status_to_string (handoff_status latest_handoff))
    ; "last_signal_at", Json_util.float_opt_to_json last_signal_at
    ; "evaluator_last_event_at", Json_util.float_opt_to_json verdict_last
    ; "handoff_last_event_at", Json_util.float_opt_to_json handoff_last
    ; "fallback_ratio", `Float fallback_ratio
    ; "cross_model_rate", `Float cross_model_rate
    ; "cross_model_match_count", `Int cross_model_match
    ; "verdicts_with_generator_runtime", `Int verdicts_with_generator
    ; ( "latest_handoff_generation"
      , Json_util.int_opt_to_json (Option.bind latest_handoff handoff_generation) )
    ]
;;

let reset_runtime_stores_for_testing () =
  Atomic.set wake_payload_store_ref None
;;

let json ~(config : Workspace.config) ?since ?until () =
  let calibration = Eval_calibration.calibration_stats ?since ?until () in
  let recent_verdicts = read_recent_verdicts ?since ?until () in
  let has_window = Option.is_some since || Option.is_some until in
  let handoff_events = read_handoff_events ?since ?until config in
  let latest_handoff : handoff_event option =
    latest_by_timestamp handoff_timestamp handoff_events
  in
  let handoff_has_any =
    match handoff_events with
    | _ :: _ -> true
    | [] when has_window -> has_any_handoff_events config
    | [] -> false
  in
  `Assoc
    [ "generated_at", `Float (Time_compat.now ())
    ; ( "scope_note"
      , `String
          "The safety harness tracks supporting evaluator and long-running continuity \
           rails, so these signals are not a direct keep/discard judge for generator \
           iterations." )
    ; "overview", overview_json ~calibration ~recent_verdicts ~latest_handoff
    ; "calibration", calibration
    ; "recent_verdicts", `List (List.map verdict_item_json recent_verdicts)
    ; ( "recent_handoffs"
      , recent_handoffs_json
          ?since
          ?until
          ~has_any:handoff_has_any
          ~latest:latest_handoff
          ~events:handoff_events
          () )
    ]
;;

let () =
  Keeper_keepalive_signal.register_record_wake_payload (fun ~keeper_name ~trace_id ~turn_index ~context_window ~system_prompt_bytes ~tool_schema_json_bytes ~message_content_bytes ~message_count ~role_counts ~tool_count ->
    let (_recorded : wake_payload_event) =
      record_wake_payload ~keeper_name ~trace_id ~turn_index ~context_window
        ~system_prompt_bytes ~tool_schema_json_bytes ~message_content_bytes
        ~message_count ~role_counts ~tool_count
    in
    ()
  )
;;

(* ── Operator labels ─────────────────────────────────────────────────── *)

type label_request =
  { label_notes_hash : string
  ; label_verdict : Eval_calibration.label_verdict
  ; label_reason : string
  }

let notes_hash_hex_length = 64

(* The label is the verdict the human holds, in the calibration vocabulary —
   not agreement with the machine. Divergence mining compares this against
   the evaluator's verdict under the same notes hash, so an operator who
   agrees with a rejection records a reject label. *)
let parse_label_body body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error message -> Error ("body is not JSON: " ^ message)
  | `Assoc fields ->
    let string_of name =
      match List.assoc_opt name fields with
      | Some (`String value) -> Ok value
      | Some _ -> Error (Printf.sprintf "field %S must be a string" name)
      | None -> Error (Printf.sprintf "missing field %S" name)
    in
    let ( let* ) = Result.bind in
    let* label_notes_hash = string_of "notes_hash" in
    let* () =
      if
        String.length label_notes_hash = notes_hash_hex_length
        && String.for_all
             (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
             label_notes_hash
      then Ok ()
      else
        Error
          (Printf.sprintf "notes_hash must be %d lowercase hex characters"
             notes_hash_hex_length)
    in
    let* label_verdict =
      match string_of "verdict" with
      | Ok "approve" -> Ok Eval_calibration.Approve_label
      | Ok "reject" -> Ok Eval_calibration.Reject_label
      | Ok other ->
        Error
          (Printf.sprintf "verdict must be \"approve\" or \"reject\", got %S"
             other)
      | Error _ as e -> e
    in
    let* label_reason = Result.map String.trim (string_of "reason") in
    Ok { label_notes_hash; label_verdict; label_reason }
  | _ -> Error "body must be a JSON object"
;;

let record_operator_label ~labeler
    { label_notes_hash; label_verdict; label_reason } =
  Eval_calibration.record_human_label ~notes_hash:label_notes_hash
    ~human_verdict:label_verdict ~labeler ~reason:label_reason
;;
