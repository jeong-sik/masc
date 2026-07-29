(** Keeper context snapshot helpers for operator control snapshots. *)

type context_metrics_unavailable_reason =
  | Context_measurement_missing
  | Storage_read_failed of Dated_jsonl.read_error
  | Malformed_metrics_row of
      { path : string
      ; line_number : int option
      ; detail : string
      }

type keeper_context_snapshot =
  { context_ratio : float option
  ; context_tokens : int option
  ; context_max : int option
  ; context_source : string option
  ; context_metrics_unavailable : context_metrics_unavailable_reason option
  }

let keeper_context_snapshot_is_empty (snapshot : keeper_context_snapshot) =
  snapshot.context_ratio = None
  && snapshot.context_tokens = None
  && snapshot.context_max = None
  && snapshot.context_source = None
  && snapshot.context_metrics_unavailable = None
;;

let keeper_context_snapshot_from_metrics_json (json : Yojson.Safe.t) =
  match
    ( Safe_ops.json_string_opt "snapshot_source" json
    , Safe_ops.json_float_opt "context_ratio" json
    , Safe_ops.json_int_opt "context_tokens" json
    , Safe_ops.json_int_opt "context_max" json )
  with
  | Some "keeper_context_status", Some ratio, Some tokens, Some max_tokens
    when Float.is_finite ratio
         && ratio >= 0.0
         && ratio <= 1.0
         && tokens >= 0
         && max_tokens > 0 ->
    Some
      { context_ratio = Some ratio
      ; context_tokens = Some tokens
      ; context_max = Some max_tokens
      ; context_source = Some "keeper_context_status"
      ; context_metrics_unavailable = None
      }
  | _ -> None
;;

let latest_keeper_context_snapshot_from_files config keeper_name =
  let ( let* ) = Result.bind in
  let store = Keeper_types_support.keeper_metrics_store config keeper_name in
  let* entries =
    Dated_jsonl.read_recent_result store 32
    |> Result.map_error (fun error -> Storage_read_failed error)
  in
  let rec snapshots_newest_first snapshots = function
    | [] -> Ok snapshots
    | Dated_jsonl.Parsed json :: rest ->
      let snapshots =
        match keeper_context_snapshot_from_metrics_json json with
        | Some snapshot -> snapshot :: snapshots
        | None -> snapshots
      in
      snapshots_newest_first snapshots rest
    | Dated_jsonl.Malformed_json { path; line_number; detail } :: _ ->
      Error (Malformed_metrics_row { path; line_number; detail })
  in
  let* snapshots = snapshots_newest_first [] entries in
  match snapshots with
  | snapshot :: _ -> Ok (Some snapshot)
  | [] -> Ok None
;;

let missing_keeper_context_snapshot () =
  { context_ratio = None
  ; context_tokens = None
  ; context_max = None
  ; context_source = None
  ; context_metrics_unavailable = Some Context_measurement_missing
  }
;;

let keeper_context_snapshot_of_meta config (meta : Keeper_meta_contract.keeper_meta) =
  match latest_keeper_context_snapshot_from_files config meta.name with
  | Ok (Some snapshot) -> snapshot
  | Ok None -> missing_keeper_context_snapshot ()
  | Error error ->
    { context_ratio = None
    ; context_tokens = None
    ; context_max = None
    ; context_source = None
    ; context_metrics_unavailable = Some error
    }
;;

let dated_jsonl_read_error_code = function
  | Dated_jsonl.Invalid_offset _ -> "invalid_offset"
  | Dated_jsonl.Invalid_date_range _ -> "invalid_date_range"
  | Dated_jsonl.Not_a_directory _ -> "not_a_directory"
  | Dated_jsonl.Invalid_layout_entry _ -> "invalid_layout_entry"
  | Dated_jsonl.Non_regular_file _ -> "non_regular_file"
  | Dated_jsonl.Io_error _ -> "io_error"
;;

