type account_mode =
  | Single_user
  | Multi_account

type auth_methods = {
  google : bool;
  github : bool;
  dev_token : bool;
}

let default_auth_methods = { google = false; github = false; dev_token = false }

type role =
  | Admin
  | Worker
  | Player

type principal_kind =
  | Human
  | Service

type principal = {
  kind : principal_kind;
  id : string;
}

type binding_kind =
  | Session
  | Pat
  | Service_credential

type credential_binding = {
  kind : binding_kind;
  id : string;
}

type auth_gate_reason =
  | Token_required
  | Token_invalid of string
  | Signed_out of string option
  | Forbidden_credential of string
  | Auth_unavailable of string

type auth_session =
  | Probing_health
  | Probing_single_user of { auth_methods : auth_methods }
  | Probing_multi_account of { auth_methods : auth_methods }
  | Single_user_local of {
      auth_methods : auth_methods;
      auth_enabled : bool;
      require_token : bool;
      token_present : bool;
      token_valid : bool;
      effective_agent : string option;
      role : role;
      effective_admin : bool;
      can_keeper_msg : bool;
      auth_error_code : string option;
      auth_error_detail : string option;
    }
  | Single_user_auth_required of {
      auth_methods : auth_methods;
      reason : auth_gate_reason;
    }
  | Multi_account_signed_out of {
      auth_methods : auth_methods;
      reason : auth_gate_reason;
    }
  | Multi_account_signed_in of {
      principal : principal;
      role : role;
      binding : credential_binding;
      auth_methods : auth_methods;
    }
  | Auth_unavailable of {
      mode : account_mode option;
      reason : string;
    }

type route_access =
  | Always_public
  | Single_user_shell_probe
  | Multi_account_whoami_probe
  | Workspace_read
  | Single_user_read
  | Single_user_token_read
  | Single_user_write
  | Su_read_ma_admin
  | Bridged_token_admin
  | Single_user_token_admin_only
  | Own_provider_manage
  | Own_keeper_sandbox_read
  | Memory_diff_read of { keeper_scoped : bool }
  | Machine_play

type deny_reason =
  | Probing_auth
  | Auth_required of auth_gate_reason
  | Requires_admin
  | Pat_cannot_admin
  | Token_auth_not_enabled
  | Service_cannot_manage_own_provider
  | Requires_worker_or_admin
  | Single_user_only_in_multi_account
  | Multi_account_only_in_single_user

type access_verdict =
  | Allowed
  | Denied of deny_reason

let account_mode_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "single_user" -> Ok Single_user
  | "multi_account" -> Ok Multi_account
  | other ->
      Error
        (Printf.sprintf "unknown account_mode %S (expected single_user or multi_account)"
           other)

let account_mode_to_string = function
  | Single_user -> "single_user"
  | Multi_account -> "multi_account"

let role_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "admin" -> Ok Admin
  | "worker" -> Ok Worker
  | "player" -> Ok Player
  | other ->
      Error
        (Printf.sprintf "unknown role %S (expected admin, worker, or player)"
           other)

let role_to_string = function
  | Admin -> "admin"
  | Worker -> "worker"
  | Player -> "player"

let principal_kind_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "human" -> Ok Human
  | "service" -> Ok Service
  | other ->
      Error
        (Printf.sprintf "unknown principal.kind %S (expected human or service)"
           other)

let principal_kind_to_string = function
  | Human -> "human"
  | Service -> "service"

let binding_kind_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "session" -> Ok Session
  | "pat" -> Ok Pat
  | "service_credential" -> Ok Service_credential
  | other ->
      Error
        (Printf.sprintf
           "unknown binding.kind %S (expected session, pat, or service_credential)"
           other)

let binding_kind_to_string = function
  | Session -> "session"
  | Pat -> "pat"
  | Service_credential -> "service_credential"

let single_user_local_admin =
  Single_user_local
    {
      auth_methods = default_auth_methods;
      auth_enabled = true;
      require_token = true;
      token_present = true;
      token_valid = true;
      effective_agent = Some "admin";
      role = Admin;
      effective_admin = true;
      can_keeper_msg = true;
      auth_error_code = None;
      auth_error_detail = None;
    }

let single_user_local_worker =
  Single_user_local
    {
      auth_methods = default_auth_methods;
      auth_enabled = true;
      require_token = true;
      token_present = true;
      token_valid = true;
      effective_agent = Some "worker";
      role = Worker;
      effective_admin = false;
      can_keeper_msg = true;
      auth_error_code = None;
      auth_error_detail = None;
    }

