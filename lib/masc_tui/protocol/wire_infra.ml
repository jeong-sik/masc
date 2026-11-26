open Masc_tui_core
open Json_decode_fields
open Wire_common

let ( let* ) = Result.bind

let infra_sandboxes_path = "/api/v1/infra/sandboxes"

let infra_sandbox_keeper_path ~keeper =
  "/api/v1/infra/sandboxes/" ^ percent_encode keeper

let infra_sandboxes_probe_path = "/api/v1/infra/sandboxes/probe"
let repositories_path = "/api/v1/repositories"
let repository_pulls_path = "/api/v1/repositories/pulls"

let repository_detail_path ~repo_id =
  "/api/v1/repositories/" ^ percent_encode repo_id

let repository_activity_window_hours = 24.0

let repository_activity_path ~repo_id =
  Printf.sprintf "/api/v1/ide/repository-activity?repo_id=%s&window_hours=%g"
    (percent_encode repo_id) repository_activity_window_hours

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

type line_range = {
  start_line : int;
  end_line : int;
}

type edit_occurrence = {
  old_range : line_range;
  new_range : line_range option;
}

type line_evidence =
  | Edit_ranges of edit_occurrence list
  | Edit_ranges_omitted
  | Write_range of line_range option

type change_kind =
  | Change_edit of {
      before : string;
      after : string;
      replace_all : bool;
    }
  | Change_write of { content : string }
  | Change_insert of {
      line : int;
      text : string;
    }
  | Change_materialize of { sha256 : string }

type file_change = {
  path : string;
  keeper : string;
  change : change_kind;
  line_evidence : line_evidence option;
  succeeded : bool;
}

type repository_activity = {
  window_hours : float;
  changes : file_change list;
  incomplete : int;
  unattributed : int;
}

