(* HIGH-RISK-UNREVIEWED: see the interface. *)

module Http = Http_server_eio
module Env = Server_dashboard_http_v2_envelope

let observer_events_path = "/api/v1/auth/events"
let dashboard_access = Server_route.Self_authenticated Route_access.Multi_account_dashboard
let max_dashboard_mutation_bytes = 512 * 1024
let exact_lane_run_page_default = 50
let exact_lane_run_page_max = 200
let exact_lane_run_detail_prefix = "/api/v1/dashboard/exact-lane-runs/"
let wiki_slug_prefix = "/api/v1/wiki/"
let sandbox_keeper_prefix = "/api/v1/infra/sandboxes/"

type access_tier =
  | Workspace_read
  | Admin_only
  | Browser_observer_sse

type authorized =
  { caller : Auth_gate.authenticated
  ; state : Authz_state.t
  }

let refused status text = Login_routes.json status [ "error", `String text ]

let gate_error_answer reason =
  let status =
    if Auth_gate.is_unauthenticated reason
    then Login_routes.Unauthorized_401
    else Login_routes.Forbidden_403
  in
  refused status (Auth_gate.reason_to_string reason)
;;

let route_access_of_tier = function
  | Workspace_read | Browser_observer_sse -> Route_access.Read_auth
  | Admin_only -> Route_access.Permission Masc_domain.CanAdmin
;;

let authorize (trusted : Authz_zone.trusted) ~now_ms tier (request : Auth_gate.request) =
  let state = (trusted :> Authz_zone.snapshot).Authz_zone.state in
  match Auth_gate.decide trusted ~now_ms (route_access_of_tier tier) request with
  | Error reason -> Error (gate_error_answer reason)
  | Ok (Auth_gate.Anonymous | Auth_gate.Judged_by_route) ->
    Error (gate_error_answer Auth_gate.Credential_required)
  | Ok (Auth_gate.Authenticated caller) ->
    (match tier with
     | Workspace_read | Admin_only -> Ok { caller; state }
     | Browser_observer_sse ->
       (match caller.Auth_gate.binding, request.Auth_gate.origin with
        | ( Auth_gate.Session (_ : Authz_types.Session_id.t)
          , (Authz_browser_request.Same_origin | Authz_browser_request.No_origin) ) ->
          Ok { caller; state }
        | Auth_gate.Session (_ : Authz_types.Session_id.t), Authz_browser_request.Other_origin ->
          Error
            (refused
               Login_routes.Forbidden_403
               "cross-origin observer event streams are forbidden")
        | ( (Auth_gate.Pat (_ : Authz_types.Pat_id.t)
            | Auth_gate.Service_credential (_ : Authz_types.Service_credential_id.t))
          , ( Authz_browser_request.Same_origin
            | Authz_browser_request.No_origin
            | Authz_browser_request.Other_origin ) ) ->
          Error
            (refused
               Login_routes.Forbidden_403
               "observer events require a browser session cookie")))
;;

let is_admin (caller : Auth_gate.authenticated) =
  match caller.Auth_gate.role with
  | Masc_domain.Admin -> true
  | Masc_domain.Worker | Masc_domain.Player -> false
;;

let actor_of_principal = function
  | Authz_types.Principal.Human user_id -> Authz_types.User_id.to_string user_id
  | Authz_types.Principal.Service service_id -> Authz_types.Service_id.to_string service_id
;;

let owned_keeper_names ~state (caller : Auth_gate.authenticated) =
  match caller.Auth_gate.principal with
  | Authz_types.Principal.Human user_id ->
    Authz_keeper_state.owned_by state.Authz_state.keepers user_id
    |> List.map (fun (_keeper_id, (keeper : Authz_keeper_state.keeper)) ->
      Authz_types.Engine_name.to_string keeper.engine_name)
  | Authz_types.Principal.Service (_ : Authz_types.Service_id.t) -> []
;;

let board_reader_of ~state (caller : Auth_gate.authenticated) =
  Masc_board_handlers.Board_access.Workspace_member
    { actor_id = actor_of_principal caller.Auth_gate.principal
    ; owned_keeper_ids = owned_keeper_names ~state caller
    }
;;

let can_read_keeper_memory ~state caller ~keeper =
  List.mem keeper (owned_keeper_names ~state caller)
;;

let can_read_keeper_sandbox ~state caller ~keeper =
  is_admin caller || List.mem keeper (owned_keeper_names ~state caller)
;;

let non_empty_string_field name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some (`String value) ->
       let trimmed = String.trim value in
       if String.equal trimmed "" then None else Some trimmed
     | Some _ | None -> None)
  | _ -> None
;;

let event_keeper_name_of payload =
  match non_empty_string_field "name" payload with
  | Some _ as found -> found
  | None ->
    (match non_empty_string_field "keeper" payload with
     | Some _ as found -> found
     | None -> non_empty_string_field "keeper_name" payload)
;;

let lane_addons_visibility_permitted ~state caller payload =
  match payload with
  | `Assoc fields ->
    (match List.assoc_opt "visibility" fields with
     | Some (`Assoc _ as vis) ->
       (match non_empty_string_field "kind" vis with
        | Some "shared" -> true
        | Some "operator" -> is_admin caller
        | Some "keeper" ->
          (match non_empty_string_field "keeper" vis with
           | Some keeper -> is_admin caller || List.mem keeper (owned_keeper_names ~state caller)
           | None -> false)
        | Some _ | None -> false)
     | Some _ | None -> false)
  | _ -> false
;;

