(** Infrastructure wire codecs: Unified Sandboxes ([/api/v1/infra/sandboxes] and
    [/api/v1/infra/sandboxes/:keeper] — [apple_container] microVMs +
    [remote_ssh] pools + Docker/host volume GC + tool failure breakdown),
    Repositories & Read-Only Git/Keeper Diffs, and Unified Activity & System
    Logs. *)

open Masc_tui_core

val infra_sandboxes_path : string
val infra_sandbox_keeper_path : keeper:string -> string
val infra_sandboxes_probe_path : string
val repositories_path : string
val keeper_file_changes_path : keeper:string -> ?window_hours:float -> unit -> string
val system_logs_path : ?limit:int -> ?level:string -> unit -> string
val system_logs_stream_path : ?since_seq:int -> unit -> string

(** {1 Unified Sandboxes (microVM + Remote SSH + Docker + Host Storage/GC)} *)

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

val decode_sandboxes_snapshot :
  observed_at:Clock.Mono.t -> Yojson.Safe.t -> (sandboxes_snapshot, string) result

val decode_keeper_sandbox :
  observed_at:Clock.Mono.t ->
  Yojson.Safe.t ->
  (keeper_sandbox_response, string) result
(** Decode [GET /api/v1/infra/sandboxes/:keeper]. *)

val encode_sandbox_probe_request :
  [ `All | `Keeper of string | `Ssh_pool of string ] -> Yojson.Safe.t

(** {1 Repositories & Read-Only Git / Keeper Diffs} *)

type repo_status =
  | Repo_synced
  | Repo_syncing
  | Repo_dirty
  | Repo_error of string
  | Repo_unknown of string

type repository = {
  id : string;
  name : string;
  codebase : string option;
  url : string;
  local_path : string;
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

val decode_repositories : Yojson.Safe.t -> (repository list, string) result

val decode_file_changes :
  observed_at:Clock.Mono.t -> Yojson.Safe.t -> (file_change list, string) result

(** {1 Unified Activity & System Logs} *)

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

val log_level_of_string : string -> log_level option
val log_level_to_string : log_level -> string
val decode_system_log_entry : Yojson.Safe.t -> (system_log_entry, string) result
val decode_system_log_snapshot : Yojson.Safe.t -> (system_log_entry list, string) result

type system_log_frame = { reset : bool; entries : system_log_entry list }
(** One [/api/v1/dashboard/logs/stream] frame, entries newest first. [reset]
    asks the client to replace its list with this page: the stream had no
    cursor, the ring evicted entries the client never got, more entries
    matched than one page, or the cursor came from an earlier server run. *)

val decode_system_log_frame : Yojson.Safe.t -> (system_log_frame, string) result
