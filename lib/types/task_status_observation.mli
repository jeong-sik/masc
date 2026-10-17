(** Strict status metadata for read-only observations. This codec does not
    change Task transitions or grant mutation authority. Free-text completion
    notes and cancellation reasons are omitted. *)
val to_yojson : Masc_domain.task_status -> Yojson.Safe.t

val of_yojson : Yojson.Safe.t -> (Masc_domain.task_status, string) result
(** Requires one copy of every metadata field for the canonical status, a
    nonblank owner/verification identity and RFC 3339 lifecycle clocks. *)
