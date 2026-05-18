let resolved_context_budget_of_meta (meta : Keeper_types.keeper_meta) : int option =
  let _ = meta in
  None
;;

let compute_context_ratio (meta : Keeper_types.keeper_meta) : float option =
  let input_tokens = meta.runtime.usage.last_input_tokens in
  if input_tokens = 0
  then None
  else (
    match resolved_context_budget_of_meta meta with
    | Some max_ctx -> Some (float_of_int input_tokens /. float_of_int max_ctx)
    | None -> None)
;;

type keeper_context_snapshot =
  { context_ratio : float option
  ; context_tokens : int option
  ; context_max : int option
  ; context_source : string option
  }

let keeper_context_snapshot_is_empty (snapshot : keeper_context_snapshot) =
  snapshot.context_ratio = None
  && snapshot.context_tokens = None
  && snapshot.context_max = None
  && snapshot.context_source = None
;;

let keeper_context_snapshot_from_metrics_json (json : Yojson.Safe.t) =
  let snapshot =
    { context_ratio = Safe_ops.json_float_opt "context_ratio" json
    ; context_tokens = Safe_ops.json_int_opt "context_tokens" json
    ; context_max = Safe_ops.json_int_opt "context_max" json
    ; context_source =
        (match Safe_ops.json_string_opt "snapshot_source" json with
         | Some source when String.trim source <> "" -> Some source
         | _ ->
           (match Safe_ops.json_string_opt "channel" json with
            | Some channel when String.trim channel <> "" ->
              Some ("metrics_" ^ String.trim channel)
            | _ -> Some "metrics_log"))
    }
  in
  if keeper_context_snapshot_is_empty snapshot then None else Some snapshot
;;

let latest_keeper_context_snapshot_from_files config keeper_name =
  let metrics_lines =
    let store = Keeper_types.keeper_metrics_store config keeper_name in
    let dated = Dated_jsonl.read_recent_lines store 32 in
    if dated <> []
    then dated
    else (
      let path = Keeper_types.keeper_metrics_path config keeper_name in
      Keeper_memory.read_file_tail_lines path ~max_bytes:32000 ~max_lines:32)
  in
  let snapshots =
    List.rev metrics_lines
    |> List.filter_map (fun line ->
      try
        let json = Yojson.Safe.from_string line in
        keeper_context_snapshot_from_metrics_json json
      with
      | Yojson.Json_error _ -> None)
  in
  match
    List.find_opt
      (fun snapshot -> snapshot.context_source = Some "keeper_context_status")
      snapshots
  with
  | Some snapshot -> Some snapshot
  | None ->
    (match snapshots with
     | snapshot :: _ -> Some snapshot
     | [] -> None)
;;

let fallback_keeper_context_snapshot (meta : Keeper_types.keeper_meta) =
  { context_ratio = compute_context_ratio meta
  ; context_tokens =
      (match meta.runtime.usage.last_input_tokens with
       | n when n > 0 -> Some n
       | _ -> None)
  ; context_max = resolved_context_budget_of_meta meta
  ; context_source =
      (match
         meta.runtime.usage.last_input_tokens, resolved_context_budget_of_meta meta
       with
       | n, Some _ when n > 0 -> Some "usage_last_input_tokens"
       | _ -> None)
  }
;;

let keeper_context_snapshot_of_meta config (meta : Keeper_types.keeper_meta) =
  match latest_keeper_context_snapshot_from_files config meta.name with
  | Some snapshot -> snapshot
  | None -> fallback_keeper_context_snapshot meta
;;

let keeper_context_snapshot_fields (snapshot : keeper_context_snapshot) =
  [ ( "context_ratio"
    , Operator_pending_confirm.option_to_json (fun value -> `Float value) snapshot.context_ratio )
  ; ( "context_tokens"
    , Operator_pending_confirm.option_to_json (fun value -> `Int value) snapshot.context_tokens )
  ; ( "context_max"
    , Operator_pending_confirm.option_to_json (fun value -> `Int value) snapshot.context_max )
  ; "context_source", Operator_pending_confirm.string_option_to_json snapshot.context_source
  ]
;;
