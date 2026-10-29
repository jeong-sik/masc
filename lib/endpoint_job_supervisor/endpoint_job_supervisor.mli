(** Per-job endpoint supervision with owned stdio.
    Every child descriptor and capture source is created here for the same
    original launch. Stdin comes from that immutable committed specification.
    An authenticated daemon/host adapter, restart receipt reconciliation and
    durable host consumption/Release remain separate obligations. *)
module P = Endpoint_job_protocol
module R = Endpoint_job_registry
module L = Endpoint_job_launch
module O = Endpoint_job_output
module G = Endpoint_process_gate
type t
type pipe_end = Child_stdin | Child_stdout | Child_stderr | Input_writer
type error =
  | Registry_error of R.error
  | Launch_error of L.error
  | Output_error of { stream : P.stream; cause : O.error }
  | Pipe_unavailable
  | Pipe_cleanup_failed of pipe_end list
  | Registry_cleanup_failed of File_lock_eio.durable_lock_error
  | Interrupted
  | Supervisor_failed
  | Publication_failed of Fs_compat.capability_write_error
  | Recovery_failed of string
  | Receipt_storage_unavailable
  | Result_encoding_failed of Endpoint_job_result.error
val error_to_string : error -> string
type input_delivery =
  | Written of int64
  | Write_failed of { confirmed_prefix : int64 }
(** Bytes accepted by the pipe, never proof that the program consumed them.
    Write_failed preserves the known prefix without replaying any input. *)
type settled =
  { physical_exit : G.exit_observation
  ; stdin : input_delivery
  ; stdout : O.seal
  ; stderr : O.seal
  }
(** Raw original physical observation, actual recursive emptiness and both
    durably sealed streams. A bootstrap exit remains bootstrap evidence;
    this value alone never creates a protocol terminal result or source ACK. *)
type launch_outcome =
  | Not_performed of { error : error; pipe_cleanup_errors : pipe_end list }
  | Performed of
      { value : (t,error) result
      ; registry_release_error : File_lock_eio.durable_lock_error option
      ; pipe_cleanup_errors : pipe_end list
      }
val launch_effect_workspace :
  sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t ->
  cgroup_parent_path:string -> execution:L.execution -> R.launch_intent -> launch_outcome
(** Run inside the independent endpoint job's Switch, never a request/turn
    lifetime. Allocation before callback entry may fail; Not_performed never
    grants a new admission/launch permit or proves a prior attempt absent.
    Original resources stay Switch-owned if an exception/cancellation escapes.

    Close parent copies after the actual spawn, stream only original stdin,
    and capture that same spawn's stdout/stderr. Typed post-child startup or
    cleanup failure retains [Ok owner] with unavailable settlement and exact
    cancellation authority. Background fibers are daemons so owner teardown
    does not wait on a child before releasing its kernel resources. *)
val original : t -> P.original
val availability : t -> (unit,error) result
(** Current known startup/capture failure; Ok does not certify completion. *)
val await_settled : t -> (settled,error) result
(** Observer cancellation leaves the job and collectors running. Capture or
    stdin-close failure becomes observable without waiting for a child that
    may now be blocked on that failed stream. An error is not termination;
    the owner can still durably cancel and observe physical quiescence. *)
type observation = private { settled : settled; status : P.response }
val await_observation : t -> (observation,error) result
(** Join this actual supervisor and refresh its original record before projecting
    Termination_observed or a proven Not_started with both actual seals.
    The raw gate and input-delivery facts remain in [settled]. The result stays
    Result_pending: no immutable terminal receipt, exec proof, host ACK or
    Release is fabricated. Original authority or capture failure remains an
    error even when the physical child has exited. Never infer replay permission. *)
type result_receipt = private { sha256 : P.Sha256.t; status : P.response; content : string }
val result_leaf : string
val await_result : t -> (result_receipt,error) result
(** The job-owned supervisor automatically publishes once after original
    physical/tree settlement, input delivery and both seals. It freezes the
    original admission/known launch, source revision/cancellation and raw gate
    observations in a private immutable receipt using canonical durable
    exclusive publication. The shared receipt codec includes a domain-separated
    payload checksum for restart corruption detection, not authentication.
    Only confirmed publication produces Result_ready
    with the digest of these exact receipt bytes. Both original streams are
    fully reopened/hashed outside metadata/registry locks and compared with the
    actual cached seals. Their retained attachments and the exact private
    receipt bytes/attachment are revalidated after publication before readiness;
    the exact readback file and its actual parent are fsynced together.
    These are bounded observations, not protection against later mutation.
    The result remains a
    physical or proven non-start observation, never payload or Task/Goal success.

    A held startup automatically commits cancellation against its original
    source before retiring/killing its original tree. A Busy cancellation never
    entered the lease body, so it is awaited like a contended read; any other
    cancellation error is returned unchanged. Only actual quiescence,
    input settlement and both complete seals can produce a terminal receipt.
    Native rejection or a settled pre-activation gate with durable cancellation
    and empty actual output may prove Not_started; raw bootstrap status remains
    in the receipt. The original startup error stays visible through
    [availability]/[await_settled]. Missing authority or output never becomes
    readiness, and no launch is replayed.

    Transient contention on the original registry read lock leaves the
    job-owned publisher pending; it retries only that read, including after
    exclusive receipt publication. Observer cancellation leaves publication
    and the original job alive.
    Publication/capture failure or owner teardown settles this observer with an
    error; it never grants a new launch or overwrites an existing receipt.
    Repeated observers share the same original immutable receipt. Restart
    readback/reconciliation and durable host consumption/Release remain separate
    obligations; this API grants neither cleanup nor recovered kernel authority. *)
val read_output : t -> stream:P.stream -> offset:int64 -> max_bytes:int -> (O.chunk,error) result
val cancel : t -> (R.record,error) result
val await_quiescent : t -> (G.exit_observation,error) result
(** Original-owner durable cancellation and raw physical/tree settlement remain
    available even when output initialization or capture is unavailable. *)
module For_testing : sig
  type result_read =
    | Observe_original | Open_storage | Reopen_stdout | Reopen_stderr
    | Validate_stdout | Validate_stderr | Refresh_after_publication
    | Cancel_held_original
  val launch_effect_workspace :
    ?before_result_read:(result_read -> unit) ->
    ?on_result_read_busy:(result_read -> unit) ->
    after_spawn:(L.t -> unit) -> before_result_publish:(unit -> unit) ->
    after_result_publish:(unit -> unit) ->
    sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t ->
    cgroup_parent_path:string -> execution:L.execution -> R.launch_intent -> launch_outcome
  (** [after_spawn]: original owner exists and parent child-ends are closed;
      input/capture workers have not started. [before_result_publish]: actual
      physical/tree/input/output settlement exists, before result publication
      and outside the owner metadata lock. [after_result_publish] runs after the
      actual durable exclusive commit, before attachment readback/readiness.
      Both publication hooks run outside the owner metadata lock.
      [before_result_read] runs before a job-owned read or validation attempt;
      [on_result_read_busy] runs after that read observed real contention. *)
end