let single_user_local_player =
  Single_user_local
    {
      auth_methods = default_auth_methods;
      auth_enabled = true;
      require_token = true;
      token_present = true;
      token_valid = true;
      effective_agent = Some "player";
      role = Player;
      effective_admin = false;
      can_keeper_msg = false;
      auth_error_code = None;
      auth_error_detail = None;
    }

let nonblank_opt = function
  | None -> None
  | Some s ->
      let t = String.trim s in
      if String.equal t "" then None else Some t

let session_of_single_user_shell_auth ~auth_methods ~enabled ~require_token
    ~token_present ~token_valid ~effective_agent ~effective_role
    ~effective_admin ~can_keeper_msg ~auth_error_code ~auth_error_detail =
  let detail_msg default_msg =
    match nonblank_opt auth_error_detail with
    | Some d -> d
    | None -> (
        match nonblank_opt auth_error_code with
        | Some c -> c
        | None -> default_msg)
  in
  if enabled && require_token && not token_valid then
    let reason =
      if token_present then Token_invalid (detail_msg "invalid bearer token")
      else Token_required
    in
    Single_user_auth_required { auth_methods; reason }
  else
    match effective_role with
    | None ->
        Single_user_auth_required
          {
            auth_methods;
            reason =
              (if token_present then
                 Token_invalid (detail_msg "caller role could not be resolved")
               else Token_required);
          }
    | Some role ->
        let is_effective_admin =
          match (role, effective_admin) with
          | Admin, Some true -> true
          | Admin, (Some false | None)
          | Worker, (Some true | Some false | None)
          | Player, (Some true | Some false | None) ->
              false
        in
        Single_user_local
          {
            auth_methods;
            auth_enabled = enabled;
            require_token;
            token_present;
            token_valid;
            effective_agent;
            role;
            effective_admin = is_effective_admin;
            can_keeper_msg;
            auth_error_code;
            auth_error_detail;
          }

let account_mode_of_session = function
  | Probing_health -> None
  | Probing_single_user _
  | Single_user_local _
  | Single_user_auth_required _ ->
      Some Single_user
  | Probing_multi_account _
  | Multi_account_signed_out _
  | Multi_account_signed_in _ ->
      Some Multi_account
  | Auth_unavailable { mode; _ } -> mode

let auth_methods_of_session = function
  | Probing_health | Auth_unavailable _ -> default_auth_methods
  | Probing_single_user { auth_methods }
  | Probing_multi_account { auth_methods }
  | Single_user_local { auth_methods; _ }
  | Single_user_auth_required { auth_methods; _ }
  | Multi_account_signed_out { auth_methods; _ }
  | Multi_account_signed_in { auth_methods; _ } ->
      auth_methods

let role_of_session = function
  | Single_user_local { role; _ } | Multi_account_signed_in { role; _ } ->
      Some role
  | Probing_health
  | Probing_single_user _
  | Probing_multi_account _
  | Single_user_auth_required _
  | Multi_account_signed_out _
  | Auth_unavailable _ ->
      None

let is_authenticated = function
  | Single_user_local _ | Multi_account_signed_in _ -> true
  | Probing_health
  | Probing_single_user _
  | Probing_multi_account _
  | Single_user_auth_required _
  | Multi_account_signed_out _
  | Auth_unavailable _ ->
      false

let requires_auth_gate = function
  | Single_user_auth_required _
  | Multi_account_signed_out _
  | Auth_unavailable _ ->
      true
  | Probing_health
  | Probing_single_user _
  | Probing_multi_account _
  | Single_user_local _
  | Multi_account_signed_in _ ->
      false

let is_multi_account = function
  | Probing_multi_account _
  | Multi_account_signed_out _
  | Multi_account_signed_in _ ->
      true
  | Auth_unavailable { mode = Some Multi_account; _ } -> true
  | Probing_health
  | Probing_single_user _
  | Single_user_local _
  | Single_user_auth_required _
  | Auth_unavailable { mode = Some Single_user | None; _ } ->
      false

let is_single_user = function
  | Probing_single_user _
  | Single_user_local _
  | Single_user_auth_required _ ->
      true
  | Auth_unavailable { mode = Some Single_user; _ } -> true
  | Probing_health
  | Probing_multi_account _
  | Multi_account_signed_out _
  | Multi_account_signed_in _
  | Auth_unavailable { mode = Some Multi_account | None; _ } ->
      false

