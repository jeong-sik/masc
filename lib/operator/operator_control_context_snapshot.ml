(** Keeper context snapshot helpers for operator control snapshots. *)

let ratio_of_tokens ~max_tokens ~last_tokens =
  if max_tokens > 0 && last_tokens > 0 then
    let ratio = float_of_int last_tokens /. float_of_int max_tokens in
    Some (Float.max 0.0 (Float.min 1.0 ratio))
  else
    None
;;

let compute_context_ratio (meta : Keeper_meta_contract.keeper_meta) : float option =
  match Keeper_context_runtime.observe_max_context_resolution_of_meta meta with
  | Keeper_context_runtime.Available { resolution; _ } ->
    ratio_of_tokens
      ~max_tokens:resolution.effective_budget
      ~last_tokens:meta.runtime.usage.last_input_tokens
  | Keeper_context_runtime.Unavailable _ -> None
;;

type context_metrics_read_error =
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
  ; context_unavailable_reason : Keeper_context_runtime.max_context_resolution_error option
  ; context_metrics_unavailable : context_metrics_read_error option
  }

let keeper_context_snapshot_is_empty (snapshot : keeper_context_snapshot) =
  snapshot.context_ratio = None
  && snapshot.context_tokens = None
  && snapshot.context_max = None
  && snapshot.context_source = None
  && snapshot.context_unavailable_reason = None
  && snapshot.context_metrics_unavailable = None
;;

let keeper_context_snapshot_from_metrics_json (json : Yojson.Safe.t) =
  let snapshot =
    let context_max =
      match Safe_ops.json_int_opt "context_max" json with
      | Some value when value > 0 -> Some value
      | Some _ | None -> None
    in
    { context_ratio = Safe_ops.json_float_opt "context_ratio" json
    ; context_tokens = Safe_ops.json_int_opt "context_tokens" json
    ; context_max
    ; context_source =
        (match Safe_ops.json_string_opt "snapshot_source" json with
         | Some source when String.trim source <> "" -> Some source
         | _ ->
           (match Safe_ops.json_string_opt "channel" json with
            | Some channel when String.trim channel <> "" ->
              Some ("metrics_" ^ String.trim channel)
            | Some _ | None -> Some "metrics_log"))
    ; context_unavailable_reason = None
    ; context_metrics_unavailable = None
    }
  in
  if keeper_context_snapshot_is_empty snapshot then None else Some snapshot
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
  match
    List.find_opt
      (fun snapshot -> snapshot.context_source = Some "keeper_context_status")
      snapshots
  with
  | Some snapshot -> Ok (Some snapshot)
  | None -> Ok (List.hd_opt snapshots)
;;

let apply_capacity_observation meta snapshot =
  match Keeper_context_runtime.observe_max_context_resolution_of_meta meta with
  | Keeper_context_runtime.Available { resolution; _ } ->
    let context_ratio =
      match snapshot.context_tokens with
      | Some last_tokens ->
        ratio_of_tokens ~max_tokens:resolution.effective_budget ~last_tokens
      | None -> None
    in
    { snapshot with
      context_ratio
    ; context_max = Some resolution.effective_budget
    ; context_unavailable_reason = None
    }
  | Keeper_context_runtime.Unavailable { reason; _ } ->
    { snapshot with
      context_ratio = None
    ; context_max = None
    ; context_unavailable_reason = Some reason
    }
;;

let fallback_keeper_context_snapshot (meta : Keeper_meta_contract.keeper_meta) =
  let context_tokens =
    match meta.runtime.usage.last_input_tokens with
    | n when n > 0 -> Some n
    | _ -> None
  in
  apply_capacity_observation
    meta
    { context_ratio = None
    ; context_tokens
    ; context_max = None
    ; context_source = Some "fallback_metadata"
    ; context_unavailable_reason = None
    ; context_metrics_unavailable = None
    }
;;

let keeper_context_snapshot_of_meta config (meta : Keeper_meta_contract.keeper_meta) =
  match latest_keeper_context_snapshot_from_files config meta.name with
  | Ok (Some snapshot) -> apply_capacity_observation meta snapshot
  | Ok None -> fallback_keeper_context_snapshot meta
  | Error error ->
    apply_capacity_observation
      meta
      { context_ratio = None
      ; context_tokens = None
      ; context_max = None
      ; context_source = None
      ; context_unavailable_reason = None
      ; context_metrics_unavailable = Some error
      }
;;

let dated_jsonl_read_error_code = function
  | Dated_jsonl.Invalid_offset _ -> "invalid_offset"
  | Dated_jsonl.Not_a_directory _ -> "not_a_directory"
  | Dated_jsonl.Invalid_layout_entry _ -> "invalid_layout_entry"
  | Dated_jsonl.Non_regular_file _ -> "non_regular_file"
  | Dated_jsonl.Io_error _ -> "io_error"
;;

let context_metrics_unavailable_json = function
  | None -> `Null
  | Some (Storage_read_failed error) ->
    `Assoc
      [ "kind", `String "storage_read_failed"
      ; "reason", `String (dated_jsonl_read_error_code error)
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
  let unavailable_reason =
    match snapshot.context_unavailable_reason with
    | Some error -> `String (Keeper_context_runtime.max_context_resolution_error_code error)
    | None -> `Null
  in
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
    ; "unavailable_reason", unavailable_reason
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
  ; "context_unavailable_reason", unavailable_reason
  ; ( "context_metrics_unavailable"
    , context_metrics_unavailable_json snapshot.context_metrics_unavailable )
  ; ( "context", `Assoc assoc_fields )
  ]
;;
