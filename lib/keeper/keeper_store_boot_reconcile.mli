(** Settle, at boot, every durable per-keeper store this build cannot decode:
    refuse to start, or move the file aside once.

    A schema hard cut is finished only when the old state is gone. Without a
    boot step the cut surfaced per keeper, hours after the restart, on
    whichever read or write happened first: 2026-09-01 six keepers' memory
    snapshots (one for 27 hours, because only a write moved the file aside
    and that keeper did not write), 2026-09-02 five keeper metas. Running the
    decoders once here, before any keeper loop starts, makes the first boot
    the whole event.

    Moving a store aside changes what its keeper remembers, so the operator
    decides (RFC-0420). [examine] reads and renames nothing; [admit] says
    whether boot may go on; [quarantine] moves aside what [examine] found,
    only after the operator accepted it with [--accept-store-quarantine]. On
    2026-09-05 a build started from a shell, outside the deploy preflight,
    moved 15 memory snapshots aside and the keepers started empty; the
    preflight would have refused those files.

    Covered stores: keeper meta ([<masc>/keepers/<name>.json]) and the
    current Memory OS snapshot ([config/keepers/<name>.memory-current.json]).
    The deploy preflight scans the same stores with the same decoders. *)

type store =
  | Keeper_meta
  | Memory_current

val store_to_string : store -> string

type undecodable =
  { store : store
  ; keeper : string
  ; path : string
  ; rejection : string
  }

type examination =
  { readable : int
  ; undecodable : undecodable list
  }

val examine : Workspace.config -> examination
(** Decode every store file with this build. Reads only: no file is renamed,
    so calling it twice gives the same answer. A snapshot the process cannot
    read at all counts as undecodable; its [rejection] says so. *)

val admit
  :  accept_quarantine:bool
  -> examination
  -> (examination, undecodable list) result
(** Whether boot may go on. [Ok] when nothing is undecodable, or the operator
    accepted the quarantine. [Error] names every store boot refuses to move;
    the files stay where they are. *)

val refusal_to_string : undecodable list -> string
(** The boot refusal: one line per store (kind, keeper, path, rejection) and
    the two ways forward. *)

type quarantined =
  { store : store
  ; keeper : string
  ; path : string
  ; rejected_path : string
  ; rejection : string
  }

type failure =
  { store : store
  ; keeper : string
  ; path : string
  ; error : string
  }

type report =
  { examined : int
  ; readable : int
  ; quarantined : quarantined list
  ; failed : failure list
      (** Refused by the decoder but not moved aside; the file stays and the
          lazy paths (writer quarantine, meta re-materialisation) meet it. *)
  }

val quarantine : now:float -> Workspace.config -> examination -> report
(** Move every [undecodable] store to [<path>.rejected-<now>] (a suffix is
    added if that name is taken). Never raises for a single file; a file that
    cannot be moved lands in [failed]. With nothing undecodable the report
    only counts. *)

val summary : report -> string
(** One line for the boot log. *)
