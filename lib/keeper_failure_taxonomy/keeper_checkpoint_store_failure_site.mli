(** Keeper_checkpoint_store_failure_site — closed sum for [site] label on
    [metric_keeper_checkpoint_failures] when emitted from the
    checkpoint-store layer. *)

type t =
  | Agent_core_cleanup (** AGENT_CORE checkpoint cleanup pass failed. *)
  | Agent_core_save (** AGENT_CORE checkpoint primary save failed. *)
  | Agent_core_delete (** AGENT_CORE checkpoint delete failed. *)
  | Agent_core_archive (** AGENT_CORE checkpoint history archive failed. *)

val to_label : t -> string
