(** End-of-invocation preparation evidence. This is observation, not execution
    authority or a Task completion receipt. *)
type boundary = Returned | Raised | Cancelled
type report = private
  { report_id : string
  ; boundary : boundary
  ; turn_ref : Ids.Turn_ref.t option
  ; execution_scope : Keeper_execution_scope_id.t option
  ; timeline : Keeper_turn_preview.preparation_timeline
  }

val report_to_json : report -> Yojson.Safe.t
val report_of_json : Yojson.Safe.t -> (report, string) result
(** Strict wire inverse, including scope/parent/clock validation. Report IDs
    distinguish observation snapshots, including continuations of the same
    execution; they never create or resume an execution. *)

val with_report :
  preview:Keeper_turn_preview.writer -> on_report:(report -> unit) ->
  (unit -> 'a) -> 'a
(** Snapshot the retained original writer once after the invocation returns,
    raises or is cancelled. Unfinished scopes remain active, not fabricated as
    completed. Ordinary sink failures are logged; reserved exceptions propagate.
    Exceptional cleanup is cancellation-protected in Eio. The snapshot reads
    one immutable value under the mutex; report construction, timeline traversal
    and publication run outside it. *)

val with_turn :
  config:Workspace.config -> keeper_name:string -> preview:Keeper_turn_preview.writer ->
  (unit -> 'a) -> 'a
(** Use the existing runtime manifest store. A writer with an original turn
    reference and at least one scope appends one Preparation_observed row.
    No per-scope writes, provider calls, retries or new store are introduced.
    Missing original identity is logged, never inferred from Keeper name/time.
    Manifest retention and append failures follow the existing store contract.
    Publication overhead is outside recorded spans and remains unmeasured. *)
