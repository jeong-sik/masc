(* HIGH-RISK-UNREVIEWED: a voice endpoint that names a key variable sends that
   key, an account of the host. The variable is read only with the proof that
   the access shares the accounts of the host (plan D4d). *)

let missing (adapter : Voice_runtime_overlay.adapter) (endpoint : Voice_config.endpoint) env_name =
  Printf.sprintf
    "voice provider %s (endpoint %s) expects %s to be set to a non-empty value"
    adapter.canonical_name
    endpoint.id
    env_name
;;

let read (_ : Runtime_account_access.host_account) adapter endpoint env_name =
  match Sys.getenv_opt env_name with
  | Some value ->
    let trimmed = String.trim value in
    if trimmed <> "" then Ok trimmed else Error (missing adapter endpoint env_name)
  | None -> Error (missing adapter endpoint env_name)
;;

let resolve endpoint =
  match Voice_runtime_overlay.endpoint_auth_env_name endpoint with
  | None -> Ok ""
  | Some env_name ->
    (match Runtime_account_access.authorize_host Runtime_account_access.Voice_endpoint with
     | Error refusal -> Error (Runtime_account_access.refusal_to_string refusal)
     | Ok host -> read host (Voice_runtime_overlay.adapter_for_endpoint endpoint) endpoint env_name)
;;
