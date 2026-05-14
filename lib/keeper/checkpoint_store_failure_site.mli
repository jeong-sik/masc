(** Checkpoint_store_failure_site — closed sum for [site] label on
    [metric_keeper_checkpoint_failures] when emitted from the
    checkpoint-store layer (6 sites in keeper_checkpoint_store.ml).

    NOTE: the underlying metric is shared with
    {!Checkpoint_failure_operation} but emits use the legacy [site]
    label key (kept verbatim to preserve Grafana dashboard queries
    that select on `site=...`).  A follow-up RFC could harmonise the
    label key to a single [operation] across both call sites once
    dashboards are migrated. *)

type t =
  | Save (** Legacy-format checkpoint save failure. *)
  | Oas_cleanup (** OAS checkpoint cleanup pass failed. *)
  | Oas_save (** OAS checkpoint primary save failed. *)
  | Oas_delete (** OAS checkpoint delete failed. *)
  | Oas_archive_fallback (** Archive-tier fallback save failed. *)
  | Oas_archive_primary (** Archive-tier primary save failed. *)

val to_label : t -> string