let observer_event_visible_to ~state caller payload =
  match non_empty_string_field "type" payload with
  | Some
      ("keeper_chat_operation_event" | "keeper_chat_appended" | "keeper_turn_preview_changed") ->
    (match event_keeper_name_of payload with
     | Some keeper -> List.mem keeper (owned_keeper_names ~state caller)
     | None -> false)
  | Some ("operator_snapshot" | "operator_digest" | "operator_action_required") -> is_admin caller
  | Some "workspace_dataset_changed"
    when Option.equal String.equal (non_empty_string_field "dataset" payload) (Some "lane_addons")
    -> lane_addons_visibility_permitted ~state caller payload
  | Some _ | None -> true
;;

let strip_single_user_auth_headers (request : Httpun.Request.t) =
  let should_strip_header name =
    let lower = String.lowercase_ascii name in
    String.equal lower "authorization"
    || String.equal lower "x-masc-internal-token"
    || String.equal lower "x-masc-agent"
    || String.equal lower "x-masc-agent-name"
    || String.equal lower "x-gate-agent"
    || String.equal lower "cookie"
  in
  let should_strip_query key =
    let lower = String.lowercase_ascii key in
    String.equal lower "agent"
    || String.equal lower "agent_name"
    || String.equal lower "me"
    || String.equal lower "token"
    || String.equal lower "access_token"
  in
  let headers =
    Httpun.Headers.to_list request.Httpun.Request.headers
    |> List.filter (fun (name, (_ : string)) -> not (should_strip_header name))
    |> Httpun.Headers.of_list
  in
  let uri = Uri.of_string request.Httpun.Request.target in
  let query =
    Uri.query uri
    |> List.filter (fun (key, (_ : string list)) -> not (should_strip_query key))
  in
  let target = Uri.to_string (Uri.with_query uri query) in
  Httpun.Request.create
    ~version:request.Httpun.Request.version
    ~headers
    request.Httpun.Request.meth
    target
;;

let request_carries_observer_query_token (request : Httpun.Request.t) =
  let query = Uri.query (Uri.of_string request.Httpun.Request.target) in
  List.exists
    (fun (key, (_ : string list)) ->
      let lower = String.lowercase_ascii key in
      String.equal lower "token" || String.equal lower "access_token")
    query
;;

let with_authorized ?(forbid_query_token = false) ~login ~tier request reqd f =
  Server_login_http.with_authority reqd (fun request_authority ->
    Server_login_http.on_trusted login reqd (fun trusted ->
      let base_gate = Server_login_http.gate_request ~request_authority request in
      let gate_req =
        if forbid_query_token && request_carries_observer_query_token request
        then
          { base_gate with
            Auth_gate.credentials =
              { base_gate.Auth_gate.credentials with
                Authz_credential_presentation.query_credential = true
              }
          }
        else base_gate
      in
      match authorize trusted ~now_ms:(Server_login_http.now_ms login) tier gate_req with
      | Error answer -> Server_login_http.respond reqd answer
      | Ok auth -> f gate_req auth))
;;

let with_engine_after_auth ~engine_state reqd f =
  match engine_state () with
  | None ->
    Server_login_http.respond
      reqd
      (refused Login_routes.Service_unavailable_503 "engine_starting")
  | Some state -> f state
;;

let with_engine ~login ~engine_state ~tier request reqd f =
  with_authorized ~login ~tier request reqd (fun (_ : Auth_gate.request) auth ->
    with_engine_after_auth ~engine_state reqd (fun state -> f state auth))
;;

let respond_json_error ?(status = `Bad_request) ~request reqd message =
  Http.Response.json_value
    ~status
    ~request
    (`Assoc [ "ok", `Bool false; "error", `String message ])
    reqd
;;

let respond_v2_result ~request reqd = function
  | Ok json -> Http.Response.json_value ~compress:true ~request json reqd
  | Error (status, json) -> Http.Response.json_value ~status ~compress:true ~request json reqd
;;

let v2_error_result ~field code message =
  Error (Env.error_status code, Env.error_json ~field ~code message)
;;

let non_empty_trimmed_param req key =
  match Server_utils.query_param req key with
  | None -> None
  | Some raw ->
    let trimmed = String.trim raw in
    if String.equal trimmed "" then None else Some trimmed
;;

let extract_wiki_slug req =
  match Server_utils.extract_path_param ~prefix:wiki_slug_prefix (Http.Request.path req) with
  | None -> None
  | Some raw ->
    let decoded = Uri.pct_decode raw |> String.trim in
    if String.equal decoded "" || String.contains decoded '/' then None else Some decoded
;;

(* ---- Cookie-authenticated Observer SSE (GET /api/v1/auth/events) ---- *)

