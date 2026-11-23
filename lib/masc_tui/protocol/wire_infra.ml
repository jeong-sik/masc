open Masc_tui_core
open Json_decode_fields
open Wire_common

let ( let* ) = Result.bind

let infra_sandboxes_path = "/api/v1/infra/sandboxes"

let infra_sandbox_keeper_path ~keeper =
  "/api/v1/infra/sandboxes/" ^ percent_encode keeper

let infra_sandboxes_probe_path = "/api/v1/infra/sandboxes/probe"
let repositories_path = "/api/v1/repositories"

let keeper_file_changes_path ~keeper ?(window_hours = 24.0) () =
  Printf.sprintf "/api/v1/keepers/%s/file-changes?window_hours=%g"
    (percent_encode keeper) window_hours

let system_logs_path ?(limit = 200) ?level () =
  let params =
    [ Printf.sprintf "limit=%d" (max 1 limit) ]
    @ match level with None -> [] | Some l -> [ "level=" ^ percent_encode l ]
  in
  "/api/v1/dashboard/logs?" ^ String.concat "&" params

let system_logs_stream_path ?since_seq () =
  match since_seq with
  | None -> "/api/v1/dashboard/logs/stream"
  | Some s -> Printf.sprintf "/api/v1/dashboard/logs/stream?since_seq=%d" s

type probe_freshness =
  | Probe_fresh of float
  | Probe_warming of float
  | Probe_stale of float
  | Probe_error of { measured_at_unix : float; detail : string }

type socket_status =
  | Socket_present of { path_basename : string option }
  | Socket_absent of { path_basename : string option }
  | Socket_non_socket of { file_kind : string option }
  | Socket_unreadable of { detail : string option }

type shim_parity =
  | Shim_matched of string
  | Shim_mismatch of { shim_identity : string; server_identity : string option }
  | Shim_undeclared
  | Shim_unavailable of string

type volume_status =
  | Volume_declared of string
  | Volume_invalid of string

type sandbox_network_mode =
  | Net_inherit
  | Net_none
  | Net_policy

type tool_failure_breakdown = {
  dependency_unavailable : int;
  runtime_failure : int;
  policy_rejection : int;
  workflow_rejection : int;
  operator_cancelled : int;
}

type tool_metrics_24h = {
  calls : int;
  failures : int;
  failure_unclassified : int;
  p50_ms : float Observed.t;
  p95_ms : float Observed.t;
  max_ms : float Observed.t;
  failure_classes : tool_failure_breakdown;
}

type microvm_guest = {
  keeper : string;
  backend : string;
  guest_name : string;
  presence : string;
  agent_socket : socket_status;
  shim_parity : shim_parity;
  network_mode : sandbox_network_mode;
  cpus : int Observed.t;
  memory_mib : int Observed.t;
  volume : volume_status;
  metrics_24h : tool_metrics_24h;
}

type ssh_reachability =
  | Ssh_probe_pending
  | Ssh_reachable of { rtt_ms : float; measured_at_unix : float }
  | Ssh_unreachable of { detail : string; measured_at_unix : float }

type ssh_account_usage = {
  unix_user : string;
  active_sessions : int Observed.t;
  max_sessions : int;
  keepers : string list;
}

type ssh_keeper_session = {
  keeper : string;
  last_dispatch : Yojson.Safe.t;
  metrics_24h : tool_metrics_24h;
}

type ssh_pool = {
  pool_name : string;
  host : string;
  port : int;
  unix_user : string;
  remote_root : string;
  private_home : bool;
  max_sessions : int;
  active_sessions : int Observed.t;
  reachability : ssh_reachability;
  accounts : ssh_account_usage list;
  keeper_sessions : ssh_keeper_session list;
  metrics_24h : tool_metrics_24h;
}

type ssh_unbound_keeper = {
  keeper : string;
  backend : string;
  binding_state : string;
  remote_endpoint : string option;
  metrics_24h : tool_metrics_24h;
}

type docker_keeper = {
  keeper : string;
  backend : string;
  network_mode : sandbox_network_mode;
  metrics_24h : tool_metrics_24h;
}

type unobserved_reason = {
  scope : string;
  reason : string;
}

