(** Exact vote-file authority. The caller owns persistence; filesystem work
    runs outside the Board state mutex. Casts retain supplied canonical parent
    admission; deletion/flush rewrites keep their own-source contract. *)
open Board_types

type row = Board_vote_key.t * vote_direction * float

type read =
  | Complete of {
      observation : votes_source_observation;
      rows : row list;
      diagnostics : votes_source_diagnostic list;
    }
  | Partial of {
      observation : votes_source_observation;
      rows : row list;
      errors : votes_row_error list;
      diagnostics : votes_source_diagnostic list;
    }
  | Unavailable of {
      failure : votes_source_failure;
      diagnostics : votes_source_diagnostic list;
    }

val read : store -> read
val publish_read : store -> read -> unit
val fail_read : store -> read -> exn -> Printexc.raw_backtrace -> read
val finish_read : read -> (int, board_error) result
(** The caller replaces the ledger on a complete load and recalculates counts.
    Valid votes remain stored when their targets are absent. Partial rows are
    display data and grant no mutation authority. A reload cannot settle an
    unknown write or interrupted publication; those require a fresh store. *)

type publication
type write =
  | Written of {
      publication : publication;
      diagnostics : votes_source_diagnostic list;
    }
  | Not_written of {
      failure : votes_source_failure;
      diagnostics : votes_source_diagnostic list;
    }
  | Unknown of {
      failure : votes_source_failure;
      diagnostics : votes_source_diagnostic list;
    }

val append : store -> admission:Board_target_admission.t -> row -> write
val rewrite : store -> string -> write
(** Append and rewrite compare the exact loaded bytes/cursor under the existing
    stable file lock. Rewrite bytes come from a model capture in this same
    persistence interval. The write receipt precedes model publication; an
    after-write reread cannot replace it. *)

type admission_check
val check_admission : store -> admission:Board_target_admission.t -> admission_check
val finish_check : admission_check -> ('a, board_error) result -> ('a, board_error) result
(** A duplicate cast is still checked against exact parent and vote snapshots.
    This is a read-only guard, not a fabricated write/publication receipt.
    Finish preserves the caller's no-effect result and reserved cleanup cause. *)

val acknowledge_publication : store -> publication -> (unit, board_error) result
(** Acknowledge the exact store-owned receipt after the model callback returns
    success. Until then normal vote operations refuse. *)
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
val observe_guard_refusal :
  store -> votes_source_observation -> Fs_compat.private_jsonl_guard_failure -> unit
(** Outside the filesystem worker, refuse only the exact current observation
    contradicted by its own guard. Contention and pending effects are preserved. *)
