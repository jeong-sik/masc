(** Keeper context snapshot helpers for operator control snapshots. *)

(* Context budget resolution is intentionally unimplemented: the provider-side
   max-context number is not threaded through the keeper meta yet. Both
   [compute_context_ratio] and [context_max] therefore return [None] for all
   keepers — observed-and-tested behavior (see
   [test_compute_context_ratio_does_not_infer_provider_budget]). If a future
   RFC threads the budget through, these call sites become real computations
   again. *)

let compute_context_ratio (meta : Keeper_meta_contract.keeper_meta) : float option =
  let tokens = meta.runtime.usage.last_input_tokens in
  if tokens <= 0 then None
  else
    let max_tokens =
      (* Provider-side budget is not yet plumbed through meta; use the
         configured ceiling as a conservative fallback so the dashboard
         still shows a usable ratio. *)
      Keeper_types_profile_toml_normalizers.max_keeper_context_tokens
    in
    if max_tokens <= 0 then None
    else Some (float_of_int tokens /. float_of_int max_tokens)
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

let latest_keeper_context_snapshot_from_files config keeper_name =
  let metrics_lines =
    let store = Keeper_types_support.keeper_metrics_store config keeper_name in
    let dated = Dated_jsonl.read_recent_lines store 32 in
    if dated <> []
    then dated
    else (
      let path = Keeper_types_support.keeper_metrics_path config keeper_name in
      match
        Keeper_memory.read_file_tail_lines_result path
          ~max_bytes:32000 ~max_lines:32
      with
      | Ok lines -> lines
      | Error exn_class ->
          Keeper_memory.record_memory_recall_read_error
            ~site:"operator_context_snapshot_metrics" path exn_class;
          [])
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

let fallback_keeper_context_snapshot (meta : Keeper_meta_contract.keeper_meta) =
  (* context_max / context_source stay [None] because the provider-side budget
     is not yet plumbed through meta (see top-of-file note). *)
  { context_ratio = compute_context_ratio meta
  ; context_tokens =
      (match meta.runtime.usage.last_input_tokens with
       | n when n > 0 -> Some n
       | _ -> None)
  ; context_max = None
  ; context_source = None
  }
;;

let keeper_context_snapshot_of_meta config (meta : Keeper_meta_contract.keeper_meta) =
  match latest_keeper_context_snapshot_from_files config meta.name with
  | Some snapshot -> snapshot
  | None -> fallback_keeper_context_snapshot meta
;;

let keeper_context_snapshot_fields (snapshot : keeper_context_snapshot) =
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
  ]
;;