type sandboxes_snapshot = {
  probe_state : probe_freshness;
  microvm_declared : int;
  microvm_running : int;
  microvm_sockets_present : int;
  microvm_shim_mismatch : int;
  ssh_pools_count : int;
  ssh_keepers_count : int;
  ssh_unbound_keepers_count : int;
  ssh_active_sessions : int Observed.t;
  ssh_max_sessions : int;
  docker_keepers_count : int;
  microvm_guests : microvm_guest list;
  ssh_pools : ssh_pool list;
  ssh_unbound_keepers : ssh_unbound_keeper list;
  docker_keepers : docker_keeper list;
  fleet_metrics_24h : tool_metrics_24h;
  volume_gc_report : Yojson.Safe.t option;
  host_storage : Yojson.Safe.t option;
  unobserved_reasons : unobserved_reason list;
}

type keeper_sandbox_detail =
  | Sandbox_microvm of microvm_guest
  | Sandbox_ssh_keeper of {
      session : ssh_keeper_session;
      pool : ssh_pool option;
    }
  | Sandbox_ssh_unbound of ssh_unbound_keeper
  | Sandbox_docker of docker_keeper

type keeper_sandbox_response = {
  keeper : string;
  probe_state : probe_freshness option;
  sandbox : keeper_sandbox_detail;
}

let decode_probe_freshness json =
  let* kind = required_nonblank_string json "kind" in
  let* ts = required_finite_float json "measured_at_unix" in
  match kind with
  | "fresh" -> Ok (Probe_fresh ts)
  | "warming" -> Ok (Probe_warming ts)
  | "stale" -> Ok (Probe_stale ts)
  | "error" ->
      let* detail =
        match optional_nonblank_string json "error" with
        | Ok (Some d) -> Ok d
        | Ok None -> Ok "sandbox probe error"
        | Error _ as err -> err
      in
      Ok (Probe_error { measured_at_unix = ts; detail })
  | other -> Error (Printf.sprintf "unknown sandbox probe_state kind %S" other)

let decode_socket_status json =
  let* status = required_nonblank_string json "status" in
  match status with
  | "socket_present" ->
      let* path_basename = optional_nonblank_string json "path_basename" in
      Ok (Socket_present { path_basename })
  | "socket_absent" ->
      let* path_basename = optional_nonblank_string json "path_basename" in
      Ok (Socket_absent { path_basename })
  | "non_socket" ->
      let* file_kind = optional_nonblank_string json "file_kind" in
      Ok (Socket_non_socket { file_kind })
  | "unreadable" ->
      let* detail = optional_nonblank_string json "detail" in
      Ok (Socket_unreadable { detail })
  | other -> Error (Printf.sprintf "unknown agent_socket status %S" other)

let decode_shim_parity json =
  let* status = required_nonblank_string json "status" in
  match status with
  | "matched" ->
      let* build_identity = required_nonblank_string json "build_identity" in
      Ok (Shim_matched build_identity)
  | "mismatch" ->
      let* shim_identity = required_nonblank_string json "shim_identity" in
      let* server_identity = optional_nonblank_string json "server_identity" in
      Ok (Shim_mismatch { shim_identity; server_identity })
  | "undeclared" -> Ok Shim_undeclared
  | "unavailable" ->
      let* detail =
        match optional_nonblank_string json "detail" with
        | Ok (Some d) -> Ok d
        | Ok None -> Ok "unavailable"
        | Error _ as err -> err
      in
      Ok (Shim_unavailable detail)
  | other -> Error (Printf.sprintf "unknown shim_parity status %S" other)

let decode_volume_status json =
  let* status = required_nonblank_string json "status" in
  match status with
  | "declared" ->
      let* name = required_nonblank_string json "name" in
      Ok (Volume_declared name)
  | "invalid" ->
      let* detail =
        match optional_nonblank_string json "detail" with
        | Ok (Some d) -> Ok d
        | Ok None -> Ok "invalid volume"
        | Error _ as err -> err
      in
      Ok (Volume_invalid detail)
  | other -> Error (Printf.sprintf "unknown volume status %S" other)

let network_mode_of_string = function
  | "inherit" -> Some Net_inherit
  | "none" -> Some Net_none
  | "policy" -> Some Net_policy
  | _ -> None

