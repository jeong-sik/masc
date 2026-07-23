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
(** [write_backlog ?after_commit config backlog] commits the primary SSOT,
    then attempts the recovery copy. Recovery-copy failure is logged and does
    not turn a committed primary mutation into a reported failure.
    Non-transition callers (GC, init, query) omit the callback.
    Raises [Backlog_write_failed] only when the primary SSOT did not commit. *)

exception Backlog_write_failed of string

type write_backlog_outcome =
  { primary_mirror_error : string option
  ; recovery_error : string option
  ; post_commit_error : string option
  }

val write_backlog_result :
  ?after_commit:(unit -> unit) ->
  Workspace_utils_backend_setup.config ->
  Masc_domain.backlog ->
  (write_backlog_outcome, string) result
(** Result-returning variant of {!write_backlog}. [Error] means the primary
    SSOT did not commit. Failures after a primary commit are returned in the
    corresponding [Ok] fields and logged explicitly. *)