type line_counts = {
  added : int option;
  removed : int option;
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

(* Each change row is one logged file-writing tool call, as
   [Keeper_tool_call_file_change.to_json] writes it. *)

let decode_line_range json =
  let* start_line = required_int_field json "start_line" in
  let* end_line = required_int_field json "end_line" in
  if start_line < 1 then Error "line range start_line must be at least 1"
  else if end_line < start_line then
    Error "line range end_line must not precede start_line"
  else Ok { start_line; end_line }

let decode_nullable_line_range json key =
  let* value = required_member json key in
  match value with
  | `Null -> Ok None
  | `Assoc _ as range ->
      let* decoded = decode_line_range range in
      Ok (Some decoded)
  | bad -> field_type_error key "a line range or null" bad

let decode_edit_occurrence json =
  let* old_obj = required_object_field json "old_range" in
  let* old_range = decode_line_range old_obj in
  let* new_range = decode_nullable_line_range json "new_range" in
  Ok { old_range; new_range }

(* [null] on rows logged before the producer recorded line evidence.
   [occurrences] is [null] only above the producer's range limit, and is
   otherwise one entry per occurrence. *)
let decode_line_evidence json =
  let* evidence = required_member json "line_evidence" in
  match evidence with
  | `Null -> Ok None
  | `Assoc _ as ev -> (
      let* kind = required_nonblank_string ev "kind" in
      match kind with
      | "edit" -> (
          let* occurrence_count = required_int_field ev "occurrence_count" in
          let* occurrences = required_member ev "occurrences" in
          match occurrences with
          | `Null -> Ok (Some Edit_ranges_omitted)
          | `List items ->
              let* ranges =
                decode_list "occurrences" decode_edit_occurrence items
              in
              if Int.equal (List.length ranges) occurrence_count then
                Ok (Some (Edit_ranges ranges))
              else
                Error
                  (Printf.sprintf
                     "line_evidence occurrence_count %d names %d occurrences"
                     occurrence_count (List.length ranges))
          | bad -> field_type_error "occurrences" "a list or null" bad)
      | "write" ->
          let* new_range = decode_nullable_line_range ev "new_range" in
          Ok (Some (Write_range new_range))
      | other -> Error (Printf.sprintf "unknown line_evidence kind %S" other))
  | bad -> field_type_error "line_evidence" "an object or null" bad

let decode_change_kind json =
  let* change = required_object_field json "change" in
  let* kind = required_nonblank_string change "kind" in
  match kind with
  | "edit" ->
      let* before = required_string_field change "before" in
      let* after = required_string_field change "after" in
      let* replace_all = required_bool_field change "replace_all" in
      Ok (Change_edit { before; after; replace_all })
  | "write" ->
      let* content = required_string_field change "content" in
      Ok (Change_write { content })
  | "insert" ->
      let* line = required_int_field change "line" in
      let* text = required_string_field change "text" in
      Ok (Change_insert { line; text })
  | "materialize" ->
      let* sha256 = required_nonblank_string change "sha256" in
      Ok (Change_materialize { sha256 })
  | other -> Error (Printf.sprintf "unknown file change kind %S" other)

(* The server keeps only rows whose location is [repo] with the asked id
   ([Server_ide_http.repository_activity_json]). The location is read as the
   closed set the projection writes; a bundle or absolute target, or another
   repository, means the answer is not for this repository. *)
let decode_repo_change_path ~repo_id json =
  let* location = required_object_field json "location" in
  let* kind = required_nonblank_string location "kind" in
  match kind with
  | "repo" ->
      let* row_repo_id = required_nonblank_string location "repo_id" in
      let* path = required_string_field location "path" in
      if String.equal row_repo_id repo_id then Ok path
      else
        Error
          (Printf.sprintf "a change in repository %S answered for %S"
             row_repo_id repo_id)
  | "bundle" | "absolute" ->
      Error
        (Printf.sprintf "repository activity for %S carries a %s location"
           repo_id kind)
  | other -> Error (Printf.sprintf "unknown change location kind %S" other)

let decode_repo_file_change ~repo_id json =
  let* path = decode_repo_change_path ~repo_id json in
  let* keeper = required_nonblank_string json "keeper" in
  let* change = decode_change_kind json in
  let* line_evidence = decode_line_evidence json in
  let* succeeded = required_bool_field json "succeeded" in
  Ok { path; keeper; change; line_evidence; succeeded }

let refused_repository_activity json =
  let* error = optional_nonblank_string json "error" in
  match error with
  | Some reason -> Error ("repository activity refused: " ^ reason)
  | None -> Error "repository activity answered ok=false without an error"

(* [Server_ide_http.json_ok] wraps the answer as [{ok; data}]. *)
let decode_repository_activity ~repo_id json =
  let* ok = required_bool_field json "ok" in
  if not ok then refused_repository_activity json
  else
    let* data = required_object_field json "data" in
    let* answered_repo_id = required_nonblank_string data "repo_id" in
    if not (String.equal answered_repo_id repo_id) then
      Error
        (Printf.sprintf "repository activity for %S answered for %S" repo_id
           answered_repo_id)
    else
      let* window_hours = required_finite_float data "window_hours" in
      let* items = required_list_field data "changes" in
      let* changes =
        decode_list "changes" (decode_repo_file_change ~repo_id) items
      in
      let* incomplete = required_nonnegative_int_field data "incomplete" in
      let* unattributed = required_nonnegative_int_field data "unattributed" in
      Ok { window_hours; changes; incomplete; unattributed }

(* The ranges are the lines the replaced and the replacing text occupy
   ([Keeper_file_change_evidence]), so their lengths are exact. An insert is
   one non-empty line put above an existing one
   ([Keeper_tool_patch.Insert_before_line]); its evidence also spans the line
   it went above, which did not change, so the insert is counted from its kind
   instead. Anything the row does not determine stays [None]. *)
let range_line_count range = range.end_line - range.start_line + 1

let optional_range_line_count = function
  | Some range -> range_line_count range
  | None -> 0

let unreported_line_counts = { added = None; removed = None }

let file_change_line_counts change =
  if not change.succeeded then unreported_line_counts
  else
    match (change.change, change.line_evidence) with
    | Change_edit _, Some (Edit_ranges occurrences) ->
        let sum count_of =
          List.fold_left (fun total occ -> total + count_of occ) 0 occurrences
        in
        {
          added = Some (sum (fun occ -> optional_range_line_count occ.new_range));
          removed = Some (sum (fun occ -> range_line_count occ.old_range));
        }
    | Change_write _, Some (Write_range new_range) ->
        { added = Some (optional_range_line_count new_range); removed = None }
    | ( Change_insert _,
        (None | Some (Edit_ranges _ | Edit_ranges_omitted | Write_range _)) ) ->
        { added = Some 1; removed = Some 0 }
    | Change_edit _, (None | Some (Edit_ranges_omitted | Write_range _))
    | Change_write _, (None | Some (Edit_ranges _ | Edit_ranges_omitted))
    | ( Change_materialize _,
        (None | Some (Edit_ranges _ | Edit_ranges_omitted | Write_range _)) ) ->
        unreported_line_counts

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

(* --- Wave 3: Activity Backfill, Runtime Trace, Workspace Code Browser & Git --- *)

let activity_events_path ?(limit = 200) ?(after_seq = 0) () =
  Printf.sprintf "/api/v1/activity/events?limit=%d&after_seq=%d" (max 1 limit)
    (max 0 after_seq)

let keeper_runtime_trace_path ~keeper ?(limit = 50) () =
  Printf.sprintf "/api/v1/keepers/%s/runtime-trace?limit=%d"
    (percent_encode keeper) (max 1 limit)

type workspace_scope =
  | Ws_project
  | Ws_repo of string
  | Ws_keeper of string

let equal_workspace_scope a b =
  match a, b with
  | Ws_project, Ws_project -> true
  | Ws_repo x, Ws_repo y | Ws_keeper x, Ws_keeper y -> String.equal x y
  | Ws_project, (Ws_repo _ | Ws_keeper _)
  | Ws_repo _, (Ws_project | Ws_keeper _)
  | Ws_keeper _, (Ws_project | Ws_repo _) ->
      false

let workspace_scope_label = function
  | Ws_project -> "project"
  | Ws_repo r -> "repo:" ^ r
  | Ws_keeper k -> "keeper:" ^ k

let scope_query_params = function
  | Ws_project -> []
  | Ws_repo id -> [ "repo_id=" ^ percent_encode id ]
  | Ws_keeper k -> [ "keeper=" ^ percent_encode k ]

let with_query base params =
  match params with
  | [] -> base
  | ps -> base ^ "?" ^ String.concat "&" ps

let workspace_children_path ~scope ~path ?(limit = 200) () =
  let params =
    scope_query_params scope
    @ [ "path=" ^ percent_encode path; Printf.sprintf "limit=%d" (max 1 limit) ]
  in
  with_query "/api/v1/workspace/children" params

let normalized_workspace_path path =
  let p = Option.value ~default:"" path in
  if String.equal (String.trim p) "." then "" else p

let workspace_files_path ~scope ?path () =
  let params =
    scope_query_params scope
    @ [ "path=" ^ percent_encode (normalized_workspace_path path) ]
  in
  with_query "/api/v1/workspace/files" params

let workspace_search_path ~scope ?path ~query ?(ignore_case = true) () =
  let params =
    scope_query_params scope
    @ [
        "path=" ^ percent_encode (normalized_workspace_path path);
        "q=" ^ percent_encode query;
        "ignore_case=" ^ if ignore_case then "1" else "0";
      ]
  in
  with_query "/api/v1/workspace/search" params

let workspace_file_path ~scope ~path () =
  with_query "/api/v1/workspace/file"
    (scope_query_params scope @ [ "path=" ^ percent_encode path ])

let git_branches_path ~scope ?path () =
  let params =
    scope_query_params scope
    @ [ "path=" ^ percent_encode (normalized_workspace_path path) ]
  in
  with_query "/api/v1/git/branches" params

let git_worktrees_path ~scope ?path () =
  let params =
    scope_query_params scope
    @ [ "path=" ^ percent_encode (normalized_workspace_path path) ]
  in
  with_query "/api/v1/git/worktrees" params

let git_status_path ~scope () =
  with_query "/api/v1/git/status" (scope_query_params scope)

let git_blame_path ~scope ~path () =
  with_query "/api/v1/git/blame"
    (scope_query_params scope @ [ "path=" ^ percent_encode path ])

let git_log_path ~scope ~path ?(limit = 50) () =
  with_query "/api/v1/git/log"
    (scope_query_params scope
    @ [ "path=" ^ percent_encode path; Printf.sprintf "limit=%d" (max 1 limit) ])

let git_diff_path ~scope ~path () =
  with_query "/api/v1/git/diff"
    (scope_query_params scope @ [ "path=" ^ percent_encode path ])

type activity_event_item = {
  seq : int;
  ts_ms : int;
  ts_iso : string;
  kind : string;
  actor_id : string option;
  actor_kind : string option;
  subject_id : string option;
  tags : string list;
  payload : Yojson.Safe.t;
}

let decode_activity_event_item json =
  let* seq = required_int_field json "seq" in
  let* ts_ms = required_int_field json "ts_ms" in
  let* ts_iso = required_nonblank_string json "ts_iso" in
  let* kind = required_nonblank_string json "kind" in
  let actor_id, actor_kind =
    match optional_object_field json "actor" with
    | Ok (Some a) ->
        let id =
          match optional_nonblank_string a "id" with Ok v -> v | Error _ -> None
        in
        let k =
          match optional_nonblank_string a "kind" with Ok v -> v | Error _ -> None
        in
        (id, k)
    | Ok None | Error _ -> (None, None)
  in
  let subject_id =
    match optional_object_field json "subject" with
    | Ok (Some s) -> (
        match optional_nonblank_string s "id" with Ok v -> v | Error _ -> None)
    | Ok None | Error _ -> None
  in
  let* tags = optional_string_list json "tags" in
  let payload = member "payload" json in
  Ok { seq; ts_ms; ts_iso; kind; actor_id; actor_kind; subject_id; tags; payload }

let decode_activity_events_page json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "events" in
  let* events = decode_list "events" decode_activity_event_item items in
  let next_seq =
    match optional_int_field body "next_after_seq" with
    | Ok (Some n) -> n
    | Ok None | Error _ -> (
        match optional_int_field body "latest_seq" with
        | Ok (Some n) -> n
        | Ok None | Error _ -> 0)
  in
  Ok (events, next_seq)

type runtime_trace_snapshot = {
  keeper : string;
  trace_id : string;
  turn_id : int option;
  health : string;
  stale_reason : string option;
  manifest_total_rows : int;
  manifest_returned_rows : int;
  receipt_returned_rows : int;
  raw : Yojson.Safe.t;
}

let int_or_zero_infra json key =
  match optional_int_field json key with Ok (Some n) -> n | Ok None | Error _ -> 0

let decode_runtime_trace json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let trace_id =
    match optional_string_field body "trace_id" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let* turn_id = optional_int_field body "turn_id" in
  let health =
    match optional_nonblank_string body "health" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> "empty"
  in
  let* stale_reason = optional_nonblank_string body "stale_reason" in
  Ok
    {
      keeper;
      trace_id;
      turn_id;
      health;
      stale_reason;
      manifest_total_rows = int_or_zero_infra body "manifest_total_rows";
      manifest_returned_rows = int_or_zero_infra body "manifest_returned_rows";
      receipt_returned_rows = int_or_zero_infra body "receipt_returned_rows";
      raw = body;
    }

type workspace_tree_node = {
  path : string;
  label : string;
  depth : int;
  parent : string;
  has_children : bool;
  diff : string option;
  keeper_id : string option;
}

type workspace_files_catalog = {
  root : string;
  files : string list;
}

type workspace_search_match = {
  path : string;
  line : int;
  text : string;
}

type workspace_search_result = {
  root : string;
  query : string;
  matches : workspace_search_match list;
  truncated : bool;
}

type workspace_file_content = {
  path : string;
  content : string;
  revision : string;
}

type git_branch_entry = {
  name : string;
  current : bool;
  upstream_name : string option;
  ahead : int option;
  behind : int option;
  commit_epoch : int;
  subject : string;
}

type git_worktree_entry = {
  name : string;
  main : bool;
  head : string option;
  state : string;
  branch : string option;
  locked : bool;
  prunable : bool;
}

type git_status_change = {
  path : string;
  staged : bool;
  unstaged : bool;
  untracked : bool;
  conflicted : bool;
}

type git_status_snapshot = {
  head : string option;
  upstream : string option;
  total : int;
  changes : git_status_change list;
}

type git_blame_entry = {
  file_path : string;
  line_start : int;
  line_end : int;
  keeper_id : string;
  timestamp_ms : int;
  kind : string;
}

type git_log_commit = {
  hash : string;
  timestamp_ms : int;
  author : string;
  subject : string;
}

type git_diff_line = {
  kind : [ `Add | `Delete | `Context ];
  old_line : int option;
  new_line : int option;
  text : string;
}

type git_diff_hunk = {
  old_start : int;
  old_count : int;
  new_start : int;
  new_count : int;
  section : string option;
}

type git_diff_row =
  | Hunk of git_diff_hunk
  | Line of git_diff_line

type git_diff_snapshot = {
  has_changes : bool;
  rows : git_diff_row list;
}

let decode_workspace_tree_node json =
  let* path = required_nonblank_string json "path" in
  let label =
    match optional_nonblank_string json "label" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> Filename.basename path
  in
  let depth = int_or_zero_infra json "depth" in
  let parent =
    match optional_string_field json "parent" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let has_children =
    match optional_bool_field json "hasChildren" with
    | Ok (Some b) -> b
    | Ok None | Error _ -> false
  in
  let* diff = optional_nonblank_string json "diff" in
  let* keeper_id = optional_nonblank_string json "keeperId" in
  Ok { path; label; depth; parent; has_children; diff; keeper_id }

let decode_workspace_children json =
  match json with
  | `List items -> decode_list "children" decode_workspace_tree_node items
  | `Assoc _ -> (
      let* _, body = unwrap_v2_or_raw json in
      match optional_list_field body "children" with
      | Ok (_ :: _ as items) -> decode_list "children" decode_workspace_tree_node items
      | Ok [] -> (
          match optional_list_field body "entries" with
          | Ok items -> decode_list "entries" decode_workspace_tree_node items
          | Error _ as err -> err)
      | Error _ as err -> err)
  | _ -> Error "workspace/children expected JSON array or object"

let decode_workspace_files json =
  let* _, body = unwrap_v2_or_raw json in
  let root =
    match optional_string_field body "root" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> "."
  in
  let* files = required_string_list body "files" in
  Ok { root; files }

let decode_workspace_search_match json =
  let* path = required_nonblank_string json "path" in
  let* line = required_int_field json "line" in
  let* text = required_string_field json "text" in
  Ok { path; line; text }

let decode_workspace_search json =
  let* _, body = unwrap_v2_or_raw json in
  let root =
    match optional_string_field body "root" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> "."
  in
  let query =
    match optional_string_field body "query" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let* items = required_list_field body "matches" in
  let* matches = decode_list "matches" decode_workspace_search_match items in
  let truncated =
    match optional_bool_field body "truncated" with
    | Ok (Some b) -> b
    | Ok None | Error _ -> false
  in
  Ok { root; query; matches; truncated }

let decode_workspace_file ~path json =
  let* _, body = unwrap_v2_or_raw json in
  let* content = required_string_field body "content" in
  let revision =
    match optional_string_field body "revision" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  Ok { path; content; revision }

let decode_git_branch_entry json =
  let* name = required_nonblank_string json "name" in
  let current =
    match optional_bool_field json "current" with
    | Ok (Some b) -> b
    | Ok None | Error _ -> false
  in
  let upstream_name, ahead, behind =
    match optional_object_field json "upstream" with
    | Ok (Some u) ->
        let uname =
          match optional_nonblank_string u "name" with Ok v -> v | Error _ -> None
        in
        let ah =
          match optional_int_field u "ahead" with Ok v -> v | Error _ -> None
        in
        let bh =
          match optional_int_field u "behind" with Ok v -> v | Error _ -> None
        in
        (uname, ah, bh)
    | Ok None | Error _ -> (None, None, None)
  in
  let commit_epoch = int_or_zero_infra json "commit_epoch" in
  let subject =
    match optional_string_field json "subject" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  Ok { name; current; upstream_name; ahead; behind; commit_epoch; subject }

let decode_git_branches json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "branches" in
  decode_list "branches" decode_git_branch_entry items

let decode_git_worktree_entry json =
  let* name = required_nonblank_string json "name" in
  let main =
    match optional_bool_field json "main" with
    | Ok (Some b) -> b
    | Ok None | Error _ -> false
  in
  let* head = optional_nonblank_string json "head" in
  let state =
    match optional_nonblank_string json "state" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> "branch"
  in
  let* branch = optional_nonblank_string json "branch" in
  let locked =
    match optional_bool_field json "locked" with
    | Ok (Some b) -> b
    | Ok None | Error _ -> false
  in
  let prunable =
    match optional_bool_field json "prunable" with
    | Ok (Some b) -> b
    | Ok None | Error _ -> false
  in
  Ok { name; main; head; state; branch; locked; prunable }

let decode_git_worktrees json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "worktrees" in
  decode_list "worktrees" decode_git_worktree_entry items

let decode_git_status_change json =
  let* path = required_nonblank_string json "path" in
  let bool_or_f k =
    match optional_bool_field json k with Ok (Some b) -> b | Ok None | Error _ -> false
  in
  Ok
    {
      path;
      staged = bool_or_f "staged";
      unstaged = bool_or_f "unstaged";
      untracked = bool_or_f "untracked";
      conflicted = bool_or_f "conflicted";
    }

let decode_git_status json =
  let* _, body = unwrap_v2_or_raw json in
  let head, upstream =
    match optional_object_field body "branch" with
    | Ok (Some b) ->
        let h =
          match optional_nonblank_string b "head" with Ok v -> v | Error _ -> None
        in
        let u =
          match optional_nonblank_string b "upstream" with
          | Ok (Some s) -> Some s
          | Ok None | Error _ -> (
              match optional_object_field b "upstream" with
              | Ok (Some uo) -> (
                  match optional_nonblank_string uo "name" with
                  | Ok v -> v
                  | Error _ -> None)
              | Ok None | Error _ -> None)
        in
        (h, u)
    | Ok None | Error _ -> (None, None)
  in
  let* items = optional_list_field body "changes" in
  let* changes = decode_list "changes" decode_git_status_change items in
  let total =
    match optional_int_field body "total" with
    | Ok (Some n) -> n
    | Ok None | Error _ -> List.length changes
  in
  Ok { head; upstream; total; changes }

let decode_git_blame_entry json =
  let* file_path = required_nonblank_string json "file_path" in
  let line_start = int_or_zero_infra json "line_start" in
  let line_end = int_or_zero_infra json "line_end" in
  let* keeper_id = required_nonblank_string json "keeper_id" in
  let timestamp_ms = int_or_zero_infra json "timestamp_ms" in
  let kind =
    match optional_nonblank_string json "kind" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> "edit"
  in
  Ok { file_path; line_start; line_end; keeper_id; timestamp_ms; kind }

let decode_git_blame json =
  match json with
  | `List items -> decode_list "blame" decode_git_blame_entry items
  | `Assoc _ ->
      let* _, body = unwrap_v2_or_raw json in
      let* items = optional_list_field body "entries" in
      decode_list "entries" decode_git_blame_entry items
  | _ -> Error "git/blame expected JSON array or object"

let decode_git_log_commit json =
  let* hash = required_nonblank_string json "hash" in
  let timestamp_ms = int_or_zero_infra json "timestamp_ms" in
  let author =
    match optional_string_field json "author" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let subject =
    match optional_string_field json "subject" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  Ok { hash; timestamp_ms; author; subject }

let decode_git_log json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "commits" in
  decode_list "commits" decode_git_log_commit items

let decode_git_diff_line ~kind json =
  let* old_line = optional_int_field json "oldLine" in
  let* new_line = optional_int_field json "newLine" in
  let* text = required_string_field json "text" in
  Ok (Line { kind; old_line; new_line; text })

let decode_git_diff_hunk json =
  let* old_start = required_int_field json "oldStart" in
  let* old_count = required_int_field json "oldCount" in
  let* new_start = required_int_field json "newStart" in
  let* new_count = required_int_field json "newCount" in
  let* section = optional_string_field json "section" in
  Ok (Hunk { old_start; old_count; new_start; new_count; section })

let decode_git_diff_row json =
  let* kind = required_nonblank_string json "kind" in
  match kind with
  | "hunk" -> decode_git_diff_hunk json
  | "add" -> decode_git_diff_line ~kind:`Add json
  | "delete" -> decode_git_diff_line ~kind:`Delete json
  | "context" -> decode_git_diff_line ~kind:`Context json
  | other -> Error (Printf.sprintf "unknown git diff row kind %S" other)

let decode_git_diff json =
  let* _, body = unwrap_v2_or_raw json in
  let* has_changes = required_bool_field body "has_changes" in
  let* items = required_list_field body "unified" in
  let* rows = decode_list "unified" decode_git_diff_row items in
  Ok { has_changes; rows }

(* --- Repository Open Pull Requests & Per-Repo Git Observation --- *)

type repository_pull_row = {
  repo_slug : string;
  number : int;
  draft : bool;
  checks : string;
  review : string;
  mergeable : string;
  author : string option;
  keeper : string option;
  title : string option;
  head_review : string;
}

type repository_pulls_entry = {
  repository_id : string;
  slug : string option;
  state : string;
  pulls : repository_pull_row list;
  undecodable : int;
  failure_summary : string option;
}

type repository_pulls_snapshot = {
  reader_state : string;
  reader_detail : string option;
  repositories_error : string option;
  entries : repository_pulls_entry list;
}

let decode_pull_row json =
  let* repo_slug = required_nonblank_string json "repo_slug" in
  let* number = required_int_field json "number" in
  let* draft = decode_bool_field_or json "draft" ~default:false in
  let checks =
    match optional_nonblank_string json "checks" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> "none"
  in
  let review =
    match optional_nonblank_string json "review" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> "none"
  in
  let mergeable =
    match optional_nonblank_string json "mergeable" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> "unknown"
  in
  let author =
    match optional_nonblank_string json "author" with
    | Ok v -> v
    | Error _ -> None
  in
  let keeper =
    match optional_nonblank_string json "keeper" with
    | Ok v -> v
    | Error _ -> None
  in
  let title =
    match optional_nonblank_string json "title" with
    | Ok v -> v
    | Error _ -> None
  in
  let head_review =
    match optional_nonblank_string json "head_review" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> "unknown"
  in
  Ok
    {
      repo_slug;
      number;
      draft;
      checks;
      review;
      mergeable;
      author;
      keeper;
      title;
      head_review;
    }

let format_pull_failure failure_json =
  match failure_json with
  | `Assoc _ -> (
      match optional_nonblank_string failure_json "kind" with
      | Ok (Some "rate_limited") -> Some "GitHub rate limited"
      | Ok (Some "token_rejected") -> Some "GitHub token rejected (401)"
      | Ok (Some "repository_not_visible") -> Some "Repository not visible"
      | Ok (Some "forbidden") -> Some "GitHub access forbidden (403)"
      | Ok (Some "http_status") -> (
          match optional_int_field failure_json "status" with
          | Ok (Some code) -> Some (Printf.sprintf "GitHub HTTP %d" code)
          | Ok None | Error _ -> Some "GitHub HTTP error")
      | Ok (Some "graphql_errors") -> (
          match optional_list_field failure_json "messages" with
          | Ok (`String m :: _) -> Some m
          | Ok _ | Error _ -> Some "GraphQL error")
      | Ok (Some ("transport_failed" | "response_unreadable" as kind)) -> (
          match optional_nonblank_string failure_json "message" with
          | Ok (Some msg) -> Some msg
          | Ok None | Error _ -> Some kind)
      | Ok (Some other) -> Some other
      | Ok None | Error _ -> None)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None