let decode_failure_classes json =
  let* dependency_unavailable =
    required_nonnegative_int_field json "dependency_unavailable"
  in
  let* runtime_failure =
    required_nonnegative_int_field json "runtime_failure"
  in
  let* policy_rejection =
    required_nonnegative_int_field json "policy_rejection"
  in
  let* workflow_rejection =
    required_nonnegative_int_field json "workflow_rejection"
  in
  let* operator_cancelled =
    required_nonnegative_int_field json "operator_cancelled"
  in
  Ok
    {
      dependency_unavailable;
      runtime_failure;
      policy_rejection;
      workflow_rejection;
      operator_cancelled;
    }

let empty_metrics_24h =
  {
    calls = 0;
    failures = 0;
    failure_unclassified = 0;
    p50_ms = Observed.unreported;
    p95_ms = Observed.unreported;
    max_ms = Observed.unreported;
    failure_classes =
      {
        dependency_unavailable = 0;
        runtime_failure = 0;
        policy_rejection = 0;
        workflow_rejection = 0;
        operator_cancelled = 0;
      };
  }

let decode_tool_metrics_obj ~observed_at tm =
  let* calls = required_nonnegative_int_field tm "calls" in
  let* failures = required_nonnegative_int_field tm "failures" in
  let* failure_unclassified =
    required_nonnegative_int_field tm "failure_unclassified"
  in
  let* p50_ms = observed_float ~observed_at tm "p50_ms" in
  let* p95_ms = observed_float ~observed_at tm "p95_ms" in
  let* max_ms = observed_float ~observed_at tm "max_ms" in
  let* fc_obj = required_object_field tm "failure_classes" in
  let* failure_classes = decode_failure_classes fc_obj in
  Ok
    {
      calls;
      failures;
      failure_unclassified;
      p50_ms;
      p95_ms;
      max_ms;
      failure_classes;
    }

let decode_tool_metrics_24h ~observed_at json =
  match optional_object_field json "tool_metrics_24h" with
  | Error _ as err -> err
  | Ok None -> Ok empty_metrics_24h
  | Ok (Some tm) -> decode_tool_metrics_obj ~observed_at tm

let decode_microvm_guest ~observed_at json =
  let* keeper = required_nonblank_string json "keeper" in
  let* backend = required_nonblank_string json "backend" in
  let* guest_name = required_nonblank_string json "guest_name" in
  let* presence = required_nonblank_string json "presence" in
  let* sock_obj = required_object_field json "agent_socket" in
  let* agent_socket = decode_socket_status sock_obj in
  let* shim_obj = required_object_field json "shim_parity" in
  let* shim_parity = decode_shim_parity shim_obj in
  let* network_mode =
    decode_enum ~field:"network_mode" network_mode_of_string json
  in
  let* size_obj = required_object_field json "guest_size" in
  let* cpus = observed_int ~observed_at size_obj "cpus" in
  let* memory_mib = observed_int ~observed_at size_obj "memory_mib" in
  let* vol_obj = required_object_field json "volume" in
  let* volume = decode_volume_status vol_obj in
  let* metrics_24h = decode_tool_metrics_24h ~observed_at json in
  Ok
    {
      keeper;
      backend;
      guest_name;
      presence;
      agent_socket;
      shim_parity;
      network_mode;
      cpus;
      memory_mib;
      volume;
      metrics_24h;
    }

let decode_ssh_reachability json =
  let* status = required_nonblank_string json "status" in
  match status with
  | "probe_pending" -> Ok Ssh_probe_pending
  | "reachable" ->
      let* rtt_ms = required_nonnegative_float json "rtt_ms" in
      let* measured_at_unix = required_finite_float json "measured_at_unix" in
      Ok (Ssh_reachable { rtt_ms; measured_at_unix })
  | "unreachable" ->
      let* detail = required_string_field json "detail" in
      let* measured_at_unix = required_finite_float json "measured_at_unix" in
      Ok (Ssh_unreachable { detail; measured_at_unix })
  | other -> Error (Printf.sprintf "unknown ssh reachability status %S" other)

(* The server writes every live SSH session count as [null] because nothing
   counts them yet, and lists [ssh_active_sessions_unreported] under
   [unobserved_reasons]. A [null] here is a count nobody took, not an empty
   pool, so it reads as Unreported rather than Absent. *)
let unobserved_session_count ~observed_at json key =
  let* count = observed_int ~observed_at json key in
  match count with
  | Observed.Absent -> Ok Observed.unreported
  | ( Observed.Loading _ | Observed.Value _ | Observed.Unreported
    | Observed.Failed _ ) as reported ->
      Ok reported

