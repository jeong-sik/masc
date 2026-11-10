(** Exact reaction-file authority. The caller owns persistence; filesystem work
    runs outside the Board state mutex. New toggles retain supplied canonical
    parent admission; deletion/flush rewrites keep their own-source contract. *)
open Board_types

type row = reaction

type read =
  | Complete of {
      observation : reactions_source_observation;
      rows : row list;
      diagnostics : reactions_source_diagnostic list;
    }
  | Partial of {
      observation : reactions_source_observation;
      rows : row list;
      errors : reactions_row_error list;
      diagnostics : reactions_source_diagnostic list;
    }
  | Unavailable of {
      failure : reactions_source_failure;
      diagnostics : reactions_source_diagnostic list;
    }

val read : store -> read
val publish_read : store -> read -> unit
val fail_read : store -> read -> exn -> Printexc.raw_backtrace -> read
val finish_read : read -> (int, board_error) result
(** The caller replaces the reaction table on a complete load.
    Valid reactions remain stored when their targets are absent. Partial rows are
    display data and grant no mutation authority. A reload cannot settle an
    unknown write or interrupted publication; those require a fresh store. *)

type publication
type write =
  | Written of {
      publication : publication;
      diagnostics : reactions_source_diagnostic list;
    }
  | Not_written of {
      failure : reactions_source_failure;
      diagnostics : reactions_source_diagnostic list;
    }
  | Unknown of {
      failure : reactions_source_failure;
      diagnostics : reactions_source_diagnostic list;
    }

val rewrite : store -> string -> write
(** Rewrite compares the exact loaded bytes/cursor under the existing
    stable file lock. Rewrite bytes come from a model capture in this same
    persistence interval. The write receipt precedes model publication; an
    after-write reread cannot replace it. *)

val rewrite_admitted : store -> admission:Board_target_admission.t -> string -> write
(** A new toggle retains canonical parent dependencies through the leaf write.
    Ordinary deletion/flush rewrites retain their own-source contract. *)

val acknowledge_publication : store -> publication -> (unit, board_error) result
(** Acknowledge the exact store-owned receipt after the model callback returns
    success. Until then normal reaction operations refuse. *)
val reject_publication : store -> publication -> board_error -> unit
(** Retain a normally returned model error beside the known file receipt.
    This does not acknowledge the write or make it safe to replay. *)
val fail_publication : store -> publication -> exn -> Printexc.raw_backtrace -> 'a
(** Retain an exceptional projection failure before propagating its original
    cause or a reserved cleanup cause. *)
val finish_write : write -> ('a, board_error) result -> ('a, board_error) result
(** Finish after the model callback and its publication decision. Preserve the
    original reserved cleanup cause through the shared Board carrier. *)
val require_readable : store -> (unit, board_error) result