let resync_gap_frame ~last_event_id ~missed_through =
  Sse.format_event_yojson
    ~event_type:"observer_resync_required"
    (`Assoc
       [ "type", `String "observer_resync_required"
       ; "reason", `String "replay_gap"
       ; "last_event_id", `Int last_event_id
       ; "missed_through", `Int missed_through
       ])
;;

let handle_observer_events ~sw ~clock ~login ~base_path ~engine_state request reqd =
  with_authorized
    ~forbid_query_token:true
    ~login
    ~tier:Browser_observer_sse
    request
    reqd
    (fun gate_req (_ : authorized) ->
       match Server_mcp_transport_http_headers.get_last_event_id request with
       | Error err ->
         Server_login_http.respond
           reqd
           (refused
              Login_routes.Bad_request_400
              (Server_mcp_transport_http_headers.last_event_id_error_to_string err))
       | Ok last_event_id_opt ->
         let runtime_authority = Sse.runtime_authority_exn ~base_path in
         let observer_instance_id =
           Option.map
             (fun state -> Server_observer_scope.instance_id (Mcp_server.workspace_scope state))
             (engine_state ())
         in
         let headers =
           Httpun.Headers.of_list
             [ "content-type", "text/event-stream"
             ; "cache-control", "private, no-store"
             ; "connection", "close"
             ; "x-accel-buffering", "no"
             ; ( Server_mcp_transport_http_headers.observer_idle_timeout_header
               , string_of_int Server_mcp_transport_http_headers.observer_idle_timeout_ms )
             ]
         in
         let response =
           Server_sse_response.respond
             ~clock
             ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s
             ~flush_headers_immediately:true
             reqd
             (Httpun.Response.create ~headers `OK)
         in
         let queue = Server_sse_pump.Queue.create ~max_queued_events:Sse.stream_capacity in
         (* Subscribe BEFORE replay lookup so no event committed between replay
            capture and live pump startup can be lost; overlap is deduplicated
            by [seen_replay_ids]. *)
         let unsubscribe =
           Sse.subscribe_publication_inputs
             ~runtime_authority
             ?observer_instance_id
             (Server_sse_pump.Queue.push queue)
         in
         let replay_opt =
           Option.map
             (fun last_event_id ->
               let replay =
                 Sse.replay_after_for_session
                   ~runtime_authority
                   ?observer_instance_id
                   ~session_id:("ma-observer-" ^ string_of_int (Sse.fresh_client_id ()))
                   ~kind:Sse.Observer
                   last_event_id
               in
               last_event_id, replay)
             last_event_id_opt
         in
         let seen_replay_ids : (int, unit) Hashtbl.t = Hashtbl.create 32 in
         Option.iter
           (fun (_last_id, (replay : Sse.replay)) ->
             List.iter
               (fun (delivery : Sse.delivery) ->
                 Hashtbl.replace seen_replay_ids delivery.Sse.event_id ())
               replay.Sse.deliveries)
           replay_opt;
         let active_auth () =
           match Authz_zone.read login.Login_routes.zone with
           | Error (_ : Authz_zone.uncertain) -> None
           | Ok trusted ->
             (match
                authorize
                  trusted
                  ~now_ms:(Server_login_http.now_ms login)
                  Browser_observer_sse
                  gate_req
              with
              | Ok auth -> Some auth
              | Error (_ : Login_routes.answer) -> None)
         in
         let send_frame frame =
           match Server_sse_response.send response frame with
           | Server_sse_response.Written -> true
           | Server_sse_response.Closed | Server_sse_response.Stalled -> false
         in
         let send_replay () =
           match replay_opt with
           | None -> true
           | Some (last_event_id, { Sse.deliveries; continuity }) ->
             let after_gap_ok =
               match continuity with
               | Sse.Continuous -> true
               | Sse.After_gap { missed_through } ->
                 send_frame (resync_gap_frame ~last_event_id ~missed_through)
             in
             if not after_gap_ok
             then false
             else
               let rec flush = function
                 | [] -> true
                 | (delivery : Sse.delivery) :: rest ->
                   (match active_auth () with
                    | None -> false
                    | Some auth ->
                      if observer_event_visible_to ~state:auth.state auth.caller delivery.Sse.payload
                      then if send_frame delivery.Sse.frame then flush rest else false
                      else flush rest)
               in
               flush deliveries
         in
         Server_sse_response.serve ~sw ~release:unsubscribe response (fun () ->
           if send_frame (Server_mcp_transport_http_headers.sse_prime_event ()) && send_replay ()
           then (
             let (_ : Server_sse_pump.ending) =
               Server_sse_pump.run
                 ~source:(Server_sse_pump.Queue.source queue)
                 ~step:(fun (ev : Sse.external_event) ->
                   if Hashtbl.mem seen_replay_ids ev.Sse.ext_event_id
                   then (
                     Hashtbl.remove seen_replay_ids ev.Sse.ext_event_id;
                     Server_sse_pump.Skip)
                   else (
                     match active_auth () with
                     | None -> Server_sse_pump.Stop
                     | Some auth ->
                       if observer_event_visible_to ~state:auth.state auth.caller ev.Sse.ext_payload
                       then Server_sse_pump.Send ev.Sse.ext_frame
                       else Server_sse_pump.Skip))
                 ~idle:(fun () ->
                   match active_auth () with
                   | Some (_ : authorized) -> Server_sse_pump.Keepalive
                   | None -> Server_sse_pump.Finish)
                 ~clock
                 ~ping_interval_s:Server_mcp_transport_http_headers.sse_ping_interval_s
                 ~closed:(fun () -> Server_sse_response.await_closed response)
                 ~send:(Server_sse_response.send response)
             in
             ())))
;;

(* ---- Workspace Read handlers (Worker + Admin) ---- *)

let handle_shell ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let light = Server_utils.bool_query_param req "light" ~default:false in
    let timing = Server_timing.create () in
    (* Omit [~request] so single-user [Server_auth] projection never runs. *)
    let json =
      Server_dashboard_snapshot_select.select_shell_json
        ?clock:state.Mcp_server.clock
        ~timing
        ~light
        (Mcp_server.workspace_config state)
    in
    Http.Response.json_value
      ~compress:true
      ~request:req
      ~extra_headers:(Server_timing.extra_header timing)
      json
      reqd)
;;

let handle_bootstrap ~sw ~clock ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let clean_req = strip_single_user_auth_headers req in
    let json =
      Server_dashboard_http.dashboard_bootstrap_http_json
        ~include_request_auth:false
        ~state
        ~sw
        ~clock
        clean_req
    in
    Http.Response.json_value_on_cpu ~compress:true ~request:req json reqd)
;;

