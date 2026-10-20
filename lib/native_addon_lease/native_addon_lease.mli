(** Durable admission for trusted native Addons. All file operations are blocking;
    host callers must use a system thread. Directories are private host-owned
    claim slots (installation and any shared resources), never worker inputs.
    Lease inodes are stable and must never be unlinked or replaced. *)
type t
type process = { instance_id : string; pid : int; started : string }
type status = Awaiting_exec | Live of process | Cleanup_pending of process | Settled
type error = Invalid_claim of string | Stale_claim | Consumed_claim
  | Busy of string | State_invalid of string | Io_failure of string
  | Identity_unavailable | Termination_refused of Owner_process_identity.error
val error_to_string : error -> string
val prepare : directories:string list -> instance_id:string -> (t, error) result
(** Fence previous unstarted launchers under all claim gates. Refuse a holder,
    live predecessor or unconfirmed foreground group before granting admission.
    An instance is admitted only once in each slot. Its durable reservation is
    retained across replacements, retirement and process exit; retries require
    a fresh instance ID. A failed partial preparation may reserve some slots. *)
val instance_id : t -> string
val directories : t -> string list
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
