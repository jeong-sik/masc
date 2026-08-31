type t = {
  ok : bool;
  status : Yojson.Safe.t;
  error_fields : (string * Yojson.Safe.t) list;
  timeout_fields : (string * Yojson.Safe.t) list;
}

let of_status ~status ~stderr ~timeout_budget =
  let ok =
    match status with
    | Unix.WEXITED 0 -> true
    | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false
  in
  (* A successful command's stderr is not an error, and an empty stderr is not
     a message. Both halves have to hold or the payload grows an [error] field
     for a call that worked. *)
  let error_fields =
    match status, String.trim stderr with
    | Unix.WEXITED 0, _ | _, "" -> []
    | _, stderr -> [ "error", `String stderr; "stderr", `String stderr ]
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
  ; error_fields
  ; timeout_fields
  }
;;