let handle_execution ~sw ~clock ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let clean_req = strip_single_user_auth_headers req in
    let timing = Server_timing.create () in
    let context, cached =
      Server_timing.measure timing Server_timing.Cache_lookup (fun () ->
        let context = Server_dashboard_http.execution_http_request ~state clean_req in
        context, Server_dashboard_http.dashboard_execution_cached_http_response context)
    in
    let response =
      match cached with
      | Some response -> response
      | None ->
        Server_timing.measure timing Server_timing.Cache_compute (fun () ->
          Server_dashboard_http.dashboard_execution_http_response ~sw ~clock context)
    in
    match response with
    | Server_dashboard_http.Execution_json json ->
      Http.Response.json_value
        ~compress:false
        ~request:req
        ~extra_headers:(Server_timing.extra_header timing)
        json
        reqd
    | Server_dashboard_http.Execution_payload payload ->
      let body, headers =
        Dashboard_cache.select_http_representation
          ~accept_encoding:(Httpun.Headers.get req.Httpun.Request.headers "accept-encoding")
          payload
      in
      Http.Response.json_lazy
        ~compress:false
        ~request:req
        ~etag:payload.Dashboard_cache.etag
        ~extra_headers:(headers @ Server_timing.extra_header timing)
        (fun () -> body)
        reqd)
;;

