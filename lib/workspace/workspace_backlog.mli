(** Workspace backlog persistence — read / write the canonical
    [tasks/backlog.json] document with structural recovery. *)

open Masc_domain
open Workspace_utils

val backlog_path : Workspace_utils_backend_setup.config -> string
val backlog_recovery_path : Workspace_utils_backend_setup.config -> string
val decode_backlog : path:string ->
           Yojson.Safe.t -> (Masc_domain.backlog, string) result
val read_backlog_r : Workspace_utils_backend_setup.config ->
           (Masc_domain.backlog, string) result
val read_backlog : Workspace_utils_backend_setup.config -> Masc_domain.backlog
val write_backlog :
  ?after_commit:(unit -> unit) ->
  Workspace_utils_backend_setup.config ->
  Masc_domain.backlog ->
  unit
(** [write_backlog ?after_commit config backlog] persists the backlog to
    both the primary and recovery paths, then invokes [after_commit] if
    provided.  Use [after_commit] for cache-invalidation side-effects that
    must not fire unless the backlog commit succeeded (RFC-0221 §3.3).
    Non-transition callers (GC, init, query) omit the callback. Raises
    [Sys_error] when {!write_backlog_result} reports a persistence failure. *)

val write_backlog_result :
  ?after_commit:(unit -> unit) ->
  Workspace_utils_backend_setup.config ->
  Masc_domain.backlog ->
  (unit, string) result
(** Result-returning variant of {!write_backlog}.  The backlog is considered
    persisted only after both primary/recovery writes succeed and the primary
    copy can be read back and decoded.  The cache is cleared and [after_commit]
    runs only on success. *)