let decide_single_user ~auth_enabled ~require_token ~token_valid ~role
    ~effective_admin (req : route_access) =
  let has_worker_or_admin =
    match role with Admin | Worker -> true | Player -> false
  in
  let has_token_read =
    auth_enabled && require_token && token_valid && has_worker_or_admin
  in
  let has_token_admin =
    auth_enabled && require_token && token_valid && effective_admin
  in
  match req with
  | Always_public | Single_user_shell_probe -> Allowed
  | Multi_account_whoami_probe -> Denied Multi_account_only_in_single_user
  | Workspace_read
  | Single_user_read
  | Single_user_write
  | Su_read_ma_admin
  | Own_keeper_sandbox_read
  | Memory_diff_read _ ->
      if has_worker_or_admin then Allowed else Denied Requires_worker_or_admin
  | Single_user_token_read ->
      if has_token_read then Allowed
      else if (not auth_enabled) || not require_token then
        Denied Token_auth_not_enabled
      else if not has_worker_or_admin then Denied Requires_worker_or_admin
      else Denied (Auth_required Token_required)
  | Machine_play -> Allowed
  | Bridged_token_admin | Single_user_token_admin_only | Own_provider_manage ->
      if has_token_admin then Allowed
      else if (not auth_enabled) || not require_token then
        Denied Token_auth_not_enabled
      else if not token_valid then Denied (Auth_required Token_required)
      else Denied Requires_admin

let decide_multi_account ~(principal : principal) ~role
    ~(binding : credential_binding) (req : route_access) =
  let has_worker_or_admin =
    match role with Admin | Worker -> true | Player -> false
  in
  match req with
  | Always_public | Multi_account_whoami_probe -> Allowed
  | Single_user_shell_probe | Workspace_read | Own_keeper_sandbox_read ->
      if has_worker_or_admin then Allowed else Denied Requires_worker_or_admin
  | Memory_diff_read { keeper_scoped = false } ->
      if has_worker_or_admin then Allowed else Denied Requires_worker_or_admin
  | Memory_diff_read { keeper_scoped = true } -> (
      match (principal.kind, has_worker_or_admin) with
      | Human, true -> Allowed
      | Service, true -> Denied Service_cannot_manage_own_provider
      | (Human | Service), false -> Denied Requires_worker_or_admin)
  | Su_read_ma_admin | Bridged_token_admin -> (
      match (role, binding.kind) with
      | Admin, Session -> Allowed
      | Admin, Pat -> Denied Pat_cannot_admin
      | Admin, Service_credential -> Denied Requires_admin
      | (Worker | Player), (Session | Pat | Service_credential) ->
          Denied Requires_admin)
  | Own_provider_manage -> (
      match (principal.kind, has_worker_or_admin) with
      | Human, true -> Allowed
      | Service, (true | false) -> Denied Service_cannot_manage_own_provider
      | Human, false -> Denied Requires_worker_or_admin)
  | Single_user_read
  | Single_user_token_read
  | Single_user_write
  | Single_user_token_admin_only
  | Machine_play ->
      Denied Single_user_only_in_multi_account

let decide (session : auth_session) (req : route_access) : access_verdict =
  match (session, req) with
  | _, Always_public -> Allowed
  | ( Probing_health
    , ( Single_user_shell_probe
      | Multi_account_whoami_probe
      | Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) ) ->
      Denied Probing_auth
  | Probing_single_user _, Single_user_shell_probe -> Allowed
  | Probing_single_user _, Multi_account_whoami_probe ->
      Denied Multi_account_only_in_single_user
  | ( Probing_single_user _
    , ( Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) ) ->
      Denied Probing_auth
  | Probing_multi_account _, Multi_account_whoami_probe -> Allowed
  | ( Probing_multi_account _
    , ( Single_user_shell_probe
      | Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) ) ->
      Denied Probing_auth
  | Single_user_auth_required { reason; _ }, Single_user_shell_probe ->
      Denied (Auth_required reason)
  | Single_user_auth_required _, Multi_account_whoami_probe ->
      Denied Multi_account_only_in_single_user
  | ( Single_user_auth_required { reason; _ }
    , ( Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) ) ->
      Denied (Auth_required reason)
  | ( Multi_account_signed_out { reason; _ }
    , ( Single_user_shell_probe
      | Multi_account_whoami_probe
      | Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) ) ->
      Denied (Auth_required reason)
  | ( Auth_unavailable { reason; _ }
    , ( Single_user_shell_probe
      | Multi_account_whoami_probe
      | Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) ) ->
      Denied (Auth_required (Auth_unavailable reason))
  | ( Single_user_local
        { auth_enabled; require_token; token_valid; role; effective_admin; _ }
    , ( Single_user_shell_probe
      | Multi_account_whoami_probe
      | Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) ) ->
      decide_single_user ~auth_enabled ~require_token ~token_valid ~role
        ~effective_admin req
  | ( Multi_account_signed_in { principal; role; binding; _ }
    , ( Single_user_shell_probe
      | Multi_account_whoami_probe
      | Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) ) ->
      decide_multi_account ~principal ~role ~binding req