let handle_execution_publication ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let clean_req = strip_single_user_auth_headers req in
    match
      Server_dashboard_http.execution_publication_of_request
        (Server_dashboard_http.execution_http_request ~state clean_req)
    with
    | Some payload ->
      let body, headers =
        Dashboard_cache.select_http_representation
          ~accept_encoding:(Httpun.Headers.get req.Httpun.Request.headers "accept-encoding")
          payload
      in
      Http.Response.json_lazy
        ~compress:false
        ~request:req
        ~etag:payload.Dashboard_cache.etag
        ~extra_headers:headers
        (fun () -> body)
        reqd
    | None ->
      Http.Response.json_value
        ~status:`Not_found
        ~request:req
        (`Assoc [ "error", `String "no execution projection has been announced yet" ])
        reqd)
;;

let handle_execution_trust ~sw ~clock ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let clean_req = strip_single_user_auth_headers req in
    let json =
      Server_dashboard_http.dashboard_execution_trust_http_json ~state ~sw ~clock clean_req
    in
    Http.Response.json_value ~compress:true ~request:req json reqd)
;;

let handle_board ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state auth ->
    let config = Mcp_server.workspace_config state in
    let reader = board_reader_of ~state:auth.state auth.caller in
    let actor = Some (actor_of_principal auth.caller.Auth_gate.principal) in
    Server_cached_read_http.respond
      ~request:req
      reqd
      (Server_dashboard_http.dashboard_memory_http_payload ~config ~reader ~actor req))
;;

let handle_planning ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    Server_cached_read_http.respond
      ~request:req
      reqd
      (Server_dashboard_http.cached_planning_payload ~config:(Mcp_server.workspace_config state)))
;;

let handle_goals ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    Server_cached_read_http.respond
      ~request:req
      reqd
      (Server_dashboard_http.cached_goals_tree_payload
         ~config:(Mcp_server.workspace_config state)))
;;

let handle_goal_detail ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    match non_empty_trimmed_param req "goal_id" with
    | None -> respond_json_error ~request:req reqd "goal_id query param is required"
    | Some goal_id ->
      let config = Mcp_server.workspace_config state in
      let json =
        Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
          Server_dashboard_http.dashboard_goal_detail_http_json ~config ~goal_id)
      in
      Http.Response.json_value ~compress:true ~request:req json reqd)
;;

let handle_task_history_page ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    Server_routes_http_dashboard_handlers.handle_dashboard_task_history_page state req reqd)
;;

let handle_task_history ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    Server_routes_http_dashboard_handlers.handle_dashboard_task_history state req reqd)
;;

let handle_workspace ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let clean_req = strip_single_user_auth_headers req in
    Server_routes_http_dashboard_handlers.handle_dashboard_workspace state clean_req reqd)
;;

let handle_tools ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let timing = Server_timing.create () in
    let response =
      Server_dashboard_snapshot_select.select_tools_response
        ~timing
        ?keeper:(Server_utils.query_param req "keeper")
        (Mcp_server.workspace_config state)
    in
    let extra_headers = Server_timing.extra_header timing in
    match response with
    | Server_dashboard_snapshot_select.Tools_json json ->
      Http.Response.json_value ~compress:true ~request:req ~extra_headers json reqd
    | Server_dashboard_snapshot_select.Tools_prepared tools ->
      let body, headers =
        Http_response_payload.select_prepared
          ~accept_encoding:(Httpun.Headers.get req.Httpun.Request.headers "accept-encoding")
          tools.Dashboard_snapshot.encoded
      in
      Http.Response.json_lazy
        ~compress:false
        ~request:req
        ~etag:tools.Dashboard_snapshot.etag
        ~extra_headers:(headers @ extra_headers)
        (fun () -> body)
        reqd)
;;

let handle_telemetry ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    Server_routes_http_routes_dashboard_setup.handle_telemetry state req reqd)
;;

let handle_telemetry_summary ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let timing = Server_timing.create () in
    let json =
      Server_dashboard_snapshot_select.select_telemetry_summary_json
        ~timing
        (Mcp_server.workspace_config state)
    in
    Http.Response.json_value
      ~compress:true
      ~request:req
      ~extra_headers:(Server_timing.extra_header timing)
      json
      reqd)
;;

let handle_cache_stats ~login ~engine_state req reqd =
  with_engine
    ~login
    ~engine_state
    ~tier:Workspace_read
    req
    reqd
    (fun (_ : Mcp_server.server_state) (_ : authorized) ->
       Http.Response.json_value ~compress:true ~request:req (Dashboard_cache.stats ()) reqd)
;;

let handle_runtime_defaults ~login ~engine_state req reqd =
  with_engine
    ~login
    ~engine_state
    ~tier:Workspace_read
    req
    reqd
    (fun (_ : Mcp_server.server_state) (_ : authorized) ->
       let json =
         Server_dashboard_runtime_defaults_json.current
           ~generated_at_iso:(Masc_domain.now_iso ())
           ()
       in
       Http.Response.json_value ~compress:true ~request:req json reqd)
;;

let handle_runtime_resolved ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let json =
      Server_dashboard_runtime_resolved_json.build
        ~generated_at_iso:(Masc_domain.now_iso ())
        ~config:(Mcp_server.workspace_config state)
    in
    Http.Response.json_value ~compress:true ~request:req json reqd)
;;

let handle_runtime_observables ~login ~engine_state req reqd =
  with_engine
    ~login
    ~engine_state
    ~tier:Workspace_read
    req
    reqd
    (fun (_ : Mcp_server.server_state) (_ : authorized) ->
       let json = Server_dashboard_http_runtime_observables.runtime_observables_http_json () in
       Http.Response.json_value ~compress:true ~request:req json reqd)
;;

let handle_transport_health ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let json = Server_dashboard_http.dashboard_transport_health_http_json ~state in
    Http.Response.json_value ~compress:true ~request:req json reqd)
;;

let handle_verification_runs ~login ~engine_state req reqd =
  with_engine
    ~login
    ~engine_state
    ~tier:Workspace_read
    req
    reqd
    (fun (_ : Mcp_server.server_state) (_ : authorized) ->
       let runs = Verification_run_registry.list_runs (Verification_run_registry.global ()) in
       let json =
         `Assoc
           [ "generated_at", `String (Masc_domain.now_iso ())
           ; "count", `Int (List.length runs)
           ; "runs", `List (List.map Verification_run_registry.run_to_yojson runs)
           ]
       in
       Http.Response.json_value ~compress:true ~request:req json reqd)
;;

let handle_goal_verification_runs ~login ~engine_state req reqd =
  with_engine
    ~login
    ~engine_state
    ~tier:Workspace_read
    req
    reqd
    (fun (_ : Mcp_server.server_state) (_ : authorized) ->
       let runs =
         Goal_verification_run_registry.list_runs (Goal_verification_run_registry.global ())
       in
       let json =
         `Assoc
           [ "generated_at", `String (Masc_domain.now_iso ())
           ; "count", `Int (List.length runs)
           ; "runs", `List (List.map Goal_verification_run_registry.row_to_yojson runs)
           ]
       in
       Http.Response.json_value ~compress:true ~request:req json reqd)
;;

let handle_scheduled_automation ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let json =
      Server_dashboard_http.dashboard_scheduled_automation_query_http_json
        ~config:(Mcp_server.workspace_config state)
        req
    in
    Http.Response.json_value ~compress:true ~request:req json reqd)
;;

let handle_project_snapshot ~sw ~clock ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let clean_req = strip_single_user_auth_headers req in
    let timing = Server_timing.create () in
    let json =
      Server_dashboard_snapshot_select.select_project_snapshot_json
        ~state
        ~sw
        ~clock
        ~timing
        clean_req
    in
    Http.Response.json_value
      ~compress:true
      ~request:req
      ~extra_headers:(Server_timing.extra_header timing)
      json
      reqd)
;;

let handle_candle_ledger ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let limit = Server_utils.int_query_param req "limit" ~default:100 in
    let keeper = non_empty_trimmed_param req "keeper" in
    let result =
      Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        Server_dashboard_http_candle_config.candle_ledger_json ~limit ?keeper ~base_path ())
    in
    respond_v2_result ~request:req reqd result)
;;

let handle_wiki_list ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let tag = non_empty_trimmed_param req "tag" in
    let source_res =
      match non_empty_trimmed_param req "source" with
      | None -> Ok None
      | Some trimmed ->
        (match Wiki_page.source_of_string_opt trimmed with
         | Some src -> Ok (Some src)
         | None ->
           v2_error_result
             ~field:"source"
             Env.Invalid_param
             (Printf.sprintf
                "unknown wiki source %S; valid: %s"
                trimmed
                (String.concat ", " Wiki_page.valid_source_strings)))
    in
    let sort_res =
      match Server_utils.query_param req "sort" with
      | None -> Ok Server_dashboard_http_wiki.Sort_title
      | Some raw ->
        (match Server_dashboard_http_wiki.sort_order_of_string raw with
         | Some sort -> Ok sort
         | None ->
           v2_error_result
             ~field:"sort"
             Env.Invalid_param
             (Printf.sprintf "unknown sort %S; valid: title, updated, rank" raw))
    in
    let result =
      match source_res, sort_res with
      | Error err, _ | _, Error err -> Error err
      | Ok source, Ok sort ->
        Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
          Server_dashboard_http_wiki.list_json ?tag ?source ~sort ~base_path ())
    in
    respond_v2_result ~request:req reqd result)
;;

let handle_wiki_log ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let limit = Server_utils.int_query_param req "limit" ~default:100 in
    let before_idx_res =
      match Server_utils.query_param req "before_idx" with
      | None -> Ok None
      | Some raw ->
        (match int_of_string_opt (String.trim raw) with
         | Some n when n >= 0 -> Ok (Some n)
         | Some _ | None ->
           v2_error_result
             ~field:"before_idx"
             Env.Invalid_param
             "before_idx must be a non-negative integer")
    in
    let page = non_empty_trimmed_param req "page" in
    let result =
      match before_idx_res with
      | Error err -> Error err
      | Ok before_idx ->
        Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
          Server_dashboard_http_wiki.log_json ~limit ?before_idx ?page ~base_path ())
    in
    respond_v2_result ~request:req reqd result)
;;

let handle_wiki_search ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let query =
      match Server_utils.query_param req "q" with
      | Some q -> q
      | None -> Option.value ~default:"" (Server_utils.query_param req "query")
    in
    let limit = Server_utils.int_query_param req "limit" ~default:30 in
    let result =
      Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        Server_dashboard_http_wiki.search_json ~limit ~base_path ~query ())
    in
    respond_v2_result ~request:req reqd result)
;;

let handle_wiki_lint ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let page = non_empty_trimmed_param req "page" in
    let result =
      Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        Server_dashboard_http_wiki.lint_json ?page ~base_path ())
    in
    respond_v2_result ~request:req reqd result)
;;

let handle_wiki_get_page ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let result =
      match extract_wiki_slug req with
      | None -> v2_error_result ~field:"slug" Env.Invalid_param "wiki slug is required"
      | Some slug ->
        Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
          Server_dashboard_http_wiki.get_page_json ~base_path ~slug ())
    in
    respond_v2_result ~request:req reqd result)
;;

let handle_memory_world ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let config = Mcp_server.workspace_config state in
    let result =
      Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        Server_dashboard_http_memory_v2.world_json ~config ())
    in
    respond_v2_result ~request:req reqd result)
;;

let handle_memory_diff ~login ~engine_state req reqd =
  with_authorized ~login ~tier:Workspace_read req reqd (fun (_ : Auth_gate.request) auth ->
    let parsed =
      Server_dashboard_http_memory_v2.parse_diff_query
        ~scope:(Server_utils.query_param req "scope")
        ~keeper:(Server_utils.query_param req "keeper")
        ~window:(Server_utils.query_param req "window")
        ~from_rev:(Server_utils.query_param req "from_rev")
        ~to_rev:(Server_utils.query_param req "to_rev")
    in
    match parsed with
    | Error (field, msg) ->
      respond_v2_result ~request:req reqd (v2_error_result ~field Env.Invalid_param msg)
    | Ok ((Server_dashboard_http_memory_v2.Scope_keeper keeper as scope), range) ->
      if not (can_read_keeper_memory ~state:auth.state auth.caller ~keeper)
      then
        Server_login_http.respond
          reqd
          (refused Login_routes.Forbidden_403 "caller does not own this Keeper")
      else
        with_engine_after_auth ~engine_state reqd (fun state ->
          let config = Mcp_server.workspace_config state in
          let result =
            Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
              Server_dashboard_http_memory_v2.diff_json ~config ~scope ~range ())
          in
          respond_v2_result ~request:req reqd result)
    | Ok ((Server_dashboard_http_memory_v2.Scope_world as scope), range) ->
      with_engine_after_auth ~engine_state reqd (fun state ->
        let config = Mcp_server.workspace_config state in
        let result =
          Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
            Server_dashboard_http_memory_v2.diff_json ~config ~scope ~range ())
        in
        respond_v2_result ~request:req reqd result))
;;

let handle_sandboxes_fleet ~sw ~clock ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Workspace_read req reqd (fun state (_ : authorized) ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let json = Server_dashboard_http_infra_sandboxes.get_fleet_json ~sw ~clock ~base_path () in
    Http.Response.json_value ~compress:true ~request:req json reqd)
;;

let handle_sandbox_keeper ~sw ~clock ~login ~engine_state req reqd =
  with_authorized ~login ~tier:Workspace_read req reqd (fun (_ : Auth_gate.request) auth ->
    match Server_utils.extract_path_param ~prefix:sandbox_keeper_prefix (Http.Request.path req) with
    | None ->
      respond_v2_result
        ~request:req
        reqd
        (v2_error_result ~field:"keeper" Env.Invalid_param "keeper name is required")
    | Some raw ->
      let keeper = Uri.pct_decode raw |> String.trim in
      if not (can_read_keeper_sandbox ~state:auth.state auth.caller ~keeper)
      then
        Server_login_http.respond
          reqd
          (refused Login_routes.Forbidden_403 "caller does not own this Keeper")
      else
        with_engine_after_auth ~engine_state reqd (fun state ->
          let base_path = (Mcp_server.workspace_config state).base_path in
          respond_v2_result
            ~request:req
            reqd
            (Server_dashboard_http_infra_sandboxes.get_keeper_json ~sw ~clock ~base_path ~keeper ())))
;;

(* ---- Admin-only handlers (CanAdmin + CSRF for mutations) ---- *)

let handle_logs ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Admin_only req reqd (fun state (_ : authorized) ->
    match Server_logs_query.of_request req with
    | Error json -> Http.Response.json_value ~status:`Bad_request ~compress:true ~request:req json reqd
    | Ok query ->
      let entries = Server_logs_query.read query in
      let ring_bounds = Log.Ring.bounds () in
      let json =
        Server_logs_query.to_json
          ~config:(Mcp_server.workspace_config state)
          query
          ~ring_bounds
          entries
      in
      Http.Response.json_value ~compress:true ~request:req json reqd)
;;

let handle_operator_snapshot ~sw ~clock ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Admin_only req reqd (fun state (_ : authorized) ->
    let clean_req = strip_single_user_auth_headers req in
    let json = Server_dashboard_http.operator_snapshot_http_json ~state ~sw ~clock clean_req in
    Http.Response.json_value ~compress:true ~request:req json reqd)
;;

let handle_operator_digest ~sw ~clock ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Admin_only req reqd (fun state (_ : authorized) ->
    let clean_req = strip_single_user_auth_headers req in
    match Server_dashboard_http.operator_digest_http_json ~state ~sw ~clock clean_req with
    | Ok json -> Http.Response.json_value ~compress:true ~request:req json reqd
    | Error message ->
      Http.Response.json_value
        ~status:`Bad_request
        ~request:req
        (Server_dashboard_http.operator_error_json message)
        reqd)
;;

let handle_config_schema ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Admin_only req reqd (fun state (_ : authorized) ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let result =
      match
        Server_dashboard_http_candle_config.parse_target
          ~target:(Server_utils.query_param req "target")
          ~keeper:(Server_utils.query_param req "keeper")
      with
      | Error (field, msg) -> v2_error_result ~field Env.Invalid_param msg
      | Ok target ->
        Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
          Server_dashboard_http_candle_config.config_schema_json ~base_path ~target ())
    in
    respond_v2_result ~request:req reqd result)
;;

let handle_config_patch ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Admin_only req reqd (fun state auth ->
    Server_login_http.with_body ~max_bytes:max_dashboard_mutation_bytes reqd (fun body_str ->
      let config = Mcp_server.workspace_config state in
      let actor = actor_of_principal auth.caller.Auth_gate.principal in
      let result =
        Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
          Server_dashboard_http_candle_config.config_patch_json ~config ~actor ~body_str ())
      in
      respond_v2_result ~request:req reqd result))
;;

let handle_wiki_put_page ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Admin_only req reqd (fun state auth ->
    Server_login_http.with_body ~max_bytes:max_dashboard_mutation_bytes reqd (fun body_str ->
      let config = Mcp_server.workspace_config state in
      let actor = actor_of_principal auth.caller.Auth_gate.principal in
      let result =
        match extract_wiki_slug req with
        | None -> v2_error_result ~field:"slug" Env.Invalid_param "wiki slug is required"
        | Some slug ->
          Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
            Server_dashboard_http_wiki.put_page_json ~config ~actor ~slug ~body_str ())
      in
      respond_v2_result ~request:req reqd result))
;;

let handle_sandboxes_probe ~sw ~clock ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Admin_only req reqd (fun state (_ : authorized) ->
    Server_login_http.with_body reqd (fun (_ : string) ->
      let base_path = (Mcp_server.workspace_config state).base_path in
      let started = Server_dashboard_http_infra_sandboxes.trigger_probe ~sw ~clock ~base_path () in
      Http.Response.json_value
        ~status:`Accepted
        ~request:req
        (Env.ok
           (`Assoc
              [ "accepted", `Bool true
              ; "refresh_started", `Bool started
              ; "scope", `String "all"
              ]))
        reqd))
