(** Operator action-log subsystem, extracted from
    [operator_control_snapshot.ml] (godfile decomp).

    Three types + four helpers + one path constant form the audit
    trail for every operator-initiated action against MASC. The
    cluster is `include`d into [Operator_control_snapshot] (which is
    in turn `include`d up the chain into [Operator_control]) so all
    type identities and value bindings flow through unchanged.

    Wire schema: every operator action (keeper spawn, restart, pause,
    cascade switch, etc.) is appended as one JSONL line to
    `<operator_dir>/action_log.jsonl`. The schema covers identity
    (trace_id, actor, remote session/client), target (type/id), the
    delegated tool, confirmation state (preview/immediate/expired/
    denied/confirmed), result (ok/error), latency, and timestamp.

    [recent_actions_json] returns the trailing 20 entries via a
    bounded ring buffer ([Queue.t]) so the JSONL never materializes
    as a full in-memory list — the operator dashboard polls this
    surface frequently and a multi-MB log shouldn't penalize each
    poll. *)

type action_result_status =
  | ActionOk
  | ActionError

let action_result_status_to_string = function
  | ActionOk -> "ok"
  | ActionError -> "error"
;;

type confirmation_state =
  | Preview
  | Immediate
  | Expired
  | Denied
  | Confirmed

let confirmation_state_to_string = function
  | Preview -> "preview"
  | Immediate -> "immediate"
  | Expired -> "expired"
  | Denied -> "denied"
  | Confirmed -> "confirmed"
;;

type action_log_entry =
  { trace_id : string
  ; actor : string
  ; remote_session_id : string option
  ; remote_client_type : string
  ; action_type : string
  ; target_type : string
  ; target_id : string option
  ; delegated_tool : string
  ; confirmation_state : confirmation_state
  ; result_status : action_result_status
  ; latency_ms : int
  ; created_at : string
  }

let action_log_path config =
  Filename.concat (Operator_pending_confirm.operator_dir config) "action_log.jsonl"
;;

let action_log_entry_to_yojson (entry : action_log_entry) =
  `Assoc
    [ "trace_id", `String entry.trace_id
    ; "actor", `String entry.actor
    ; "remote_session_id", Operator_pending_confirm.string_option_to_json entry.remote_session_id
    ; "remote_client_type", `String entry.remote_client_type
    ; "action_type", `String entry.action_type
    ; "target_type", `String entry.target_type
    ; "target_id", Operator_pending_confirm.string_option_to_json entry.target_id
    ; "delegated_tool", `String entry.delegated_tool
    ; ( "confirmation_state"
      , `String (confirmation_state_to_string entry.confirmation_state) )
    ; "result_status", `String (action_result_status_to_string entry.result_status)
    ; "latency_ms", `Int entry.latency_ms
    ; "created_at", `String entry.created_at
    ]
;;

let append_action_log config (entry : action_log_entry) =
  Coord_utils.mkdir_p (Operator_pending_confirm.operator_dir config);
  Fs_compat.append_jsonl (action_log_path config) (action_log_entry_to_yojson entry)
;;

let recent_actions_json config =
  let path = action_log_path config in
  if not (Sys.file_exists path)
  then `List []
  else (
    (* Bounded ring — keep the trailing 20 entries via [Queue.t] so the
       action log JSONL does not need to materialise as a full list. *)
    let buf : Yojson.Safe.t Queue.t = Queue.create () in
    Fs_compat.fold_jsonl_lines
      ~init:()
      ~f:(fun () ~line_no:_ json ->
        Queue.add json buf;
        if Queue.length buf > 20 then ignore (Queue.pop buf))
      path;
    `List (List.of_seq (Queue.to_seq buf)))
;;
