(** Dashboard dev-token cluster, extracted from
    [server_routes_http_routes_dashboard.ml]. Wraps the on-disk dev-token
    file, classifies stored candidates, mints when
    missing, and exposes the high-level [ensure_dashboard_dev_token]
    that the dashboard route handlers depend on. *)

let dashboard_dev_actor_name = "dashboard"

type request_error =
  | Request_host_rejected of Server_auth.request_host_rejection
  | Token_operation_failed of string

let request_error_status : request_error -> Httpun.Status.t = function
  | Request_host_rejected
      ( Server_auth.Missing_request_host
      | Server_auth.Multiple_request_hosts
      | Server_auth.Malformed_request_host ) ->
    `Bad_request
  | Request_host_rejected (Server_auth.Non_loopback_request_host _) -> `Forbidden
  | Token_operation_failed _ -> `Internal_server_error
;;

let request_error_code = function
  | Request_host_rejected Server_auth.Missing_request_host ->
    "dashboard_dev_token_host_missing"
  | Request_host_rejected Server_auth.Multiple_request_hosts ->
    "dashboard_dev_token_host_multiple"
  | Request_host_rejected Server_auth.Malformed_request_host ->
    "dashboard_dev_token_host_malformed"
  | Request_host_rejected (Server_auth.Non_loopback_request_host _) ->
    "dashboard_dev_token_host_non_loopback"
  | Token_operation_failed _ -> "dashboard_dev_token_operation_failed"
;;

let request_error_to_string = function
  | Request_host_rejected Server_auth.Missing_request_host ->
    "dashboard dev-token request is missing the Host header"
  | Request_host_rejected Server_auth.Multiple_request_hosts ->
    "dashboard dev-token request contains more than one Host header field"
  | Request_host_rejected Server_auth.Malformed_request_host ->
    "dashboard dev-token request has a malformed Host authority"
  | Request_host_rejected (Server_auth.Non_loopback_request_host host) ->
    Printf.sprintf
      "dashboard dev-token request Host %S is not an exact loopback host"
      host
  | Token_operation_failed detail -> detail
;;

let dashboard_dev_token_path base_path =
  Filename.concat
    (Filename.concat (Common.masc_dir_from_base_path ~base_path) "auth")
    "dashboard.token"

type dashboard_dev_token_candidate =
  | Reusable of string
  | Rotate

let classify_dashboard_dev_token_candidate ~base_path raw :
    (dashboard_dev_token_candidate, string) result =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then
    Ok Rotate
  else
    match Auth.resolve_agent_from_token base_path ~token:trimmed with
    | Ok owner when String.equal owner dashboard_dev_actor_name ->
        Ok (Reusable trimmed)
    | Ok _owner ->
        Ok Rotate
    | Error (Masc_domain.Auth (Masc_domain.Auth_error.InvalidToken _ | Masc_domain.Auth_error.TokenExpired _ | Masc_domain.Auth_error.Unauthorized _)) ->
        Ok Rotate
    | Error err ->
        Error (Masc_domain.masc_error_to_string err)

let read_reusable_dashboard_dev_token ~base_path path :
    (string option, string) result =
  if not (Fs_compat.file_exists path) then
    Ok None
  else
    try
      match classify_dashboard_dev_token_candidate ~base_path
              (Fs_compat.load_file path) with
      | Ok (Reusable raw) -> Ok (Some raw)
      | Ok Rotate -> Ok None
      | Error msg -> Error msg
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Log.Server.warn
          "dashboard dev-token read skipped for %s: %s"
          path (Printexc.to_string exn);
        Ok None

let persist_dashboard_dev_token ~base_path raw : (unit, string) result =
  let token_path = dashboard_dev_token_path base_path in
  try
    Auth.save_private_text_file token_path raw;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Error (Printf.sprintf "persist dev-token: %s" (Printexc.to_string exn))

let mint_dashboard_dev_token base_path : (string, string) result =
  match
    Auth.create_token base_path
      ~agent_name:dashboard_dev_actor_name ~role:Masc_domain.Admin
  with
  | Ok (raw, _cred) ->
      (match persist_dashboard_dev_token ~base_path raw with
       | Ok () -> Ok raw
       | Error msg -> Error msg)
  | Error err ->
      Error (Masc_domain.masc_error_to_string err)

let ensure_dashboard_dev_token base_path : (string, string) result =
  let token_path = dashboard_dev_token_path base_path in
  match read_reusable_dashboard_dev_token ~base_path token_path with
  | Error msg -> Error msg
  | Ok (Some raw) -> Ok raw
  | Ok None -> mint_dashboard_dev_token base_path

let ensure_dashboard_dev_token_for_request ~request ~base_path =
  match Server_auth.admit_loopback_request_host request with
  | Error rejection -> Error (Request_host_rejected rejection)
  | Ok _ ->
    Result.map_error
      (fun detail -> Token_operation_failed detail)
      (ensure_dashboard_dev_token base_path)
;;