let is_allowed session req =
  match decide session req with Allowed -> true | Denied _ -> false

let can_admin session = is_allowed session Bridged_token_admin

let can_single_user_token_admin session =
  is_allowed session Single_user_token_admin_only

let tracked_capabilities =
  [
    Workspace_read;
    Single_user_read;
    Single_user_token_read;
    Single_user_write;
    Su_read_ma_admin;
    Bridged_token_admin;
    Single_user_token_admin_only;
    Own_provider_manage;
    Own_keeper_sandbox_read;
    Memory_diff_read { keeper_scoped = true };
    Machine_play;
  ]

let is_privilege_demotion ~prev ~next =
  is_authenticated prev
  && ((not (is_authenticated next))
      || List.exists
           (fun cap -> is_allowed prev cap && not (is_allowed next cap))
           tracked_capabilities)

let equal_account_mode a b =
  match (a, b) with
  | Single_user, Single_user | Multi_account, Multi_account -> true
  | Single_user, Multi_account | Multi_account, Single_user -> false

let equal_auth_methods a b =
  Bool.equal a.google b.google
  && Bool.equal a.github b.github
  && Bool.equal a.dev_token b.dev_token

let equal_role a b =
  match (a, b) with
  | Admin, Admin | Worker, Worker | Player, Player -> true
  | Admin, (Worker | Player)
  | Worker, (Admin | Player)
  | Player, (Admin | Worker) ->
      false

let equal_principal_kind a b =
  match (a, b) with
  | Human, Human | Service, Service -> true
  | Human, Service | Service, Human -> false

let equal_principal (a : principal) (b : principal) =
  equal_principal_kind a.kind b.kind && String.equal a.id b.id

let equal_binding_kind a b =
  match (a, b) with
  | Session, Session
  | Pat, Pat
  | Service_credential, Service_credential ->
      true
  | Session, (Pat | Service_credential)
  | Pat, (Session | Service_credential)
  | Service_credential, (Session | Pat) ->
      false

let equal_credential_binding a b =
  equal_binding_kind a.kind b.kind && String.equal a.id b.id

let equal_auth_gate_reason a b =
  match (a, b) with
  | Token_required, Token_required -> true
  | Token_invalid x, Token_invalid y -> String.equal x y
  | Signed_out x, Signed_out y -> Option.equal String.equal x y
  | Forbidden_credential x, Forbidden_credential y -> String.equal x y
  | Auth_unavailable x, Auth_unavailable y -> String.equal x y
  | ( Token_required
    , (Token_invalid _ | Signed_out _ | Forbidden_credential _ | Auth_unavailable _) )
  | ( Token_invalid _
    , (Token_required | Signed_out _ | Forbidden_credential _ | Auth_unavailable _) )
  | ( Signed_out _
    , (Token_required | Token_invalid _ | Forbidden_credential _ | Auth_unavailable _) )
  | ( Forbidden_credential _
    , (Token_required | Token_invalid _ | Signed_out _ | Auth_unavailable _) )
  | ( Auth_unavailable _
    , (Token_required | Token_invalid _ | Signed_out _ | Forbidden_credential _) ) ->
      false

