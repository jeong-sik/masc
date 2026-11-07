(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
module Presentation = Authz_credential_presentation

let ( let* ) = Result.bind

type binding =
  | Session of Session_id.t
  | Pat of Pat_id.t
  | Service_credential of Service_credential_id.t

type authenticated =
  { principal : Principal.t
  ; binding : binding
  ; pat_binding : Pat_binding.t
  ; role : Masc_domain.agent_role
  }

type allowed =
  | Anonymous
  | Authenticated of authenticated
  | Judged_by_route

type reason =
  | Credential_required
  | Several_credentials
  | Query_credential
  | Unreadable of Presentation.unreadable
  | Legacy_credential_forbidden
  | Mcp_oauth_token_not_bound
  | Session_refused of Authz_browser_request.refusal
  | Pat_refused of Authz_pat.refusal
  | Service_credential_refused of Authz_service_credential.refusal
  | Permission_denied of Masc_domain.permission
  | Pat_admin_permission of Masc_domain.permission
  | Pat_scope_lacks of
      { permission : Masc_domain.permission
      ; effect_ : Effect.t
      }
  | Unregistered_tool of string
  | Not_served_in_multi_account of Route_access.self_authenticated_reason

let is_unauthenticated = function
  | Credential_required
  | Several_credentials
  | Query_credential
  | Unreadable _
  | Legacy_credential_forbidden
  | Mcp_oauth_token_not_bound
  | Pat_refused _
  | Service_credential_refused _ -> true
  | Session_refused refusal -> Authz_browser_request.is_unauthenticated refusal
  | Permission_denied _
  | Pat_admin_permission _
  | Pat_scope_lacks _
  | Unregistered_tool _
  | Not_served_in_multi_account _ -> false
;;

let served_reason_label = function
  | Route_access.Oauth_protocol -> "the OAuth routes"
  | Route_access.Loopback_dev_token -> "the loopback dev token"
  | Route_access.Mcp_transport -> "the MCP transport"
  | Route_access.Websocket_upgrade -> "a WebSocket upgrade"
  | Route_access.Browser_session -> "a browser login route"
  | Route_access.Subpath_dispatch -> "a sub-path route"
;;

let reason_to_string = function
  | Credential_required -> "the route needs a credential"
  | Several_credentials -> "the request presents more than one credential"
  | Query_credential -> "multi-account mode reads no credential from a query string"
  | Unreadable unreadable -> Presentation.unreadable_to_string unreadable
  | Legacy_credential_forbidden -> "multi-account mode refuses a legacy bearer"
  | Mcp_oauth_token_not_bound -> "an MCP OAuth token is not bound to a session yet"
  | Session_refused refusal -> Authz_browser_request.refusal_to_string refusal
  | Pat_refused refusal -> Authz_pat.refusal_to_string refusal
  | Service_credential_refused refusal -> Authz_service_credential.refusal_to_string refusal
  | Permission_denied permission ->
    "the principal does not hold " ^ Masc_domain.permission_to_string permission
  | Pat_admin_permission permission ->
    "a PAT does not get " ^ Masc_domain.permission_to_string permission
  | Pat_scope_lacks { permission; effect_ } ->
    Printf.sprintf
      "the scope of the PAT does not allow %s, which %s needs"
      (Effect.to_string effect_)
      (Masc_domain.permission_to_string permission)
  | Unregistered_tool tool_name -> "no tool is registered as " ^ tool_name
  | Not_served_in_multi_account reason ->
    served_reason_label reason ^ " is not served in multi-account mode"
;;

type request =
  { credentials : Presentation.request
  ; method_ : Authz_browser_request.method_
  ; origin : Authz_browser_request.origin
  ; csrf : string option
  }

(* What a kind of route asks of the request. *)
type need =
  | Nothing_needed
  | Holds of Masc_domain.permission
  | Judged_by_its_route
  | Not_served of Route_access.self_authenticated_reason

let tool_need tool_name =
  match Tool_catalog.registered_metadata tool_name with
  | Some { Tool_catalog.required_permission; _ } -> Ok (Holds required_permission)
  | None -> Error (Unregistered_tool tool_name)
;;

(* A read is [CanReadState]: every role that may read holds it. *)
let need_of : Route_access.t -> (need, reason) result = function
  | Route_access.Always_public | Route_access.Public_read Route_access.Open_when_strict ->
    Ok Nothing_needed
  | Route_access.Public_read Route_access.Credential_when_strict | Route_access.Read_auth ->
    Ok (Holds Masc_domain.CanReadState)
  | Route_access.Permission permission
  | Route_access.Token_permission permission
  | Route_access.Private_token_permission permission -> Ok (Holds permission)
  | Route_access.Tool { tool_name }
  | Route_access.Tool_observation { tool_name }
  | Route_access.Tool_actor { tool_name } -> tool_need tool_name
  | Route_access.Self_authenticated Route_access.Browser_session -> Ok Judged_by_its_route
  | Route_access.Self_authenticated
      ((Route_access.Oauth_protocol | Route_access.Loopback_dev_token) as reason) ->
    Ok (Not_served reason)
  | Route_access.Self_authenticated
      (Route_access.Mcp_transport | Route_access.Websocket_upgrade | Route_access.Subpath_dispatch)
    -> Ok (Holds Masc_domain.CanReadState)
;;

let role_of state = function
  | Principal.Human user_id ->
    if Authz_principal_state.is_admin state.Authz_state.principals user_id
    then Masc_domain.Admin
    else Masc_domain.Worker
  | Principal.Service _ -> Masc_domain.Worker
;;

let authenticated state principal binding pat_binding =
  { principal; binding; pat_binding; role = role_of state principal }
;;

let session state ~now_ms request cookie =
  let browser =
    { Authz_browser_request.method_ = request.method_
    ; session_cookie = Some (Authz_browser_session.Cookie.to_value cookie)
    ; bearer = false
    ; query_credential = false
    ; origin = request.origin
    ; csrf = request.csrf
    }
  in
  match Authz_browser_request.check state ~now_ms browser with
  | Error refusal -> Error (Session_refused refusal)
  | Ok (Authz_browser_request.Session { cookie = _; signed_in }) ->
    Ok
      (authenticated
         state
         (Principal.Human signed_in.Authz_browser_session.user_id)
         (Session signed_in.Authz_browser_session.session_id)
         Pat_binding.Not_pat)
  | Ok Authz_browser_request.No_session ->
    (* [browser] carries the cookie, so [check] reads it; this answer would
       mean it did not, and nothing then authenticates the request. *)
    Error Credential_required
;;

(* Who the presented credential is, or [None] when there is none. *)
let authenticate state ~now_ms request : (authenticated option, reason) result =
  match Presentation.read request.credentials with
  | Presentation.No_credential -> Ok None
  | Presentation.Session cookie -> Result.map Option.some (session state ~now_ms request cookie)
  | Presentation.Pat token ->
    (match Authz_pat.authenticate state ~now_ms token with
     | Error refusal -> Error (Pat_refused refusal)
     | Ok { Authz_pat.user_id; pat_id; pat_scope } ->
       Ok
         (Some
            (authenticated state (Principal.Human user_id) (Pat pat_id) (Pat_binding.Pat pat_scope))))
  | Presentation.Service_credential token ->
    (match Authz_service_credential.authenticate state token with
     | Error refusal -> Error (Service_credential_refused refusal)
     | Ok { Authz_service_credential.service_id; credential_id } ->
       Ok
         (Some
            (authenticated
               state
               (Principal.Service service_id)
               (Service_credential credential_id)
               Pat_binding.Not_pat)))
  | Presentation.Mcp_oauth_token -> Error Mcp_oauth_token_not_bound
  | Presentation.Legacy_bearer -> Error Legacy_credential_forbidden
  | Presentation.Query_credential -> Error Query_credential
  | Presentation.Several -> Error Several_credentials
  | Presentation.Unreadable unreadable -> Error (Unreadable unreadable)
;;

(* The effect a permission needs in the scope of a PAT, or [None] for the
   permissions a PAT never gets (design 4.4, user decision 2026-11-08). *)
let pat_effect : Masc_domain.permission -> Effect.t option = function
  | Masc_domain.CanReadState -> Some Effect.Read_state
  | Masc_domain.CanAddTask
  | Masc_domain.CanClaimTask
  | Masc_domain.CanCompleteTask
  | Masc_domain.CanBroadcast
  | Masc_domain.CanVote
  | Masc_domain.CanPlayMachine -> Some Effect.Use_tool
  | Masc_domain.CanInit | Masc_domain.CanReset | Masc_domain.CanAdmin -> None
;;

let holds (who : authenticated) permission =
  if not (Masc_domain.has_permission who.role permission)
  then Error (Permission_denied permission)
  else (
    match who.pat_binding with
    | Pat_binding.Not_pat -> Ok (Authenticated who)
    | Pat_binding.Pat { Pat_scope.scope; expires_at = _ } ->
      (match pat_effect permission with
       | None -> Error (Pat_admin_permission permission)
       | Some effect_ ->
         if Effect_scope.mem effect_ scope.Authorization_scope.allowed_effects
         then Ok (Authenticated who)
         else Error (Pat_scope_lacks { permission; effect_ })))
;;

let decide state ~now_ms access request =
  let* need = need_of access in
  match need with
  | Judged_by_its_route -> Ok Judged_by_route
  | Not_served reason -> Error (Not_served_in_multi_account reason)
  | Nothing_needed ->
    let* who = authenticate state ~now_ms request in
    (match who with
     | None -> Ok Anonymous
     | Some who -> Ok (Authenticated who))
  | Holds permission ->
    let* who = authenticate state ~now_ms request in
    (match who with
     | None -> Error Credential_required
     | Some who -> holds who permission)
;;
