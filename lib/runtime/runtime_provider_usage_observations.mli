(** Pure per-scope reduction of provider usage observations. *)

open Runtime_provider_usage_types

type t

val empty : t
val report_shape : source -> report_shape

val apply_report : observed_at:float -> report -> t -> t * report option
(** Return the next observations and the report accepted for the durable sink.
    [None] means no report was accepted: an empty sparse update, a report
    behind its source's complete snapshot, or a sparse update with no newer
    windows. Complete empty reports are accepted and retain their timestamp.
    Accepted windows retain input order; the first duplicate key wins. *)

val recorded_windows : t -> recorded list
(** The immutable snapshot's windows, ordered by limit id and kind. *)

val state : t -> scope_state
(** Windows are ordered by limit id and kind. Equal latest complete snapshot
    timestamps promise no precedence between reporting sources. *)