let decode_ssh_account ~observed_at json =
  let* unix_user = required_nonblank_string json "unix_user" in
  let* active_sessions =
    unobserved_session_count ~observed_at json "active_sessions"
  in
  let* max_sessions = required_nonnegative_int_field json "max_sessions" in
  let* keepers = required_string_list json "keepers" in
  Ok { unix_user; active_sessions; max_sessions; keepers }

let decode_ssh_keeper_session ~observed_at json =
  let* keeper = required_nonblank_string json "keeper" in
  let last_dispatch = member "last_dispatch" json in
  let* metrics_24h = decode_tool_metrics_24h ~observed_at json in
  Ok { keeper; last_dispatch; metrics_24h }

let decode_ssh_pool ~observed_at json =
  let* pool_name = required_nonblank_string json "pool_name" in
  let* host = required_nonblank_string json "host" in
  let* port = required_int_field json "port" in
  let* () =
    if port < 1 || port > 65535 then
      Error (Printf.sprintf "invalid ssh pool port %d" port)
    else Ok ()
  in
  let* unix_user = required_nonblank_string json "unix_user" in
  let* remote_root = required_string_field json "remote_root" in
  let* private_home = required_bool_field json "private_home" in
  let* max_sessions = required_nonnegative_int_field json "max_sessions" in
  let* active_sessions =
    unobserved_session_count ~observed_at json "active_sessions"
  in
  let* reach_obj = required_object_field json "reachability" in
  let* reachability = decode_ssh_reachability reach_obj in
  let* acct_items = required_list_field json "accounts" in
  let* accounts =
    decode_list "accounts" (decode_ssh_account ~observed_at) acct_items
  in
  let* ks_items = optional_list_field json "keeper_sessions" in
  let* keeper_sessions =
    decode_list "keeper_sessions"
      (decode_ssh_keeper_session ~observed_at)
      ks_items
  in
  let* metrics_24h = decode_tool_metrics_24h ~observed_at json in
  Ok
    {
      pool_name;
      host;
      port;
      unix_user;
      remote_root;
      private_home;
      max_sessions;
      active_sessions;
      reachability;
      accounts;
      keeper_sessions;
      metrics_24h;
    }

let decode_ssh_unbound_keeper ~observed_at json =
  let* keeper = required_nonblank_string json "keeper" in
  let* backend = required_nonblank_string json "backend" in
  let* binding_state = required_nonblank_string json "binding_state" in
  let* remote_endpoint = optional_nonblank_string json "remote_endpoint" in
  let* metrics_24h = decode_tool_metrics_24h ~observed_at json in
  Ok { keeper; backend; binding_state; remote_endpoint; metrics_24h }

let decode_docker_keeper ~observed_at json =
  let* keeper = required_nonblank_string json "keeper" in
  let* backend = required_nonblank_string json "backend" in
  let* network_mode =
    decode_enum ~field:"network_mode" network_mode_of_string json
  in
  let* metrics_24h = decode_tool_metrics_24h ~observed_at json in
  Ok { keeper; backend; network_mode; metrics_24h }

let decode_unobserved_reason json =
  let* scope = required_nonblank_string json "scope" in
  let* reason = required_nonblank_string json "reason" in
  Ok { scope; reason }

