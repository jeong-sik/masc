(** Noncreating read observations, separate from the live posts source and its
    exact stable cursor. No store is allocated or admitted by this reader. *)
open Board_types

type posts_inspection_framing =
  | Complete_rows
  | Torn_tail of { rows_end : int; end_offset : int }

type posts_inspection_observation =
  | Observed_missing
  | Observed_present of {
      accepted_rows : int;
      errors : posts_row_error list;
      framing : posts_inspection_framing;
    }

type posts_inspection =
  | Inspected of {
      observation : posts_inspection_observation;
      settlement_diagnostic : Fs_compat.private_jsonl_operation_failure option;
    }
  | Inspection_failed of {
      error : Fs_compat.Private_jsonl_unique_fold.error;
      settlement_diagnostic : Fs_compat.private_jsonl_operation_failure option;
    }

val read : workspace_masc_dir:string -> posts_inspection
val read_with_io_for_testing :
  workspace_masc_dir:string ->
  io:Fs_compat.private_jsonl_transaction_io_for_testing -> posts_inspection
val finish : posts_inspection -> unit
(** Reraise any original reserved primary/settlement exception with its
    backtrace after the enclosing shell has recorded the observation. No I/O. *)
