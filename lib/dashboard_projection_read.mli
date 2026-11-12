(** Metadata read policy shared below the Dashboard and operator libraries. *)

type t = Reuse | Current
(** [Reuse] permits the existing stale-while-revalidate caches. [Current]
    observes authoritative metadata for a source-triggered computation, so a
    healthy worker cannot settle on a previous generation's cached answer. *)

type completeness = Complete | Partial of string
(** [Partial detail] retains the actual rows and their read failure. It must
    publish as an error observation and keep failure-only retry debt. [detail]
    is diagnostic data; consumers branch on the constructor, never its text. *)

type observation = {
  json : Yojson.Safe.t;
  next_deadline_unix : float option;
  completeness : completeness;
}

val combine_completeness : completeness -> completeness -> completeness
val keeper_completeness :
  listing:Keeper_snapshot_unread.listing -> unread:Keeper_snapshot_unread.t list -> completeness
(** Classify the original typed roster/row reads without parsing rendered JSON
    or treating unread Keepers as an empty successful fleet. *)

val json_with_read_diagnostics : observation -> Yojson.Safe.t
(** Preserve the body and merge two fields into [projection_diagnostics]:
    [read_completeness] is exactly ["complete"] or ["partial"], and
    [read_error] is respectively [null] or the actual diagnostic string.
    These values come from the producer's typed read outcome. Complete reads
    explicitly clear the previous read error. Private actor/query HTTP uses
    this without claiming default canonical publication authority. *)

exception Incomplete_read of string
(** After publishing partial rows, a source worker may pass this actual read
    failure to its existing retry mechanism. It must not discard the rows. *)