let decode_sandboxes_snapshot ~observed_at json =
  let* _, body = unwrap_v2_or_raw json in
  let* probe_obj = required_object_field body "probe_state" in
  let* probe_state = decode_probe_freshness probe_obj in
  let* summary = required_object_field body "summary" in
  let* microvm_declared =
    required_nonnegative_int_field summary "microvm_declared"
  in
  let* microvm_running =
    required_nonnegative_int_field summary "microvm_running"
  in
  let* microvm_sockets_present =
    required_nonnegative_int_field summary "microvm_sockets_present"
  in
  let* microvm_shim_mismatch =
    required_nonnegative_int_field summary "microvm_shim_mismatch"
  in
  let* ssh_pools_count = required_nonnegative_int_field summary "ssh_pools" in
  let* ssh_keepers_count =
    required_nonnegative_int_field summary "ssh_keepers"
  in
  let* ssh_unbound_keepers_count =
    required_nonnegative_int_field summary "ssh_unbound_keepers"
  in
  let* ssh_active_sessions =
    unobserved_session_count ~observed_at summary "ssh_active_sessions"
  in
  let* ssh_max_sessions =
    required_nonnegative_int_field summary "ssh_max_sessions"
  in
  let* docker_keepers_count =
    required_nonnegative_int_field summary "docker_keepers"
  in
  let* guest_items = required_list_field body "microvm_guests" in
  let* microvm_guests =
    decode_list "microvm_guests" (decode_microvm_guest ~observed_at) guest_items
  in
  let* pool_items = required_list_field body "ssh_pools" in
  let* ssh_pools =
    decode_list "ssh_pools" (decode_ssh_pool ~observed_at) pool_items
  in
  let* unbound_items = optional_list_field body "ssh_unbound_keepers" in
  let* ssh_unbound_keepers =
    decode_list "ssh_unbound_keepers"
      (decode_ssh_unbound_keeper ~observed_at)
      unbound_items
  in
  let* docker_items = optional_list_field body "docker_keepers" in
  let* docker_keepers =
    decode_list "docker_keepers"
      (decode_docker_keeper ~observed_at)
      docker_items
  in
  let* fleet_metrics_24h = decode_tool_metrics_24h ~observed_at body in
  let volume_gc_report =
    match member "volume_gc_report" body with `Null -> None | v -> Some v
  in
  let host_storage =
    match member "host_storage" body with `Null -> None | v -> Some v
  in
  let* reason_items = optional_list_field body "unobserved_reasons" in
  let* unobserved_reasons =
    decode_list "unobserved_reasons" decode_unobserved_reason reason_items
  in
  Ok
    {
      probe_state;
      microvm_declared;
      microvm_running;
      microvm_sockets_present;
      microvm_shim_mismatch;
      ssh_pools_count;
      ssh_keepers_count;
      ssh_unbound_keepers_count;
      ssh_active_sessions;
      ssh_max_sessions;
      docker_keepers_count;
      microvm_guests;
      ssh_pools;
      ssh_unbound_keepers;
      docker_keepers;
      fleet_metrics_24h;
      volume_gc_report;
      host_storage;
      unobserved_reasons;
    }

let decode_keeper_sandbox ~observed_at json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let* probe_state =
    match optional_object_field body "probe_state" with
    | Ok None -> Ok None
    | Ok (Some ps) ->
        let* decoded = decode_probe_freshness ps in
        Ok (Some decoded)
    | Error _ as err -> err
  in
  let* sandbox_obj = required_object_field body "sandbox" in
  let* sandbox =
    if has_field sandbox_obj "guest_name" then
      let* g = decode_microvm_guest ~observed_at sandbox_obj in
      Ok (Sandbox_microvm g)
    else if has_field sandbox_obj "binding_state" then
      let* u = decode_ssh_unbound_keeper ~observed_at sandbox_obj in
      Ok (Sandbox_ssh_unbound u)
    else if has_field sandbox_obj "session" then
      let* sess_obj = required_object_field sandbox_obj "session" in
      let* session = decode_ssh_keeper_session ~observed_at sess_obj in
      let* pool =
        match optional_object_field sandbox_obj "pool" with
        | Ok None -> Ok None
        | Ok (Some pool_obj) ->
            let* p = decode_ssh_pool ~observed_at pool_obj in
            Ok (Some p)
        | Error _ as err -> err
      in
      Ok (Sandbox_ssh_keeper { session; pool })
    else if has_field sandbox_obj "last_dispatch" then
      let* session = decode_ssh_keeper_session ~observed_at sandbox_obj in
      Ok (Sandbox_ssh_keeper { session; pool = None })
    else
      let* d = decode_docker_keeper ~observed_at sandbox_obj in
      Ok (Sandbox_docker d)
  in
  Ok { keeper; probe_state; sandbox }