;;

let handle_standalone_lanes ~login ~engine_state req reqd =
  with_engine
    ~login
    ~engine_state
    ~tier:Admin_only
    req
    reqd
    (fun (_ : Mcp_server.server_state) (_ : authorized) ->
       Http.Response.json_value
         ~compress:true
         ~request:req
         (Server_standalone_lane_projection.snapshot_json ())
         reqd)
;;

let handle_exact_lane_runs ~login ~engine_state req reqd =
  with_engine
    ~login
    ~engine_state
    ~tier:Admin_only
    req
    reqd
    (fun (_ : Mcp_server.server_state) (_ : authorized) ->
       let limit =
         Server_utils.int_query_param req "limit" ~default:exact_lane_run_page_default
         |> Server_utils.clamp ~min_v:1 ~max_v:exact_lane_run_page_max
       in
       let before =
         match
           ( Option.bind (Server_utils.query_param req "before_started_at") float_of_string_opt
           , Server_utils.query_param req "before_run_id" )
         with
         | Some started_at, Some run_id when not (String.equal (String.trim run_id) "") ->
           Ok (Some (started_at, run_id))
         | None, None -> Ok None
         | _ -> Error "before_started_at and before_run_id must be given together"
       in
       let lane = non_empty_trimmed_param req "lane" in
       let run_kind =
         match Server_utils.query_param req "run_kind" with
         | None -> Ok None
         | Some value ->
           Server_standalone_lane_projection.run_kind_of_string value |> Result.map Option.some
       in
       match before, run_kind with
       | Error message, _ | _, Error message -> respond_json_error ~request:req reqd message
       | Ok before, Ok run_kind ->
         (match
            Server_standalone_lane_projection.recent_run_page_json ~limit ~before ~lane ~run_kind
          with
          | Error message -> respond_json_error ~request:req reqd message
          | Ok json -> Http.Response.json_value ~compress:true ~request:req json reqd))