let decode_repository_pulls_entry json =
  let* repository_id = required_nonblank_string json "repository_id" in
  let slug =
    match optional_nonblank_string json "slug" with
    | Ok v -> v
    | Error _ -> None
  in
  let pulls_obj = member "pulls" json in
  let state =
    match pulls_obj with
    | `Assoc _ -> (
        match optional_nonblank_string pulls_obj "state" with
        | Ok (Some s) -> s
        | Ok None | Error _ -> "not_read")
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        "not_read"
  in
  let* pulls =
    match pulls_obj with
    | `Assoc _ -> (
        let* items = optional_list_field pulls_obj "pulls" in
        decode_list "pulls" decode_pull_row items)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        Ok []
  in
  let undecodable =
    match pulls_obj with
    | `Assoc _ -> int_or_zero_infra pulls_obj "undecodable"
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> 0
  in
  let failure_summary =
    match pulls_obj with
    | `Assoc _ -> format_pull_failure (member "failure" pulls_obj)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        None
  in
  Ok { repository_id; slug; state; pulls; undecodable; failure_summary }

let decode_repository_pulls json =
  let* _, body = unwrap_v2_or_raw json in
  let reader_obj = member "reader" body in
  let reader_state, reader_detail =
    match reader_obj with
    | `Assoc _ ->
        let st =
          match optional_nonblank_string reader_obj "state" with
          | Ok (Some s) -> s
          | Ok None | Error _ -> "unknown"
        in
        let detail =
          match optional_nonblank_string reader_obj "reason" with
          | Ok (Some r) -> Some r
          | Ok None | Error _ -> (
              match optional_nonblank_string reader_obj "keeper" with
              | Ok (Some k) -> Some ("@" ^ k)
              | Ok None | Error _ -> None)
        in
        (st, detail)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        ("unknown", None)
  in
  let repositories_error =
    match optional_nonblank_string body "repositories_error" with
    | Ok v -> v
    | Error _ -> None
  in
  let* items = optional_list_field body "repositories" in
  let* entries =
    decode_list "repositories" decode_repository_pulls_entry items
  in
  Ok { reader_state; reader_detail; repositories_error; entries }

type repo_git_status = {
  available : bool;
  dirty : bool;
  changed_files : int;
  conflicted_files : int;
  error : string option;
}

type repo_sync_currency = {
  available : bool;
  target_ref : string option;
  behind : int;
  ahead : int;
  error : string option;
}

type repository_observation = {
  repo_id : string;
  git_status : repo_git_status option;
  sync_currency : repo_sync_currency option;
}

let decode_repository_observation json =
  let* _, body = unwrap_v2_or_raw json in
  let target =
    match member "repository" body with
    | `Assoc _ as r -> r
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        body
  in
  let* repo_id = required_nonblank_string target "id" in
  let git_status =
    match member "git_status" target with
    | `Assoc _ as gs ->
        let state =
          match optional_nonblank_string gs "state" with
          | Ok (Some s) -> s
          | Ok None | Error _ -> "unavailable"
        in
        let available = String.equal state "available" in
        let dirty =
          match optional_bool_field gs "dirty" with
          | Ok (Some b) -> b
          | Ok None | Error _ -> false
        in
        let changed_files = int_or_zero_infra gs "changed_files" in
        let conflicted_files = int_or_zero_infra gs "conflicted_files" in
        let error =
          match optional_nonblank_string gs "error" with
          | Ok v -> v
          | Error _ -> None
        in
        Some { available; dirty; changed_files; conflicted_files; error }
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        None
  in
  let sync_currency =
    match member "sync_currency" target with
    | `Assoc _ as sc ->
        let state =
          match optional_nonblank_string sc "state" with
          | Ok (Some s) -> s
          | Ok None | Error _ -> "unavailable"
        in
        let available = String.equal state "available" in
        let target_ref =
          match optional_nonblank_string sc "target_ref" with
          | Ok v -> v
          | Error _ -> None
        in
        let behind = int_or_zero_infra sc "behind" in
        let ahead = int_or_zero_infra sc "ahead" in
        let error =
          match optional_nonblank_string sc "error" with
          | Ok v -> v
          | Error _ -> None
        in
        Some { available; target_ref; behind; ahead; error }
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        None
  in
  Ok { repo_id; git_status; sync_currency }

