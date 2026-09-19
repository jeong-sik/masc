type runtime_entry =
  | Not_entered
  | Entered
(** Whether the callback invoked [Keeper_librarian_runtime.run_best_effort].
    [Entered] includes cadence deferral and failures that return normally; it
    does not assert that a model ran or a Memory snapshot committed. *)

val remember_turn : base_path:string -> keeper_name:string -> trace_id:string ->
  (meta:Keeper_meta_contract.keeper_meta -> Keeper_librarian_runtime.trigger -> runtime_entry) -> unit
(** Retain immutable latest-turn evidence so a queue wake cannot replace a
    pending post-turn extraction with an empty conversation. Each attempt passes
    current Owner metadata; an instructions or task change invalidates the last
    attempt without discarding the completed-turn evidence. *)
val install : unit -> unit
(** Install after the detached memory executor. Queue producers never wait for
    this extraction; source selection happens when the latest unit runs. *)

val run_completed_turn : base_path:string -> keeper_name:string -> unit
(** Attempt the latest remembered turn, independently of queue source coverage.
    Runtime entry records an attempt, not extraction or commit success. Input
    preparation failure or a live configuration refusal does not mark pending
    evidence as attempted. This module does not schedule a retry. *)

module For_testing : sig
  val attempt_remembered : base_path:string -> keeper_name:string ->
    trace_id:string -> meta:Keeper_meta_contract.keeper_meta -> sources_changed:bool ->
    trigger:Keeper_librarian_runtime.trigger -> bool
end
