module Precondition = Request_workspace_precondition

let served_workspace () =
  match Server_auth.current_server_state () with
  | None -> None
  | Some state ->
    let config = Mcp_server.workspace_config state in
    let base_path, masc_root =
      Server_base_path_diagnostics.served_paths
        ~cwd:(Config_dir_resolver.current_working_dir ())
        ~effective_base_path:config.base_path
        ~effective_masc_root:(Workspace.masc_dir config)
    in
    Some { Precondition.base_path; masc_root }
;;

let check_request ~served ~ready ~path (request : Httpun.Request.t) =
  if String.equal path Server_health_paths.health
  then Precondition.No_precondition
  else (
    match
      Precondition.parse
        ~expected_base_path:
          (Httpun.Headers.get_multi request.headers Precondition.expected_base_path_header)
        ~expected_masc_root:
          (Httpun.Headers.get_multi request.headers Precondition.expected_masc_root_header)
    with
    | Error refusal -> Precondition.Refused refusal
    | Ok None -> Precondition.No_precondition
    | Ok (Some expected) -> Precondition.decide expected ~served:(served ()) ~ready)
;;

let check_current_request ~path request =
  check_request
    ~served:served_workspace
    ~ready:(Server_startup_state.snapshot ()).state_ready
    ~path
    request
;;

let refusal_status = function
  | Precondition.Invalid_precondition _ -> `Bad_request
  | Precondition.Workspace_mismatch -> `Conflict
  | Precondition.Server_booting -> `Service_unavailable
;;

let refusal_headers = function
  | Precondition.Server_booting -> Server_auth.not_initialized_headers
  | Precondition.Invalid_precondition _ | Precondition.Workspace_mismatch -> []
;;

let refusal_body refusal =
  Server_refusal.json
    ~code:(Precondition.refusal_code refusal)
    (Precondition.refusal_message refusal)
;;

let guard_http1 ~path request reqd ~admitted =
  match check_current_request ~path request with
  | Precondition.Refused refusal ->
    Http_server_eio.Response.json_value
      ~status:(refusal_status refusal)
      (* Use the same admitted-origin policy as other early refusals. *)
      ~extra_headers:(refusal_headers refusal @ Server_auth.auth_error_cors_headers request)
      (refusal_body refusal)
      reqd
  | Precondition.No_precondition | Precondition.Precondition_met -> admitted ()
;;