let equal_auth_session a b =
  match (a, b) with
  | Probing_health, Probing_health -> true
  | Probing_single_user x, Probing_single_user y ->
      equal_auth_methods x.auth_methods y.auth_methods
  | Probing_multi_account x, Probing_multi_account y ->
      equal_auth_methods x.auth_methods y.auth_methods
  | Single_user_local x, Single_user_local y ->
      equal_auth_methods x.auth_methods y.auth_methods
      && Bool.equal x.auth_enabled y.auth_enabled
      && Bool.equal x.require_token y.require_token
      && Bool.equal x.token_present y.token_present
      && Bool.equal x.token_valid y.token_valid
      && Option.equal String.equal x.effective_agent y.effective_agent
      && equal_role x.role y.role
      && Bool.equal x.effective_admin y.effective_admin
      && Bool.equal x.can_keeper_msg y.can_keeper_msg
      && Option.equal String.equal x.auth_error_code y.auth_error_code
      && Option.equal String.equal x.auth_error_detail y.auth_error_detail
  | Single_user_auth_required x, Single_user_auth_required y ->
      equal_auth_methods x.auth_methods y.auth_methods
      && equal_auth_gate_reason x.reason y.reason
  | Multi_account_signed_out x, Multi_account_signed_out y ->
      equal_auth_methods x.auth_methods y.auth_methods
      && equal_auth_gate_reason x.reason y.reason
  | Multi_account_signed_in x, Multi_account_signed_in y ->
      equal_principal x.principal y.principal
      && equal_role x.role y.role
      && equal_credential_binding x.binding y.binding
      && equal_auth_methods x.auth_methods y.auth_methods
  | Auth_unavailable x, Auth_unavailable y ->
      Option.equal equal_account_mode x.mode y.mode
      && String.equal x.reason y.reason
  | ( Probing_health
    , ( Probing_single_user _
      | Probing_multi_account _
      | Single_user_local _
      | Single_user_auth_required _
      | Multi_account_signed_out _
      | Multi_account_signed_in _
      | Auth_unavailable _ ) )
  | ( Probing_single_user _
    , ( Probing_health
      | Probing_multi_account _
      | Single_user_local _
      | Single_user_auth_required _
      | Multi_account_signed_out _
      | Multi_account_signed_in _
      | Auth_unavailable _ ) )
  | ( Probing_multi_account _
    , ( Probing_health
      | Probing_single_user _
      | Single_user_local _
      | Single_user_auth_required _
      | Multi_account_signed_out _
      | Multi_account_signed_in _
      | Auth_unavailable _ ) )
  | ( Single_user_local _
    , ( Probing_health
      | Probing_single_user _
      | Probing_multi_account _
      | Single_user_auth_required _
      | Multi_account_signed_out _
      | Multi_account_signed_in _
      | Auth_unavailable _ ) )
  | ( Single_user_auth_required _
    , ( Probing_health
      | Probing_single_user _
      | Probing_multi_account _
      | Single_user_local _
      | Multi_account_signed_out _
      | Multi_account_signed_in _
      | Auth_unavailable _ ) )
  | ( Multi_account_signed_out _
    , ( Probing_health
      | Probing_single_user _
      | Probing_multi_account _
      | Single_user_local _
      | Single_user_auth_required _
      | Multi_account_signed_in _
      | Auth_unavailable _ ) )
  | ( Multi_account_signed_in _
    , ( Probing_health
      | Probing_single_user _
      | Probing_multi_account _
      | Single_user_local _
      | Single_user_auth_required _
      | Multi_account_signed_out _
      | Auth_unavailable _ ) )
  | ( Auth_unavailable _
    , ( Probing_health
      | Probing_single_user _
      | Probing_multi_account _
      | Single_user_local _
      | Single_user_auth_required _
      | Multi_account_signed_out _
      | Multi_account_signed_in _ ) ) ->
      false

let equal_route_access a b =
  match (a, b) with
  | Always_public, Always_public
  | Single_user_shell_probe, Single_user_shell_probe
  | Multi_account_whoami_probe, Multi_account_whoami_probe
  | Workspace_read, Workspace_read
  | Single_user_read, Single_user_read
  | Single_user_token_read, Single_user_token_read
  | Single_user_write, Single_user_write
  | Su_read_ma_admin, Su_read_ma_admin
  | Bridged_token_admin, Bridged_token_admin
  | Single_user_token_admin_only, Single_user_token_admin_only
  | Own_provider_manage, Own_provider_manage
  | Own_keeper_sandbox_read, Own_keeper_sandbox_read
  | Machine_play, Machine_play ->
      true
  | Memory_diff_read x, Memory_diff_read y ->
      Bool.equal x.keeper_scoped y.keeper_scoped
  | ( Always_public
    , ( Single_user_shell_probe
      | Multi_account_whoami_probe
      | Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) )
  | ( Single_user_shell_probe
    , ( Always_public
      | Multi_account_whoami_probe
      | Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) )
  | ( Multi_account_whoami_probe
    , ( Always_public
      | Single_user_shell_probe
      | Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) )
  | ( Workspace_read
    , ( Always_public
      | Single_user_shell_probe
      | Multi_account_whoami_probe
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) )
  | ( Single_user_read
    , ( Always_public
      | Single_user_shell_probe
      | Multi_account_whoami_probe
      | Workspace_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) )
  | ( Single_user_token_read
    , ( Always_public
      | Single_user_shell_probe
      | Multi_account_whoami_probe
      | Workspace_read
      | Single_user_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) )
  | ( Single_user_write
    , ( Always_public
      | Single_user_shell_probe
      | Multi_account_whoami_probe
      | Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) )
  | ( Su_read_ma_admin
    , ( Always_public
      | Single_user_shell_probe
      | Multi_account_whoami_probe
      | Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) )
  | ( Bridged_token_admin
    , ( Always_public
      | Single_user_shell_probe
      | Multi_account_whoami_probe
      | Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) )
  | ( Single_user_token_admin_only
    , ( Always_public
      | Single_user_shell_probe
      | Multi_account_whoami_probe
      | Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) )
  | ( Own_provider_manage
    , ( Always_public
      | Single_user_shell_probe
      | Multi_account_whoami_probe
      | Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_keeper_sandbox_read
      | Memory_diff_read _
      | Machine_play ) )
  | ( Own_keeper_sandbox_read
    , ( Always_public
      | Single_user_shell_probe
      | Multi_account_whoami_probe
      | Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Memory_diff_read _
      | Machine_play ) )
  | ( Memory_diff_read _
    , ( Always_public
      | Single_user_shell_probe
      | Multi_account_whoami_probe
      | Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Machine_play ) )
  | ( Machine_play
    , ( Always_public
      | Single_user_shell_probe
      | Multi_account_whoami_probe
      | Workspace_read
      | Single_user_read
      | Single_user_token_read
      | Single_user_write
      | Su_read_ma_admin
      | Bridged_token_admin
      | Single_user_token_admin_only
      | Own_provider_manage
      | Own_keeper_sandbox_read
      | Memory_diff_read _ ) ) ->
      false

