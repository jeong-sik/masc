module Precondition = Request_workspace_precondition

let served_workspace : Precondition.identity option Atomic.t = Atomic.make None

let publish_served_workspace ~base_path ~masc_root =
  Atomic.set served_workspace (Some { Precondition.base_path; masc_root })
;;

let check_request ~identity ~ready ~path (request : Httpun.Request.t) =
  if String.equal path Server_health_paths.health
  then Precondition.No_precondition
  else
    Precondition.decide
      ~identity
      ~ready
      ~expected_base_path:
        (Httpun.Headers.get_multi request.headers Precondition.expected_base_path_header)
      ~expected_masc_root:
        (Httpun.Headers.get_multi request.headers Precondition.expected_masc_root_header)
;;

let check_current_request ~path request =
  check_request
    ~identity:(Atomic.get served_workspace)
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
      ~extra_headers:(refusal_headers refusal)
      (refusal_body refusal)
      reqd
  | Precondition.No_precondition | Precondition.Precondition_met -> admitted ()
;;