type activity_event_category =
  | Act_tool_call
  | Act_turn_complete
  | Act_agent_core

let classify_activity_event_kind raw =
  match String.lowercase_ascii (String.trim raw) with
  | "tool.called" | "keeper.tool_exec" -> Act_tool_call
  | "keeper.turn_completed"
  | "keeper.turn_input_required"
  | "keeper.turn_blocked"
  | "keeper.turn_cancelled"
  | "keeper.turn_skipped" ->
      Act_turn_complete
  | k when String.starts_with ~prefix:"tool." k -> Act_tool_call
  | k
    when String.starts_with ~prefix:"turn." k
         || String.starts_with ~prefix:"keeper.turn_" k ->
      Act_turn_complete
  | _ -> Act_agent_core

type guest_presence =
  | Presence_running
  | Presence_unobserved
  | Presence_other of string

let classify_guest_presence raw =
  match String.lowercase_ascii (String.trim raw) with
  | "running" -> Presence_running
  | "unobserved" -> Presence_unobserved
  | _ -> Presence_other raw

type pr_entry_state =
  | Pr_entry_read
  | Pr_entry_failed
  | Pr_entry_other of string

let classify_pr_entry_state raw =
  match String.lowercase_ascii (String.trim raw) with
  | "read" -> Pr_entry_read
  | "failed" -> Pr_entry_failed
  | _ -> Pr_entry_other raw

