(** Keeper_checkpoint_failure_operation — closed sum for the [operation] label
    on [metric_keeper_checkpoint_failures].

    Each value names a distinct
    checkpoint-related failure mode in keeper context loading/saving. *)

type t =
  | Agent_core_parse (** Parse failure on AGENT_CORE checkpoint payload. *)
  | Agent_core_store (** AGENT_CORE checkpoint store write failure. *)
  | Agent_core_io (** Generic AGENT_CORE checkpoint I/O failure. *)
  | Agent_core_failure (** Agent-core checkpoint error. *)
  | Agent_core_sanitize_save (** Persisting a sanitized AGENT_CORE checkpoint failed. *)
  | Create_initial_save (** Initial checkpoint save during keeper boot create flow. *)

val to_label : t -> string
