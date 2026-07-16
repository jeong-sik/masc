(** Keeper_checkpoint_store_failure_site — closed sum for [site] label on
    [metric_keeper_checkpoint_failures] when emitted from the
    checkpoint-store layer. *)

type t =
  | Oas_cleanup (** OAS checkpoint cleanup pass failed. *)
  | Oas_save (** OAS checkpoint primary save failed. *)
  | Oas_delete (** OAS checkpoint delete failed. *)
  | Oas_archive (** OAS checkpoint history archive failed. *)
  | Oas_watermark_sidecar (** OAS checkpoint watermark sidecar write failed (best-effort; canonical write already succeeded). *)

val to_label : t -> string
