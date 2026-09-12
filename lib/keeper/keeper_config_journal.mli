(* Keeper_config_journal — durable crash journal for the composite
   keeper config write (keeper manifest + runtime.toml assignment).

   The composite write already carries a compare-and-swap revision check
   and an in-process compensating rollback
   (Keeper_turn_up_config_persistence.persist_with_publication_using).
   What neither can cover is the crash window between the two atomic
   renames: the process dies after the manifest replacement but before
   the runtime.toml commit, and the next boot finds one file at the new
   value and the other at the old one.

   The journal closes that window with a before-image pair. The writer
   stages both files' original bytes under both locks BEFORE touching
   either file, then commits each file as today. Every phase transition
   overwrites the journal atomically (temp file + rename + parent
   fsync). If a crash leaves the journal on disk, startup recovery
   rolls both files back to their before-images — the write converges
   to the pre-request state, one of the two states the request ever
   intended (#31180). Once both files are committed the journal is
   removed: from that instant the normal state IS the converged state.

   Rollback (not roll-forward) is the deliberate choice: the after-image
   of the manifest is not always available to the journal (edit paths
   compute edits against live bytes), while the before-image is exactly
   what the existing compensating rollback would have restored. The
   journal therefore makes the existing rollback durable across
   crashes instead of inventing a second convergence authority. *)

type phase =
  | Prepared
  | Manifest_committed
  | Rolling_back

type manifest_before_image =
  | Manifest_absent
  | Manifest_bytes of string

(** [Some Runtime_absent] pins that runtime.toml did not exist before
    the interrupted write; [None] means the write never recorded a
    runtime before-image. Presence-vs-absence used to collapse into the
    same [None], so a write that created runtime.toml could not roll it
    back. *)
type runtime_before_image =
  | Runtime_absent
  | Runtime_bytes of string

type record =
  { tx_id : string
  ; keeper_name : string
  ; manifest_before : manifest_before_image
  ; runtime_before : runtime_before_image option
  ; manifest_path : string
  ; runtime_path : string option
  ; started_at_unix : float
  ; phase : phase
  }

type recovery_outcome =
  | No_journal
  | Recovered_rolled_back of
      { manifest_restored : bool
      ; runtime_restored : bool
      ; notes : string list
      }
  | Journal_corrupt of string
  | Recovery_failed of
      { detail : string
      ; notes : string list
      }

type report =
  { outcome : recovery_outcome
  ; journal_path : string
  ; record : record option
  }

val phase_of_string : string -> (phase, string) result
val phase_to_string : phase -> string

val record_to_yojson : record -> Yojson.Safe.t
val record_of_yojson : Yojson.Safe.t -> (record, string) result

(** Serialization is a documented compatibility surface: the journal is
    read back by [recover_interrupted] after crashes, including across
    version upgrades. Fields are additive; a failed decode is reported
    as [Journal_corrupt] with the journal preserved on disk — never
    silently discarded. [phase] is deliberately NOT serialized as
    authoritative state (see the module note): [prepared] and
    [manifest_committed] read identically to recovery, [rolling_back]
    only marks that restores were already attempted. *)

(** Path of the journal file for a workspace config root. *)
val journal_path_for_base_path : base_path:string -> string

(** Atomically write [record] as the current journal (strict staged
    atomic replace: temp + rename + parent fsync). Must be called while
    holding the manifest lock. *)
val stage : base_path:string -> record -> (unit, string) result

(** Load and decode the current journal, if any. [Ok None] when no
    journal file exists. *)
val load : journal_path:string -> (record option, string) result

(** Remove the journal file if present. Returns an error when deletion fails. *)
val clear : journal_path:string -> (unit, string) result

(** Roll both files back to the record's before-images. Best effort per
    file: each restore's result is reported independently so a partial
    crash of the recovery itself remains diagnosable. Returns the notes
    for whatever could not be restored. *)
type rollback_result =
  { manifest_restored : bool
  ; runtime_restored : bool
  }

val apply_rollback :
     record
  -> manifest_restore:
       (string -> manifest_before_image -> (unit, string) result)
  -> runtime_restore:
       (string -> runtime_before_image -> (unit, string) result)
  -> (rollback_result, string * string list) result

(** Startup recovery: if a journal exists for the workspace, converge
    the composite write to its pre-request state and clear the journal.
    Restore functions follow the existing compensating-rollback
    implementations. Idempotent: an already-converged file is an
    unchanged write. Never raises; failures come back in the report. *)
val recover_interrupted :
     base_path:string
  -> manifest_restore:
       (string -> manifest_before_image -> (unit, string) result)
  -> runtime_restore:
       (string -> runtime_before_image -> (unit, string) result)
  -> report
