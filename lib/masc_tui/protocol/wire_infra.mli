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
val repository_pulls_path : string
val repository_detail_path : repo_id:string -> string
val repository_activity_path : repo_id:string -> string
(** [GET /api/v1/ide/repository-activity] for the last 24 hours. *)
val system_logs_path : ?limit:int -> ?level:string -> unit -> string
val system_logs_stream_path : ?since_seq:int -> unit -> string
val activity_events_path : ?limit:int -> ?after_seq:int -> unit -> string
val keeper_runtime_trace_path : keeper:string -> ?limit:int -> unit -> string

type workspace_scope =
  | Ws_project
  | Ws_repo of string
  | Ws_keeper of string

val equal_workspace_scope : workspace_scope -> workspace_scope -> bool
val workspace_scope_label : workspace_scope -> string
val workspace_children_path :
  scope:workspace_scope -> path:string -> ?limit:int -> unit -> string
val workspace_files_path :
  scope:workspace_scope -> ?path:string -> unit -> string
val workspace_search_path :
  scope:workspace_scope ->
  ?path:string ->
  query:string ->
  ?ignore_case:bool ->
  unit ->
  string
val workspace_file_path : scope:workspace_scope -> path:string -> unit -> string
val git_branches_path : scope:workspace_scope -> ?path:string -> unit -> string
val git_worktrees_path : scope:workspace_scope -> ?path:string -> unit -> string
val git_status_path : scope:workspace_scope -> unit -> string
val git_blame_path : scope:workspace_scope -> path:string -> unit -> string
val git_log_path :
  scope:workspace_scope -> path:string -> ?limit:int -> unit -> string
val git_diff_path : scope:workspace_scope -> path:string -> unit -> string

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
  | Repo_active
  | Repo_paused
  | Repo_cloning
  | Repo_error of string  (** The server's [error_message]. *)

type repository = {
  id : string;
  name : string;
  codebase : string option;
  url : string;
  resolved_local_path : string;
      (** The absolute checkout path the server resolved against its base
          path. *)
  default_branch : string;
  status : repo_status;
  keepers : string list;
  auto_sync : bool;
}

val decode_repositories : Yojson.Safe.t -> (repository list, string) result

(** {2 Repository activity}

    One row per logged file-writing tool call, as
    [Keeper_tool_call_file_change.to_json] writes it. The server keeps the
    rows whose target is a file in the asked repository. *)

type line_range = {
  start_line : int;
  end_line : int;
}
(** 1-based, inclusive. *)

type edit_occurrence = {
  old_range : line_range;
  new_range : line_range option;  (** [None] when the edit deleted the text. *)
}

(** The producer's record of the lines a completed change touched. *)
type line_evidence =
  | Edit_ranges of edit_occurrence list  (** One per replaced occurrence. *)
  | Edit_ranges_omitted
      (** More occurrences than the producer records ranges for. *)
  | Write_range of line_range option
      (** The written body's lines; [None] for an empty body. *)

type change_kind =
  | Change_edit of {
      before : string;
      after : string;
      replace_all : bool;
    }
  | Change_write of { content : string }  (** The whole file body. *)
  | Change_insert of {
      line : int;  (** The line the text went above. *)
      text : string;
    }
  | Change_materialize of { sha256 : string }
      (** A blob written into the file; the row names the blob, not its
          text. *)

type file_change = {
  path : string;  (** Relative to the repository root. *)
  keeper : string;
  change : change_kind;
  line_evidence : line_evidence option;
      (** [None] on rows logged before the producer recorded it. *)
  succeeded : bool;
      (** A failed or deferred call is still listed: it is a change the keeper
          attempted. *)
}

type repository_activity = {
  window_hours : float;
  changes : file_change list;
  incomplete : int;
      (** Calls in this repository whose row could not be read: over the
          log's inline budget, or malformed. *)
  unattributed : int;
      (** Unreadable calls anywhere in the fleet whose target is unknown. *)
}

val decode_repository_activity :
  repo_id:string -> Yojson.Safe.t -> (repository_activity, string) result
(** Rejects an answer for another repository and a change whose location is
    not this repository. *)

type line_counts = {
  added : int option;
  removed : int option;
}
(** [None] where the row does not determine the count. *)

val file_change_line_counts : file_change -> line_counts
(** Exact counts only. An edit with ranges counts the lines its replaced text
    ([old_range]) and its replacement ([new_range]) occupy. A write with a
    range counts the body's lines; what it replaced is not in the row. An
    insert is one line added. A failed call, an edit or write without ranges,
    and a materialized blob count nothing. *)

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

(** {1 Wave 3: Activity Backfill, Runtime Trace, Workspace Code Browser & Git} *)

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

val decode_activity_events_page :
  Yojson.Safe.t -> (activity_event_item list * int, string) result

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

val decode_runtime_trace :
  Yojson.Safe.t -> (runtime_trace_snapshot, string) result

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

type git_diff_snapshot = {
  has_changes : bool;
  lines : git_diff_line list;
}

val decode_workspace_children :
  Yojson.Safe.t -> (workspace_tree_node list, string) result
val decode_workspace_files :
  Yojson.Safe.t -> (workspace_files_catalog, string) result
val decode_workspace_search :
  Yojson.Safe.t -> (workspace_search_result, string) result
val decode_workspace_file :
  path:string -> Yojson.Safe.t -> (workspace_file_content, string) result
val decode_git_branches :
  Yojson.Safe.t -> (git_branch_entry list, string) result
val decode_git_worktrees :
  Yojson.Safe.t -> (git_worktree_entry list, string) result
val decode_git_status : Yojson.Safe.t -> (git_status_snapshot, string) result
val decode_git_blame : Yojson.Safe.t -> (git_blame_entry list, string) result
val decode_git_log : Yojson.Safe.t -> (git_log_commit list, string) result
val decode_git_diff : Yojson.Safe.t -> (git_diff_snapshot, string) result

(** {1 Repository Open Pull Requests & Per-Repo Git Observation} *)

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

val decode_repository_pulls :
  Yojson.Safe.t -> (repository_pulls_snapshot, string) result

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

val decode_repository_observation :
  Yojson.Safe.t -> (repository_observation, string) result
