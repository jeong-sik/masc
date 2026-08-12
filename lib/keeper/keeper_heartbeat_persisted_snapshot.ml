(** Read-side projection of typed heartbeat rows from the Keeper metrics
    ledger. Kept separate from [Keeper_heartbeat_snapshot], whose writer loads
    Keeper context and therefore sits above status projection in the module
    dependency graph. *)

type t =
  { timestamp : string
  ; timestamp_unix : float
  }

let latest ~(config : Workspace.config) ~keeper_name =
  let store = Keeper_types_support.keeper_metrics_store config keeper_name in
  Dated_jsonl.find_latest_entry_result store (function
    | Dated_jsonl.Parsed json ->
      (match
         Keeper_metrics_record.kind_of_json json,
         Json_util.get_string_nonempty json "ts",
         Safe_ops.json_float_opt "ts_unix" json
       with
       | Some Keeper_metrics_record.Heartbeat, Some timestamp, Some timestamp_unix
         when Float.is_finite timestamp_unix && timestamp_unix > 0.0 ->
         Some { timestamp; timestamp_unix }
       | _ -> None)
    | Dated_jsonl.Malformed_json _ -> None)
  |> Result.map_error Dated_jsonl.read_error_to_string
;;
