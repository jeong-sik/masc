type t = {
  ok : bool;
  status : Yojson.Safe.t;
  timeout_fields : (string * Yojson.Safe.t) list;
}

let of_status ~status ~timeout_budget =
  let ok =
    match status with
    | Unix.WEXITED 0 -> true
    | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false
  in
  let timeout_fields =
    match Process_eio.exit_reason_of_status status, timeout_budget with
    | Process_eio.Timed_out, Keeper_tool_execute_input.Default seconds ->
      [ "timeout", `Assoc [ "limit_sec", `Float seconds; "source", `String "default" ] ]
    | Process_eio.Timed_out, Keeper_tool_execute_input.Named_by_caller seconds ->
      [ ( "timeout"
        , `Assoc [ "limit_sec", `Float seconds; "source", `String "timeout_sec" ] )
      ]
    | ( (Process_eio.Completed _ | Process_eio.Signaled _ | Process_eio.Stopped _)
      , _ ) -> []
  in
  { ok
  ; status = Keeper_alerting_path.process_status_to_json status
  ; timeout_fields
  }
;;
