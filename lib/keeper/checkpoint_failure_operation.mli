(** Checkpoint_failure_operation — closed sum for the [operation] label
    on [metric_keeper_checkpoint_failures].

    Replaces 7 hardcoded literals scattered across 7 emit sites in
    [keeper_context_core.ml].  Each value names a distinct
    checkpoint-related failure mode in keeper context loading/saving. *)

type t =
  | Migrate_main_history (** Legacy → current main-history schema migration. *)
  | Migrate_internal_history (** Legacy → current internal-history schema migration. *)
  | Oas_parse (** Parse failure on OAS checkpoint payload. *)
  | Oas_store (** OAS checkpoint store write failure. *)
  | Oas_io (** Generic OAS checkpoint I/O failure. *)
  | Oas_sdk (** OAS SDK-level checkpoint error. *)
  | Load_legacy (** Legacy checkpoint format load failure. *)

val to_label : t -> string
