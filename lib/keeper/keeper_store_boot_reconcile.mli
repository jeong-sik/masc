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

    Which stores boot reads, and what it does when one does not decode, is
    {!Keeper_durable_store.reader}. The deploy preflight reads the same list,
    so a store cannot be known to one and missing from the other. Keeper
    meta ([<masc>/keepers/<name>.json]) and the current Memory OS snapshot
    ([config/keepers/<name>.memory-current.json]) are [Refuse_boot]: without
    them a keeper starts as another keeper or with empty memory, and
    overwrites what it lost. The official-client session binding
    ([<masc>/keepers/<name>/official-client-runtime/session.json]) is
    [Refuse_boot] too: while it does not decode, every turn of its keeper
    fails (2026-09-26, #38986); moved aside under its store lock, the
    keeper's next claim starts a new vendor session. The event queue
    ([<masc>/keepers/<name>/event-queue-v*.json] and its transition WAL) is
    [Refuse_boot] as well: while it does not decode, the keeper selects no
    stimulus; the snapshot and the WAL move aside together, under the queue
    owner lock. The goal store ([goals.json]) is
    [Degrade_typed]: every goal writer refuses an unreadable store and no
    reader turns it into an empty goal list, so keepers run on tasks, board
    and schedules and nothing overwrites the file. [examine] reads it and
    logs one INFO line when it is unreadable. Boot does not read a
    [Preflight_only] store. {!undecodable} holds only a
    {!Keeper_durable_store.Refusing.t}, so the goal store is never refused,
    never moved aside, and [--accept-store-quarantine] does not reach it. *)

val store_to_string : Keeper_durable_store.Refusing.t -> string

type undecodable =
  { store : Keeper_durable_store.Refusing.t
  ; keeper : string
  ; path : string
  ; rejection : string
  }

type examination =
  { readable : int
  ; undecodable : undecodable list
  }

val examine : Workspace.config -> examination
(** Decode every file of each [Refuse_boot] store with this build, and read
    the [Degrade_typed] store once. [Preflight_only] stores are not read.
    No file is created, renamed or written, so calling it twice gives the
    same answer. A snapshot the
    process cannot read at all counts as undecodable; its [rejection] says
    so. [readable] and [undecodable] count the per-keeper files only.

    The goal store is read through [Goal_store.load_source]. When it is
    [Unavailable], [examine] logs one INFO line
    ([Goal_store.unavailable_to_string]); otherwise it logs nothing about
    it. Every call logs that line again, so boot calls [examine] once and
    the line count equals the boot count (RFC-0444 criterion 3). *)

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
  { store : Keeper_durable_store.Refusing.t
  ; keeper : string
  ; path : string
  ; rejected_paths : string list
      (** Where each moved file went. One path for every store but the
          event queue, whose snapshot and WAL move together. *)
  ; rejection : string
  }

type failure =
  { store : Keeper_durable_store.Refusing.t
  ; keeper : string
  ; path : string
  ; error : string
  }

type report =
  { examined : int
  ; readable : int
  ; quarantined : quarantined list
  ; failed : failure list
      (** Refused by the decoder but not moved aside; each is logged at
          ERROR with its path and error. The file stays. Keeper meta and
          memory current meet it again on their lazy paths (meta
          re-materialisation, writer quarantine); an official-client session
          binding and an event queue have none, so their keeper takes no
          turn until the files move. *)
  }

val quarantine : now:float -> Workspace.config -> examination -> report
(** Move every [undecodable] store to [<path>.rejected-<now>] (a suffix is
    added if that name is taken). Never raises for a single file; a file that
    cannot be moved lands in [failed]. With nothing undecodable the report
    only counts. *)

val summary : report -> string
(** One line for the boot log. *)