let equal_deny_reason a b =
  match (a, b) with
  | Probing_auth, Probing_auth
  | Requires_admin, Requires_admin
  | Pat_cannot_admin, Pat_cannot_admin
  | Token_auth_not_enabled, Token_auth_not_enabled
  | Service_cannot_manage_own_provider, Service_cannot_manage_own_provider
  | Requires_worker_or_admin, Requires_worker_or_admin
  | Single_user_only_in_multi_account, Single_user_only_in_multi_account
  | Multi_account_only_in_single_user, Multi_account_only_in_single_user ->
      true
  | Auth_required x, Auth_required y -> equal_auth_gate_reason x y
  | ( Probing_auth
    , ( Auth_required _
      | Requires_admin
      | Pat_cannot_admin
      | Token_auth_not_enabled
      | Service_cannot_manage_own_provider
      | Requires_worker_or_admin
      | Single_user_only_in_multi_account
      | Multi_account_only_in_single_user ) )
  | ( Auth_required _
    , ( Probing_auth
      | Requires_admin
      | Pat_cannot_admin
      | Token_auth_not_enabled
      | Service_cannot_manage_own_provider
      | Requires_worker_or_admin
      | Single_user_only_in_multi_account
      | Multi_account_only_in_single_user ) )
  | ( Requires_admin
    , ( Probing_auth
      | Auth_required _
      | Pat_cannot_admin
      | Token_auth_not_enabled
      | Service_cannot_manage_own_provider
      | Requires_worker_or_admin
      | Single_user_only_in_multi_account
      | Multi_account_only_in_single_user ) )
  | ( Pat_cannot_admin
    , ( Probing_auth
      | Auth_required _
      | Requires_admin
      | Token_auth_not_enabled
      | Service_cannot_manage_own_provider
      | Requires_worker_or_admin
      | Single_user_only_in_multi_account
      | Multi_account_only_in_single_user ) )
  | ( Token_auth_not_enabled
    , ( Probing_auth
      | Auth_required _
      | Requires_admin
      | Pat_cannot_admin
      | Service_cannot_manage_own_provider
      | Requires_worker_or_admin
      | Single_user_only_in_multi_account
      | Multi_account_only_in_single_user ) )
  | ( Service_cannot_manage_own_provider
    , ( Probing_auth
      | Auth_required _
      | Requires_admin
      | Pat_cannot_admin
      | Token_auth_not_enabled
      | Requires_worker_or_admin
      | Single_user_only_in_multi_account
      | Multi_account_only_in_single_user ) )
  | ( Requires_worker_or_admin
    , ( Probing_auth
      | Auth_required _
      | Requires_admin
      | Pat_cannot_admin
      | Token_auth_not_enabled
      | Service_cannot_manage_own_provider
      | Single_user_only_in_multi_account
      | Multi_account_only_in_single_user ) )
  | ( Single_user_only_in_multi_account
    , ( Probing_auth
      | Auth_required _
      | Requires_admin
      | Pat_cannot_admin
      | Token_auth_not_enabled
      | Service_cannot_manage_own_provider
      | Requires_worker_or_admin
      | Multi_account_only_in_single_user ) )
  | ( Multi_account_only_in_single_user
    , ( Probing_auth
      | Auth_required _
      | Requires_admin
      | Pat_cannot_admin
      | Token_auth_not_enabled
      | Service_cannot_manage_own_provider
      | Requires_worker_or_admin
      | Single_user_only_in_multi_account ) ) ->
      false

let equal_access_verdict a b =
  match (a, b) with
  | Allowed, Allowed -> true
  | Denied x, Denied y -> equal_deny_reason x y
  | Allowed, Denied _ | Denied _, Allowed -> false