let dated_jsonl_read_error_path = function
  | Dated_jsonl.Invalid_offset _
  | Dated_jsonl.Invalid_date_range _ -> None
  | Dated_jsonl.Not_a_directory { path }
  | Dated_jsonl.Non_regular_file { path; _ }
  | Dated_jsonl.Io_error { path; _ } -> Some path
  | Dated_jsonl.Invalid_layout_entry { parent; entry; _ } ->
    Some (Filename.concat parent entry)
;;

let context_metrics_unavailable_json = function
  | None -> `Null
  | Some Context_measurement_missing ->
    `Assoc
      [ "kind", `String "not_observed"
      ; "reason", `String "context_measurement_missing"
      ]
  | Some (Storage_read_failed error) ->
    `Assoc
      [ "kind", `String "storage_read_failed"
      ; "reason", `String (dated_jsonl_read_error_code error)
      ; "path", Json_util.string_opt_to_json (dated_jsonl_read_error_path error)
      ; "detail", `String (Dated_jsonl.read_error_to_string error)
      ]
  | Some (Malformed_metrics_row { path; line_number; detail }) ->
    `Assoc
      [ "kind", `String "malformed_json"
      ; "reason", `String "malformed_metrics_row"
      ; "path", `String path
      ; "line_number", Json_util.int_opt_to_json line_number
      ; "detail", `String detail
      ]
;;

let keeper_context_snapshot_fields (snapshot : keeper_context_snapshot) =
  let assoc_fields =
    [ ( "source"
      , Json_util.string_opt_to_json snapshot.context_source )
    ; ( "context_ratio"
      , Json_util.option_to_yojson
          (fun value -> `Float value)
          snapshot.context_ratio )
    ; ( "context_tokens"
      , Json_util.option_to_yojson
          (fun value -> `Int value)
          snapshot.context_tokens )
    ; ( "context_max"
      , Json_util.option_to_yojson
          (fun value -> `Int value)
          snapshot.context_max )
    ; ( "metrics_unavailable"
      , context_metrics_unavailable_json snapshot.context_metrics_unavailable )
    ]
  in
  [ ( "context_ratio"
    , Json_util.option_to_yojson
        (fun value -> `Float value)
        snapshot.context_ratio )
  ; ( "context_tokens"
    , Json_util.option_to_yojson
        (fun value -> `Int value)
        snapshot.context_tokens )
  ; ( "context_max"
    , Json_util.option_to_yojson
        (fun value -> `Int value)
        snapshot.context_max )
  ; ( "context_source"
    , Json_util.string_opt_to_json snapshot.context_source )
  ; ( "context_metrics_unavailable"
    , context_metrics_unavailable_json snapshot.context_metrics_unavailable )
  ; ( "context", `Assoc assoc_fields )
  ]
;;

type keeper_last_turn_usage =
  { input_tokens : int
  ; output_tokens : int
  ; total_tokens : int
  ; observed_at : string option
  }

let keeper_last_turn_usage_of_meta (meta : Keeper_meta_contract.keeper_meta) =
  let usage = meta.runtime.usage in
  if usage.last_input_tokens <= 0
     && usage.last_output_tokens <= 0
     && usage.last_total_tokens <= 0
  then
    None
  else
    Some
      { input_tokens = usage.last_input_tokens
      ; output_tokens = usage.last_output_tokens
      ; total_tokens = usage.last_total_tokens
      ; observed_at =
          (if usage.last_turn_ts > 0.0
           then Some (Masc_domain.iso8601_of_unix_seconds usage.last_turn_ts)
           else None)
      }
;;

let keeper_last_turn_usage_to_json = function
  | None -> `Null
  | Some usage ->
    `Assoc
      [ "input_tokens", `Int usage.input_tokens
      ; "output_tokens", `Int usage.output_tokens
      ; "total_tokens", `Int usage.total_tokens
      ; "observed_at", Json_util.string_opt_to_json usage.observed_at
      ; "source", `String "keeper_runtime_usage"
      ]
;;
