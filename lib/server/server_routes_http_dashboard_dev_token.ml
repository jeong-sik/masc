(** Dashboard dev-token cluster, extracted from
    [server_routes_http_routes_dashboard.ml]. Wraps the on-disk dev-token
    file, classifies stored candidates, mints when
    missing, and exposes the high-level [ensure_dashboard_dev_token]
    that the dashboard route handlers depend on. *)

let dashboard_dev_actor_name = "dashboard"

type request_error =
  | Non_loopback_request_host of string
  | Token_operation_failed of string

let request_error_status : request_error -> Httpun.Status.t = function
  | Non_loopback_request_host _ -> `Forbidden
  | Token_operation_failed _ -> `Internal_server_error
;;

let request_error_code = function
  | Non_loopback_request_host _ -> "dashboard_dev_token_host_non_loopback"
  | Token_operation_failed _ -> "dashboard_dev_token_operation_failed"
;;

let request_error_to_string = function
  | Non_loopback_request_host host ->
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

let default_dashboard_dev_token_load path = Fs_compat.load_file path
let dashboard_dev_token_load = Atomic.make default_dashboard_dev_token_load

let set_dashboard_dev_token_load_for_testing load =
  Atomic.set dashboard_dev_token_load load

let reset_dashboard_dev_token_load_for_testing () =
  Atomic.set dashboard_dev_token_load default_dashboard_dev_token_load

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
              ((Atomic.get dashboard_dev_token_load) path) with
      | Ok (Reusable raw) -> Ok (Some raw)
      | Ok Rotate -> Ok None
      | Error msg -> Error msg
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Error
          (Printf.sprintf "read dev-token %s: %s"
             path (Printexc.to_string exn))

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

let ensure_dashboard_dev_token_for_authority ~request_authority ~base_path =
  let host = Server_request_authority.host request_authority in
  if not (Server_auth.is_loopback_host host)
  then Error (Non_loopback_request_host host)
  else
    Result.map_error
      (fun detail -> Token_operation_failed detail)
      (ensure_dashboard_dev_token base_path)
;;
