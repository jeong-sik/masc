(** Durable admission for trusted native Addons. All file operations are blocking;
    host callers must use a system thread. Directories are private host-owned
    claim slots (installation and any shared resources), never worker inputs.
    Lease inodes are stable and must never be unlinked or replaced. *)
type t
type preparation = Unpublished | Current of t
type process = { instance_id : string; pid : int; started : string }
type status = Awaiting_exec | Live of process | Cleanup_pending of process | Settled
type error = Invalid_claim of string | Stale_claim of string | Consumed_claim
  | Busy of string | State_invalid of string | Io_failure of string
  | Resource_not_private of string
  | Identity_unavailable | Termination_refused of Owner_process_identity.error
(** [Stale_claim] and [Busy] name the claim slot, instance or pid that was
    found in place of the expected one. [Resource_not_private] names a claim
    directory or file whose kind, owner, mode or link count is not private,
    with what was found and what is required. *)
val error_to_string : error -> string
val prepare : directories:string list -> instance_id:string -> cleanup_context:Yojson.Safe.t option -> (t, error) result
(** Fence previous unstarted launchers under all claim gates. Refuse a holder,
    live predecessor or unconfirmed foreground group before granting admission.
    An instance is admitted only once in each slot. Its durable reservation is
    retained across replacements, retirement and process exit; retries require
    a fresh instance ID. A failed partial preparation may reserve some slots. *)
val reopen : directories:string list -> instance_id:string -> (t, error) result
(** Recover this exact existing claim without admitting or creating anything.
    Every slot's current intent and permanent history must exist and match. *)
val current : directories:string list -> (t, error) result
(** Reopen the single current claim shared by all existing host-selected slots.
    Missing, conflicting or damaged records are refused. No files are created. *)
val recover_preparation : directory:string -> (preparation, error) result
(** Inspect one host-selected installation slot under its stable gate. Empty
    bootstrap metadata may be completed without admitting execution. A single
    complete, unconsumed reservation without a published intent is fenced as
    retired and returned as [Current], preserving its permanent instance history. [Unpublished] has no reservation to clean up.
    Published, consumed, conflicting or damaged authority is never recreated or
    treated as a fresh slot. Gate and lease inodes are never replaced. *)
val instance_id : t -> string
val directories : t -> string list
val cleanup_context : t -> (Yojson.Safe.t option, error) result
(** Immutable host-selected cleanup descriptor retained in every original
    reservation history, including retirement and process consumption. Missing
    or inconsistent required state is refused. It grants no process authority. *)
type recorded = { instance : string; history : string; context : Yojson.Safe.t option }
type inspection_error = { refusal : string; refused_instance : string option }
(** [refusal] names the refused file; [refused_instance] is the instance the
    slot's intent or history names, when it could be read. *)
val inspect : directory:string -> (recorded option, inspection_error) result
(** Read one slot the way {!reopen}, {!current} and {!recover_preparation} read
    it, without the gate lock, fsync, creating or writing anything, so a running
    owner of the slot is never blocked or changed: the intent and owner
    receipt, and the instance histories those calls decode. With a published
    intent this is the named instance's history, and every slot file must exist;
    otherwise every history, of which at most one unconsumed may exist. [Some]
    is the instance whose cleanup descriptor its host reads next, with the file
    name of its history; [None] is a slot with no reservation. *)
val retire : t -> (unit, error) result
(** Durably refuse late execution before attempting cleanup. Idempotent for this
    exact claim; cannot retire a replacement's claim. *)
val status : t -> (status, error) result
(** [Settled] requires retirement, no lease holder, an exited original process
    and no live foreground group. Missing process-start observations never
    establish absence by themselves. *)
val request_termination : t -> (unit, error) result
(** Retire first, then request TERM through kernel-observed lease identities.
    No numeric-PID or group signaling fallback. Success is a request, not release;
    use [status] to observe cleanup. *)
val exec : instance_id:string -> directories:string list -> command:string ->
  arguments:string list -> (unit, error) result
(** Standalone launcher only: claim all slots, durably record this process,
    preserve their lease descriptors through exec and replace the process.
    Requires this process to lead its own foreground group. The trusted payload
    must preserve inherited lease descriptors until exit. Descendants that leave
    the group require their package's explicit resource ownership/cleanup.
    Never call in the MASC server. No payload starts on partial acquisition. *)
module For_testing : sig
  val prepare : sync_ancestry:(string -> unit) -> directories:string list ->
    instance_id:string -> cleanup_context:Yojson.Safe.t option -> (t, error) result
end