;;

let handle_exact_lane_run_detail ~login ~engine_state req reqd =
  with_engine
    ~login
    ~engine_state
    ~tier:Admin_only
    req
    reqd
    (fun (_ : Mcp_server.server_state) (_ : authorized) ->
       let offset = String.length exact_lane_run_detail_prefix in
       let target = Uri.path (Uri.of_string req.Httpun.Request.target) in
       let raw =
         if String.length target <= offset
         then ""
         else String.sub target offset (String.length target - offset)
       in
       let run_id = Uri.pct_decode raw in
       if String.equal (String.trim run_id) ""
       then respond_json_error ~request:req reqd "run_id is required"
       else (
         match Server_standalone_lane_projection.run_detail_json ~run_id with
         | Server_standalone_lane_projection.Detail_not_found ->
           respond_json_error
             ~status:`Not_found
             ~request:req
             reqd
             ("no retained standalone lane run named " ^ run_id)
         | Server_standalone_lane_projection.Detail_ambiguous ->
           respond_json_error
             ~status:`Internal_server_error
             ~request:req
             reqd
             ("multiple standalone run registries contain " ^ run_id)
         | Server_standalone_lane_projection.Detail_found json ->
           Http.Response.json_value ~compress:true ~request:req json reqd))
;;

let handle_operator_mutation ~run ~sw ~clock ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Admin_only req reqd (fun state auth ->
    Server_login_http.with_body ~max_bytes:max_dashboard_mutation_bytes reqd (fun body_str ->
      let actor = actor_of_principal auth.caller.Auth_gate.principal in
      match Yojson.Safe.from_string body_str with
      | exception Yojson.Json_error msg ->
        Http.Response.json_value
          ~status:`Bad_request
          ~request:req
          (Server_dashboard_http.operator_error_json (Printf.sprintf "invalid json: %s" msg))
          reqd
      | args ->
        (match run ~state ~sw ~clock ~actor ~args with
         | Ok json -> Http.Response.json_value ~request:req json reqd
         | Error message ->
           Http.Response.json_value
             ~status:`Bad_request
             ~request:req
             (Server_dashboard_http.operator_error_json message)
             reqd)))