let encode_sandbox_probe_request = function
  | `All -> `Assoc [ ("scope", `String "all") ]
  | `Keeper name ->
      `Assoc [ ("scope", `Assoc [ ("keeper", `String name) ]) ]
  | `Ssh_pool pool ->
      `Assoc [ ("scope", `Assoc [ ("ssh_pool", `String pool) ]) ]

type repo_status =
  | Repo_active
  | Repo_paused
  | Repo_cloning
  | Repo_error of string

type repository = {
  id : string;
  name : string;
  codebase : string option;
  url : string;
  resolved_local_path : string;
  default_branch : string;
  status : repo_status;
  keepers : string list;
  auto_sync : bool;
}

type file_change_kind =
  | File_added
  | File_modified
  | File_deleted
  | File_renamed

type file_change = {
  path : string;
  kind : file_change_kind;
  additions : int Observed.t;
  deletions : int Observed.t;
  keeper : string option;
  diff_preview : string option;
}

(* The four words [Repo_manager_types.status_wire_name] writes. The server
   sends [error_message] beside "error" every time, so an "error" without its
   cause is not a status this can complete. *)
let decode_repo_status json =
  let* word = required_nonblank_string json "status" in
  let* error_message = optional_nonblank_string json "error_message" in
  match word with
  | "active" -> Ok Repo_active
  | "paused" -> Ok Repo_paused
  | "cloning" -> Ok Repo_cloning
  | "error" -> (
      match error_message with
      | Some message -> Ok (Repo_error message)
      | None -> Error "repository status \"error\" carries no error_message")
  | other -> Error (Printf.sprintf "unknown repository status %S" other)

let decode_repository json =
  let* id = required_nonblank_string json "id" in
  let* name = required_nonblank_string json "name" in
  let* codebase = optional_nonblank_string json "codebase" in
  let* url = required_nonblank_string json "url" in
  (* [local_path] is the stored declaration and is often relative to the
     server's base path, which only the server knows. *)
  let* resolved_local_path = required_nonblank_string json "resolved_local_path" in
  let* default_branch = required_nonblank_string json "default_branch" in
  let* status = decode_repo_status json in
  let* keepers = optional_string_list json "keepers" in
  let* auto_sync = decode_bool_field_or json "auto_sync" ~default:false in
  Ok
    {
      id;
      name;
      codebase;
      url;
      resolved_local_path;
      default_branch;
      status;
      keepers;
      auto_sync;
    }

let decode_repositories json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "repositories" in
  decode_list "repositories" decode_repository items

let file_change_kind_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "added" | "add" | "a" -> Some File_added
  | "modified" | "modify" | "m" -> Some File_modified
  | "deleted" | "delete" | "d" -> Some File_deleted
  | "renamed" | "rename" | "r" -> Some File_renamed
  | _ -> None

let decode_file_change ~observed_at json =
  let* path = required_nonblank_string json "path" in
  let* kind = decode_enum ~field:"kind" file_change_kind_of_string json in
  let* additions = observed_int ~observed_at json "additions" in
  let* deletions = observed_int ~observed_at json "deletions" in
  let* keeper = optional_nonblank_string json "keeper" in
  let* diff_preview = optional_string_field json "diff_preview" in
  Ok { path; kind; additions; deletions; keeper; diff_preview }

let decode_file_changes ~observed_at json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "changes" in
  decode_list "changes" (decode_file_change ~observed_at) items

type log_level =
  | Log_debug
  | Log_info
  | Log_warn
  | Log_error

type system_log_entry = {
  seq : int;
  ts : string;
  level : log_level;
  source : string;
  module_name : string;
  message : string;
  keeper : string option;
  turn_id : int option;
  category : string option;
  details : Yojson.Safe.t;
}

let log_level_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "debug" -> Some Log_debug
  | "info" -> Some Log_info
  | "warn" | "warning" -> Some Log_warn
  | "error" | "err" | "critical" -> Some Log_error
  | _ -> None

let log_level_to_string = function
  | Log_debug -> "debug"
  | Log_info -> "info"
  | Log_warn -> "warn"
  | Log_error -> "error"

let decode_system_log_entry json =
  let* seq = required_int_field json "seq" in
  let* ts = required_nonblank_string json "ts" in
  let* level = decode_enum ~field:"level" log_level_of_string json in
  let* source = required_nonblank_string json "source" in
  let* module_name = required_nonblank_string json "module" in
  let* message = required_string_field json "message" in
  let* keeper = optional_nonblank_string json "keeper_name" in
  let* turn_id = optional_int_field json "turn_id" in
  let* category = optional_nonblank_string json "category" in
  let details = member "details" json in
  Ok
    {
      seq;
      ts;
      level;
      source;
      module_name;
      message;
      keeper;
      turn_id;
      category;
      details;
    }

let decode_system_log_snapshot json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "entries" in
  decode_list "entries" decode_system_log_entry items

type system_log_frame = { reset : bool; entries : system_log_entry list }

let decode_system_log_frame json =
  let* reset = required_bool_field json "reset" in
  let* entries = decode_system_log_snapshot json in
  Ok { reset; entries }