type pr_checks_state =
  | Checks_passing
  | Checks_running
  | Checks_failing
  | Checks_other of string

let classify_pr_checks_state raw =
  match String.lowercase_ascii (String.trim raw) with
  | "passing" -> Checks_passing
  | "running" -> Checks_running
  | "failing" -> Checks_failing
  | _ -> Checks_other raw

type pr_mergeable_state =
  | Mergeable_conflicting
  | Mergeable_other of string

let classify_pr_mergeable_state raw =
  match String.lowercase_ascii (String.trim raw) with
  | "conflicting" -> Mergeable_conflicting
  | _ -> Mergeable_other raw

type pr_review_state =
  | Review_approved
  | Review_changes_requested
  | Review_other of string

let classify_pr_review_state raw =
  match String.lowercase_ascii (String.trim raw) with
  | "approved" -> Review_approved
  | "changes_requested" -> Review_changes_requested
  | _ -> Review_other raw

type pr_head_review_state =
  | Head_not_reviewed
  | Head_review_other of string

let classify_pr_head_review_state raw =
  match String.lowercase_ascii (String.trim raw) with
  | "not_reviewed_on_head" -> Head_not_reviewed
  | _ -> Head_review_other raw

type pulls_reader_state =
  | Reader_ready
  | Reader_other of string

let classify_pulls_reader_state raw =
  match String.lowercase_ascii (String.trim raw) with
  | "ready" -> Reader_ready
  | _ -> Reader_other raw
