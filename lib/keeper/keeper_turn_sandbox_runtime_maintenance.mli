(** Ending a turn and cleaning build output: the cleanup of a turn runtime,
    which only drops the handle because the container or guest outlives the
    turn, the report of a guest build cleanup, the audit and the run of a
    build maintenance on an Apple guest, and the cleanup of the builds of the
    guests attached to a workspace.

    [Keeper_turn_sandbox_runtime] includes this module. *)

open Keeper_meta_contract
open Keeper_turn_sandbox_runtime_record

val cleanup : t -> unit

type build_cleanup_report = { cleaned : int; failed : int }

val build_cleanup_report_of_string : string -> (build_cleanup_report, string) result

val cleanup_attached_builds : config:Workspace.config ->
  meta:keeper_meta -> retention_sec:float -> unit ->
  (build_cleanup_report option, string) result
