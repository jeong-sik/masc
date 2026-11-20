(** The working-context pass: one Librarian call that organizes a Keeper's
    pending sources into its working context. It reads no Memory and writes
    none. *)

val needed
  :  keepers_dir:string
  -> keeper_name:string
  -> Keeper_librarian_context.input
  -> bool
(** Whether the pass calls the model for this capture. *)

val remember
  :  keepers_dir:string
  -> keeper_name:string
  -> Keeper_librarian_context.input
  -> Keeper_librarian_context.version
  -> unit
(** Record that a pass shown this capture wrote that version. *)

val input
  :  config:Workspace.config
  -> keeper_id:Keeper_identity.Keeper_id.t
  -> meta:Keeper_meta_contract.keeper_meta
  -> working_context:Keeper_librarian_context.input
  -> Keeper_librarian.input
(** The input the pass hands the Librarian. Reads the Goal store and
    goal-task links for [meta.current_task_id] through the IO pool. *)

exception Blank_keeper_name
(** A signal named no Keeper. The unit that meets it raises, and the memory
    lane logs and counts it as a failed unit. *)

val run
  :  base_path:string
  -> keeper_name:string
  -> keeper_id:Keeper_identity.Keeper_id.t
  -> unit
(** Captures the Keeper's pending sources and runs one pass when {!needed}
    says so. Does nothing when the Librarian is off, or when the Keeper has
    no owner, no meta, or is stopping. *)

val install : unit -> unit
(** Install after the detached memory executor. From then on each queue
    signal submits one pass to that Keeper's memory lane; the lane keeps the
    latest. The producer of a signal never waits for the pass. *)
