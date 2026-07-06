(** Keeper context snapshot helpers for operator control snapshots. *)

(* Context budget resolution is intentionally unimplemented: the provider-side
   max-context number is not threaded through the keeper meta yet. Both
   [compute_context_ratio] and [context_max] therefore return [None] for all
   keepers — observed-and-tested behavior (see
   [test_compute_context_ratio_does_not_infer_provider_budget]). If a future
   RFC threads the budget through, these call sites become real computations
   again. *)

let compute_context_ratio (meta : Keeper_meta_contract.keeper_meta) : float option =
  let resolution = Keeper_context_runtime.resolve_max_context_resolution_of_meta meta in
  let max_tokens = resolution.effective_budget in
  let last_tokens = meta.runtime.usage.last_input_tokens in
  if max_tokens > 0 && last_tokens > 0 then
    let ratio = float_of_int last_tokens /. float_of_int max_tokens in
    Some (Float.max 0.0 (Float.min 1.0 ratio))
  else
    None
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
            | Some _ | None -> Some "metrics_log"))
    }
  in
  if keeper_context_snapshot_is_empty snapshot then None else Some snapshot
;;

let latest_keeper_context_snapshot_from_files_with_read_errors config keeper_name =
  let metrics_lines, line_path =
    let store = Keeper_types_support.keeper_metrics_store config keeper_name in
    let dated = Dated_jsonl.read_recent_lines store 32 in
    if dated <> []
    then dated, Dated_jsonl.base_dir store
    else (
      let path = Keeper_types_support.keeper_metrics_path config keeper_name in
      match
        Keeper_memory.read_file_tail_lines_result path
          ~max_bytes:32000 ~max_lines:32
      with
      | Ok lines -> lines, path
      | Error exn_class ->
          Keeper_memory.record_memory_recall_read_error
            ~site:"operator_context_snapshot_metrics" path exn_class;
          [], path)
  in
  let parsed_metrics, parse_errors =
    Keeper_status_metrics.parse_metrics_json_lines metrics_lines
  in
  let read_errors =
    List.map
      (Keeper_status_metrics.metrics_json_line_parse_error_to_json
         ~source:"operator_context_snapshot_metrics_jsonl"
         ~keeper:keeper_name
         ~path:line_path)
      parse_errors
  in
  let snapshots =
    List.rev parsed_metrics
    |> List.filter_map keeper_context_snapshot_from_metrics_json
  in
  let snapshot =
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
  in
  snapshot, read_errors
;;

let latest_keeper_context_snapshot_from_files config keeper_name =
  fst (latest_keeper_context_snapshot_from_files_with_read_errors config keeper_name)
;;

let fallback_keeper_context_snapshot (meta : Keeper_meta_contract.keeper_meta) =
  let resolution = Keeper_context_runtime.resolve_max_context_resolution_of_meta meta in
  let max_tokens = resolution.effective_budget in
  { context_ratio = compute_context_ratio meta
  ; context_tokens =
      (match meta.runtime.usage.last_input_tokens with
       | n when n > 0 -> Some n
       | _ -> None)
  ; context_max = if max_tokens > 0 then Some max_tokens else None
  ; context_source = Some "fallback_metadata"
  }
;;

let keeper_context_snapshot_of_meta config (meta : Keeper_meta_contract.keeper_meta) =
  match latest_keeper_context_snapshot_from_files config meta.name with
  | Some snapshot -> snapshot
  | None -> fallback_keeper_context_snapshot meta
;;

let keeper_context_snapshot_of_meta_with_read_errors config
    (meta : Keeper_meta_contract.keeper_meta) =
  let snapshot, read_errors =
    latest_keeper_context_snapshot_from_files_with_read_errors config meta.name
  in
  match snapshot with
  | Some snapshot -> snapshot, read_errors
  | None -> fallback_keeper_context_snapshot meta, read_errors
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
  ; ( "context", `Assoc assoc_fields )
  ]
;;
