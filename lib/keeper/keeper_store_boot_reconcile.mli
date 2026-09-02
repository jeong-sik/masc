(** Move aside, at boot, every durable per-keeper store this build cannot
    decode.

    A schema hard cut is finished only when the old state is gone. Without
    this step the cut surfaced per keeper, hours after the restart, on
    whichever read or write happened first: 2026-09-01 six keepers' memory
    snapshots (one for 27 hours, because only a write moved the file aside
    and that keeper did not write), 2026-09-02 five keeper metas. Running the
    decoders once here, before any keeper loop starts, makes the first boot
    the whole event: one warning per file, the bytes kept beside the store,
    and every later read sees either a decodable file or none.

    Covered stores: keeper meta ([<masc>/keepers/<name>.json]) and the
    current Memory OS snapshot ([config/keepers/<name>.memory-current.json]).
    The deploy preflight scans the same stores; this is the half of the cut
    that runs whether or not the restart went through the preflight. *)

type store =
  | Keeper_meta
  | Memory_current

val store_to_string : store -> string

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

val reconcile : now:float -> Workspace.config -> report
(** Decode every store file with this build; refused files move to
    [<path>.rejected-<now>] (a suffix is added if that name is taken). Never
    raises for a single file; a file that cannot be moved lands in [failed]. *)

val summary : report -> string
(** One line for the boot log. *)