;;

let handle_schedule_prune ~login ~engine_state req reqd =
  with_engine ~login ~engine_state ~tier:Admin_only req reqd (fun state auth ->
    Server_login_http.with_body reqd (fun (_ : string) ->
      let config = Mcp_server.workspace_config state in
      let operator_name = actor_of_principal auth.caller.Auth_gate.principal in
      match Server_dashboard_http.dashboard_schedule_prune_http_json ~config ~operator_name with
      | Ok json -> Http.Response.json_value ~request:req json reqd
      | Error message ->
        Http.Response.json_value
          ~status:`Bad_request
          ~request:req
          (Server_dashboard_http.operator_error_json message)
          reqd))
;;

let add_routes ~sw ~clock ~login ~base_path ~engine_state router =
  router
  (* Cookie-authenticated Observer SSE *)
  |> Server_route.get
       dashboard_access
       observer_events_path
       (handle_observer_events ~sw ~clock ~login ~base_path ~engine_state)
  (* Workspace Read routes (Admin + Worker; Keeper-scoped routes check ownership) *)
  |> Server_route.get dashboard_access "/api/v1/dashboard/shell" (handle_shell ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/bootstrap"
       (handle_bootstrap ~sw ~clock ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/execution"
       (handle_execution ~sw ~clock ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/execution/publication"
       (handle_execution_publication ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/execution-trust"
       (handle_execution_trust ~sw ~clock ~login ~engine_state)
  |> Server_route.get dashboard_access "/api/v1/dashboard/board" (handle_board ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/planning"
       (handle_planning ~login ~engine_state)
  |> Server_route.get dashboard_access "/api/v1/dashboard/goals" (handle_goals ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/goals/detail"
       (handle_goal_detail ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/tasks/history/page"
       (handle_task_history_page ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/tasks/history"
       (handle_task_history ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/workspace"
       (handle_workspace ~login ~engine_state)
  |> Server_route.get dashboard_access "/api/v1/dashboard/tools" (handle_tools ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/telemetry"
       (handle_telemetry ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/telemetry/summary"
       (handle_telemetry_summary ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/cache-stats"
       (handle_cache_stats ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/runtime-defaults"
       (handle_runtime_defaults ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/runtime/resolved"
       (handle_runtime_resolved ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/runtime-observables"
       (handle_runtime_observables ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/transport-health"
       (handle_transport_health ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/verification-runs"
       (handle_verification_runs ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/goal-verification-runs"
       (handle_goal_verification_runs ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/scheduled-automation"
       (handle_scheduled_automation ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/project-snapshot"
       (handle_project_snapshot ~sw ~clock ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/candle/ledger"
       (handle_candle_ledger ~login ~engine_state)
  |> Server_route.get dashboard_access "/api/v1/wiki" (handle_wiki_list ~login ~engine_state)
  |> Server_route.get dashboard_access "/api/v1/wiki/log" (handle_wiki_log ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/wiki/search"
       (handle_wiki_search ~login ~engine_state)
  |> Server_route.get dashboard_access "/api/v1/wiki/lint" (handle_wiki_lint ~login ~engine_state)
  |> Server_route.prefix_get
       dashboard_access
       wiki_slug_prefix
       (handle_wiki_get_page ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/memory/world"
       (handle_memory_world ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/memory/diff"
       (handle_memory_diff ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/infra/sandboxes"
       (handle_sandboxes_fleet ~sw ~clock ~login ~engine_state)
  |> Server_route.prefix_get
       dashboard_access
       sandbox_keeper_prefix
       (handle_sandbox_keeper ~sw ~clock ~login ~engine_state)
  (* Admin-only routes (Admin session; CSRF enforced on POST/PUT) *)
  |> Server_route.get dashboard_access "/api/v1/dashboard/logs" (handle_logs ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/operator"
       (handle_operator_snapshot ~sw ~clock ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/operator/digest"
       (handle_operator_digest ~sw ~clock ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/config/schema"
       (handle_config_schema ~login ~engine_state)
  |> Server_route.post
       dashboard_access
       "/api/v1/config/patch"
       (handle_config_patch ~login ~engine_state)
  |> Server_route.prefix_put
       dashboard_access
       wiki_slug_prefix
       (handle_wiki_put_page ~login ~engine_state)
  |> Server_route.post
       dashboard_access
       "/api/v1/infra/sandboxes/probe"
       (handle_sandboxes_probe ~sw ~clock ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/standalone-lanes"
       (handle_standalone_lanes ~login ~engine_state)
  |> Server_route.get
       dashboard_access
       "/api/v1/dashboard/exact-lane-runs"
       (handle_exact_lane_runs ~login ~engine_state)
  |> Server_route.prefix_get
       dashboard_access
       exact_lane_run_detail_prefix
       (handle_exact_lane_run_detail ~login ~engine_state)
  |> Server_route.post
       dashboard_access
       "/api/v1/operator/action"
       (handle_operator_mutation
          ~run:Server_dashboard_http.operator_action_for_actor_http_json
          ~sw
          ~clock
          ~login
          ~engine_state)
  |> Server_route.post
       dashboard_access
       "/api/v1/operator/confirm"
       (handle_operator_mutation
          ~run:Server_dashboard_http.operator_confirm_for_actor_http_json
          ~sw
          ~clock
          ~login
          ~engine_state)
  |> Server_route.post
       dashboard_access
       "/api/v1/dashboard/schedule/prune"
       (handle_schedule_prune ~login ~engine_state)
;;