let session_identity_changed ~prev ~next =
  match (prev, next) with
  | Single_user_local a, Single_user_local b ->
      not
        (Option.equal String.equal a.effective_agent b.effective_agent
        && equal_role a.role b.role
        && Bool.equal a.effective_admin b.effective_admin
        && Bool.equal a.auth_enabled b.auth_enabled
        && Bool.equal a.require_token b.require_token
        && Bool.equal a.token_valid b.token_valid)
  | Multi_account_signed_in a, Multi_account_signed_in b ->
      not
        (equal_principal a.principal b.principal
        && equal_role a.role b.role
        && equal_credential_binding a.binding b.binding)
  | Single_user_local _, Multi_account_signed_in _
  | Multi_account_signed_in _, Single_user_local _ ->
      true
  | ( ( Single_user_local _ | Multi_account_signed_in _ )
    , ( Probing_health
      | Probing_single_user _
      | Probing_multi_account _
      | Single_user_auth_required _
      | Multi_account_signed_out _
      | Auth_unavailable _ ) ) ->
      true
  | ( ( Probing_health
      | Probing_single_user _
      | Probing_multi_account _
      | Single_user_auth_required _
      | Multi_account_signed_out _
      | Auth_unavailable _ )
    , ( Probing_health
      | Probing_single_user _
      | Probing_multi_account _
      | Single_user_local _
      | Single_user_auth_required _
      | Multi_account_signed_out _
      | Multi_account_signed_in _
      | Auth_unavailable _ ) ) ->
      false

let role_label_upper = function
  | Admin -> "ADMIN"
  | Worker -> "WORKER"
  | Player -> "PLAYER"

let binding_label_short = function
  | Session -> "SES"
  | Pat -> "PAT"
  | Service_credential -> "SVC"

let session_badge ~compact = function
  | Probing_health | Probing_single_user _ | Probing_multi_account _ ->
      if compact then Say.make ~ko:"인증…" ~en:"AUTH…"
      else Say.make ~ko:"인증 확인 중" ~en:"AUTH PROBING"
  | Single_user_local { role; effective_admin; auth_enabled; require_token; _ }
    ->
      let role_s =
        if role = Admin && not effective_admin then "WORKER"
        else role_label_upper role
      in
      let suffix =
        if (not auth_enabled) || not require_token then
          if compact then "" else " · NO-TOK"
        else ""
      in
      if compact then Say.literal role_s
      else Say.literal (Printf.sprintf "LOCAL %s%s" role_s suffix)
  | Single_user_auth_required _ ->
      if compact then Say.make ~ko:"인증필요" ~en:"AUTH"
      else Say.make ~ko:"인증 필요" ~en:"AUTH REQUIRED"
  | Multi_account_signed_out _ ->
      if compact then Say.make ~ko:"미로그인" ~en:"OUT"
      else Say.make ~ko:"MA 미로그인" ~en:"MA SIGNED OUT"
  | Multi_account_signed_in { role; binding; _ } ->
      let r = role_label_upper role in
      let b = binding_label_short binding.kind in
      if compact then Say.literal (Printf.sprintf "%s·%s" r b)
      else Say.literal (Printf.sprintf "MA %s·%s" r b)
  | Auth_unavailable _ ->
      if compact then Say.make ~ko:"인증오류" ~en:"AUTH ERR"
      else Say.make ~ko:"인증 불가" ~en:"AUTH UNAVAIL"

