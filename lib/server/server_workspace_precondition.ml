module Precondition = Request_workspace_precondition

let expected_instance_header = "x-masc-expected-instance"
let expected_workspace_header = "x-masc-expected-workspace"

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

type v2_guard_decision =
  | Guard_pass
  | Guard_refused of
      { status : Httpun.Status.t
      ; headers : (string * string) list
      ; body : Yojson.Safe.t
      }

let parse_single_optional_header ~name values =
  match values with
  | [] -> Ok None
  | [ raw ] ->
    let trimmed = String.trim raw in
    if String.equal trimmed ""
    then Error (Printf.sprintf "%s header is empty" name)
    else Ok (Some trimmed)
  | _ :: _ :: _ ->
    Error (Printf.sprintf "%s header is given more than once" name)
;;

let workspace_matches ~expected (served : Precondition.workspace) =
  String.equal expected served.base_path
  || String.equal
       (String.lowercase_ascii expected)
       (Auth.sha256_hash served.base_path)
;;

let invalid_guard_refusal message =
  Guard_refused
    { status = `Bad_request
    ; headers = []
    ; body =
        `Assoc
          [ "error", `String "invalid_workspace_precondition"
          ; "code", `String "invalid_workspace_precondition"
          ; "message", `String message
          ]
    }
;;

let mismatch_refusal ~reason ?expected_instance ?observed_instance ?observed_workspace_sha256 message =
  let extra =
    (match expected_instance with
     | Some value -> [ "expected_instance", `String value ]
     | None -> [])
    @ (match observed_instance with
       | Some value -> [ "observed_instance", `String value ]
       | None -> [])
    @ (match observed_workspace_sha256 with
       | Some value -> [ "observed_workspace_sha256", `String value ]
       | None -> [])
  in
  Guard_refused
    { status = `Conflict
    ; headers = []
    ; body =
        `Assoc
          ([ "error", `String "workspace_mismatch"
           ; "code", `String "workspace_mismatch"
           ; "reason", `String reason
           ; "message", `String message
           ]
           @ extra)
    }
;;

let booting_guard_refusal () =
  Guard_refused
    { status = `Service_unavailable
    ; headers = Server_auth.not_initialized_headers
    ; body =
        Server_refusal.json
          ~code:"server_booting"
          (Precondition.refusal_message Precondition.Server_booting)
    }
;;

let check_v2_guard ~instance_id ~served ~ready ~path (request : Httpun.Request.t) =
  if String.equal path Server_health_paths.health
  then Guard_pass
  else (
    let inst_res =
      parse_single_optional_header
        ~name:expected_instance_header
        (Httpun.Headers.get_multi request.headers expected_instance_header)
    in
    let ws_res =
      parse_single_optional_header
        ~name:expected_workspace_header
        (Httpun.Headers.get_multi request.headers expected_workspace_header)
    in
    match inst_res, ws_res with
    | Error msg, _ | Ok _, Error msg -> invalid_guard_refusal msg
    | Ok None, Ok None -> Guard_pass
    | Ok expected_instance, Ok expected_workspace ->
      let instance_decision =
        match expected_instance with
        | None -> Guard_pass
        | Some expected when String.equal expected instance_id -> Guard_pass
        | Some expected ->
          mismatch_refusal
            ~reason:"instance_mismatch"
            ~expected_instance:expected
            ~observed_instance:instance_id
            "server instance does not match X-Masc-Expected-Instance"
      in
      (match instance_decision with
       | Guard_refused _ as refused -> refused
       | Guard_pass ->
         (match expected_workspace with
          | None -> Guard_pass
          | Some expected ->
            (match served () with
             | None -> booting_guard_refusal ()
             | Some current ->
               if not (workspace_matches ~expected current)
               then
                 mismatch_refusal
                   ~reason:"workspace_mismatch"
                   ~observed_workspace_sha256:(Auth.sha256_hash current.base_path)
                   "served workspace does not match X-Masc-Expected-Workspace"
               else if ready
               then Guard_pass
               else booting_guard_refusal ()))))
;;

let guard ~path request reqd ~admitted =
  match check_current_request ~path request with
  | Precondition.Refused refusal ->
    Http_server_eio.Response.json_value
      ~status:(refusal_status refusal)
      (* Use the same admitted-origin policy as other early refusals. *)
      ~extra_headers:(refusal_headers refusal @ Server_auth.auth_error_cors_headers request)
      (refusal_body refusal)
      reqd
  | Precondition.No_precondition | Precondition.Precondition_met ->
    (match
       check_v2_guard
         ~instance_id:Build_identity.runtime_instance_id
         ~served:served_workspace
         ~ready:(Server_startup_state.snapshot ()).state_ready
         ~path
         request
     with
     | Guard_pass -> admitted ()
     | Guard_refused { status; headers; body } ->
       Http_server_eio.Response.json_value
         ~status
         ~extra_headers:(headers @ Server_auth.auth_error_cors_headers request)
         body
         reqd)
;;
