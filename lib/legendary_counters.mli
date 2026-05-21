(** In-process counters for keeper shell observers.

    Tracks live observer families: docker-sandbox gh exit classes and
    [Shell_command_gate] caller x verdict partitions. *)

val incr_gh_exit_class : Gh_exit_class.t -> unit
(** Record one docker-sandbox gh invocation under its exit class. *)

type shell_gate_caller =
  | Worker_dev_tools
  | Tool_code_write
  | Keeper_shell_bash

type shell_gate_verdict_kind =
  | Allow
  | Reject
  | Cannot_parse

val incr_shell_gate
  :  caller:shell_gate_caller
  -> verdict:shell_gate_verdict_kind
  -> unit
(** Record one [Shell_command_gate] verdict under the caller x verdict
    bucket. *)

val reset : unit -> unit
(** Zero every counter.  Used by tests. *)

type snapshot =
  { gh_exit_ok_0 : int
  ; gh_exit_policy_blocked : int
  ; gh_exit_type_mismatch : int
  ; gh_exit_auth_failed : int
  ; gh_exit_network : int
  ; gh_exit_unknown : int
  ; shell_gate_worker_dev_tools_allow : int
  ; shell_gate_worker_dev_tools_reject : int
  ; shell_gate_worker_dev_tools_cannot_parse : int
  ; shell_gate_tool_code_write_allow : int
  ; shell_gate_tool_code_write_reject : int
  ; shell_gate_tool_code_write_cannot_parse : int
  ; shell_gate_keeper_shell_bash_allow : int
  ; shell_gate_keeper_shell_bash_reject : int
  ; shell_gate_keeper_shell_bash_cannot_parse : int
  }

val snapshot : unit -> snapshot

val snapshot_to_json : snapshot -> Yojson.Safe.t
(** Stable JSON shape for dashboard / HTTP consumers. *)
