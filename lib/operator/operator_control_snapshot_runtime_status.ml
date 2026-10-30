(** Context helpers for operator_control snapshot, extracted from
    [operator_control_snapshot.ml]. *)

open Operator_pending_confirm

let remote_confirm_ttl_seconds = 900.0

let remote_client_type_of_context (ctx : 'a context) =
  match ctx.mcp_session_id with
  | Some _ -> "mcp_remote"
  | None -> "local_api"
;;

let operator_server_profile_json =
  `Assoc
    [ "name", `String "operator_remote_v1"
    ; "transport", `String "mcp_streamable_http"
    ; "auth", `String "bearer_token"
    ]
;;
