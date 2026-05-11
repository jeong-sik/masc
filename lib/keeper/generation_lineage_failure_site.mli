(** Generation_lineage_failure_site — closed sum for [site] label on
    [metric_keeper_generation_lineage_failures] (2 sites). *)

type t =
  | Index_append
  | Manifest_save

val to_label : t -> string