let deny_reason_say = function
  | Probing_auth ->
      Say.make
        ~ko:"서버 인증 상태를 확인하는 중입니다. 잠시 후 다시 시도하세요."
        ~en:"Checking server authentication state. Try again shortly."
  | Auth_required Token_required ->
      Say.make
        ~ko:"인증 토큰이 필요합니다 (MASC_TOKEN 또는 .masc/auth/admin.token)"
        ~en:"Bearer token required (set MASC_TOKEN or .masc/auth/admin.token)"
  | Auth_required (Token_invalid detail) ->
      Say.make
        ~ko:("인증 토큰이 거부되었습니다: " ^ detail)
        ~en:("Bearer token rejected: " ^ detail)
  | Auth_required (Signed_out (Some detail)) ->
      Say.make
        ~ko:("로그인이 필요합니다: " ^ detail)
        ~en:("Sign-in required: " ^ detail)
  | Auth_required (Signed_out None) ->
      Say.make
        ~ko:"다중 계정 서버에 로그인이 필요합니다 (MASC_TOKEN에 PAT 설정)"
        ~en:"Multi-account sign-in required (set PAT in MASC_TOKEN)"
  | Auth_required (Forbidden_credential detail) ->
      Say.make
        ~ko:("현재 자격 증명으로 접근할 수 없습니다: " ^ detail)
        ~en:("Current credential is forbidden: " ^ detail)
  | Auth_required (Auth_unavailable detail) ->
      Say.make
        ~ko:("서버 인증 상태를 확인할 수 없습니다: " ^ detail)
        ~en:("Server auth status unavailable: " ^ detail)
  | Requires_admin ->
      Say.make
        ~ko:"관리자(Admin) 권한이 필요한 기능입니다"
        ~en:"Admin role is required for this view or action"
  | Pat_cannot_admin ->
      Say.make
        ~ko:"다중 계정 PAT 토큰으로는 관리자 작업을 실행할 수 없습니다 (브라우저 세션 필요)"
        ~en:"Multi-account PAT credentials cannot perform admin actions (browser session required)"
  | Token_auth_not_enabled ->
      Say.make
        ~ko:"워크스페이스 토큰 인증(auth.enabled + require_token)과 유효한 토큰이 필요합니다"
        ~en:"Requires workspace token auth enabled (auth.enabled + require_token) with a valid token"
  | Service_cannot_manage_own_provider ->
      Say.make
        ~ko:"서비스 자격 증명으로는 개인 프로바이더 또는 개인 키퍼를 관리할 수 없습니다"
        ~en:"Service credentials cannot manage personal providers or personal keepers"
  | Requires_worker_or_admin ->
      Say.make
        ~ko:"현재 역할(Player)에서는 워크스페이스 조회/작업이 제한됩니다"
        ~en:"Player role cannot access workspace views or mutations"
  | Single_user_only_in_multi_account ->
      Say.make
        ~ko:"단일 사용자 서버 전용 기능입니다 (다중 계정 서버에서 미지원)"
        ~en:"Available only on single-user servers (not served in multi-account mode)"
  | Multi_account_only_in_single_user ->
      Say.make
        ~ko:"다중 계정 서버 전용 경로입니다"
        ~en:"Available only on multi-account servers"

let auth_gate_title = function
  | Single_user_auth_required _ ->
      Say.make ~ko:"단일 사용자 인증 필요" ~en:"Single-user Authentication Required"
  | Multi_account_signed_out _ ->
      Say.make ~ko:"다중 계정 로그인 필요" ~en:"Multi-account Sign-in Required"
  | Auth_unavailable _ ->
      Say.make ~ko:"인증 상태 확인 실패" ~en:"Authentication Unavailable"
  | Probing_health
  | Probing_single_user _
  | Probing_multi_account _
  | Single_user_local _
  | Multi_account_signed_in _ ->
      Say.make ~ko:"인증 필요" ~en:"Authentication Required"

let auth_gate_detail = function
  | Single_user_auth_required { reason; _ }
  | Multi_account_signed_out { reason; _ } ->
      deny_reason_say (Auth_required reason)
  | Auth_unavailable { reason; _ } ->
      deny_reason_say (Auth_required (Auth_unavailable reason))
  | Probing_health | Probing_single_user _ | Probing_multi_account _ ->
      deny_reason_say Probing_auth
  | Single_user_local _ | Multi_account_signed_in _ ->
      Say.make ~ko:"인증이 완료되었습니다" ~en:"Authenticated"

let auth_gate_remediation = function
  | Single_user_auth_required _ ->
      Say.make
        ~ko:"MASC_TOKEN 환경 변수 또는 <workspace>/.masc/auth/admin.token 파일을 설정한 뒤 [r]을 눌러 다시 확인하세요."
        ~en:"Set MASC_TOKEN or populate <workspace>/.masc/auth/admin.token, then press [r] to retry."
  | Multi_account_signed_out _ ->
      Say.make
        ~ko:"웹 계정 콘솔에서 read_state 범위의 PAT를 발급받아 MASC_TOKEN에 설정한 뒤 TUI를 다시 실행하거나 [r]로 재시도하세요."
        ~en:"Issue a PAT with read_state scope in the account console, export MASC_TOKEN, then restart or press [r] to retry."
  | Auth_unavailable _ ->
      Say.make
        ~ko:"서버 계정 저장소 또는 인증 응답이 복구되면 [r]을 눌러 재시도하세요."
        ~en:"Wait for server account auth to recover, then press [r] to retry."
  | Probing_health
  | Probing_single_user _
  | Probing_multi_account _
  | Single_user_local _
  | Multi_account_signed_in _ ->
      Say.make ~ko:"[r] 재시도 · [Ctrl+Q] 종료" ~en:"[r] Retry · [Ctrl+Q] Quit"
