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

let max_recent_verdicts = 8
let max_signal_scan = 500
let evaluator_stale_after_s = 12. *. Masc_time_constants.hour

(* Fraction of an evaluator's verdicts that came back Invalid_verdict or
   Evaluator_unavailable before the rail stops reading Healthy. The two
   thresholds above are named, this one was a bare 0.8 at its comparison, so
   the number nobody had to look at was the one that decides whether four
   failures in five still read as fine. Named here so changing it is a
   reviewed edit. *)
let evaluator_fallback_warning_ratio = 0.8

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

let read_recent_verdicts ?since ?until ?(limit = max_recent_verdicts) ~base_path ()
  : harness_verdict_item list
  =
  let verdicts : harness_verdict_item list =
    read_store_records
      (Eval_calibration.store ~base_path)
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

let overview_json
      ~(calibration : Yojson.Safe.t)
      ~(recent_verdicts : harness_verdict_item list)
  =
  let verdict_last = latest_timestamp_of_verdicts recent_verdicts in
  let fallback_count = Safe_ops.json_int ~default:0 "fallback_count" calibration in
  let total_verdicts = Safe_ops.json_int ~default:0 "total_verdicts" calibration in
  let fallback_ratio =
    if total_verdicts = 0
    then 0.0
    else float_of_int fallback_count /. float_of_int total_verdicts
  in
  (* The ledger owns these observations. Project its unavailable rate and
     model-identity coverage intact rather than recalculate missing data as
     a successful zero measurement. *)
  let measurement name = Yojson.Safe.Util.member name calibration in
  `Assoc
    [ ( "evaluator_status"
      , `String (status_to_string (evaluator_status ~calibration verdict_last)) )
    ; "last_signal_at", Json_util.float_opt_to_json verdict_last
      (* When the status turns Stale with no new verdict. A reader that
         re-reads only on a push has no push for that moment. *)
    ; ( "stale_at"
      , Json_util.float_opt_to_json
          (Option.map (fun ts -> ts +. evaluator_stale_after_s) verdict_last) )
    ; "evaluator_last_event_at", Json_util.float_opt_to_json verdict_last
    ; "fallback_ratio", `Float fallback_ratio
    ; "distinct_runtime_rate", measurement "distinct_runtime_rate"
    ; "distinct_runtime_count", measurement "distinct_runtime_count"
    ; "verdicts_with_generator_runtime", measurement "verdicts_with_generator_runtime"
    ; "model_identity_observation", measurement "model_identity_observation"
    ]
;;

let cache_key_prefix = "harness_health:"

let json ?since ?until ~base_path () =
  let calibration = Eval_calibration.calibration_stats ?since ?until ~base_path () in
  let recent_verdicts = read_recent_verdicts ?since ?until ~base_path () in
  `Assoc
    [ "generated_at", `Float (Time_compat.now ())
    ; ( "scope_note"
      , `String
          "The safety harness tracks supporting evaluator and long-running continuity \
           rails, so these signals are not a direct keep/discard judge for generator \
           iterations." )
    ; "overview", overview_json ~calibration ~recent_verdicts
    ; "calibration", calibration
    ; "recent_verdicts", `List (List.map verdict_item_json recent_verdicts)
    ]
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

let record_operator_label ~base_path ~labeler
    { label_notes_hash; label_verdict; label_reason } =
  Eval_calibration.record_human_label ~base_path ~notes_hash:label_notes_hash
    ~human_verdict:label_verdict ~labeler ~reason:label_reason
;;
