(** Endpoint-owned asynchronous lifetime for one already admitted launch.
    This trusted core is not a wire handler or peer authenticator. The caller
    must supply the independent endpoint Switch, resolved execution policy and
    the opaque original permit obtained only after durable host confirmation.
    No request, Keeper turn or transport Switch may own this lifetime.
    Scheduling and cancellation run in that endpoint Switch's Eio domain;
    result observers may await its thread-safe futures from other domains. *)
module P = Endpoint_job_protocol
module R = Endpoint_job_registry
module L = Endpoint_job_launch
module S = Endpoint_job_supervisor
module D = Endpoint_job_result
type t
type error =
  | Registry_error of R.error
  | Supervisor_error of S.error
  | Result_error of D.error
  | Owner_stopped
  | Job_failed of exn
val error_to_string : error -> string
val start_effect_workspace :
  sw:Eio.Switch.t -> fs:Eio.Fs.dir_ty Eio.Path.t ->
  cgroup_parent_path:string -> execution:L.execution -> R.launch_intent -> t
(** Schedule the original once and return before startup I/O. Each job has its
    own child Switch. A failing job settles its own futures and does not fail
    the endpoint or another job. A returned handle is a reservation, not
    admission, native startup, exec or result readiness. Unsupported execution
    modes/domains retain the supervisor's actual refusal.

    Native startup, capture, terminal publication and cancellation continue
    independently of observers. A pre-child cancelled permit can publish a
    complete no-child result only through the original opaque retirement proof.
    Other failures never infer absence or replay permission. Original resources
    remain owned until endpoint teardown; digest-bound host consumption/Release
    and cleanup are separate obligations. No files are removed here. *)
val original : t -> P.original
val await_result : t -> (P.Sha256.t,error) result
(** Event-driven historical publication digest, never a fresh integrity check.
    Cancelling this observer leaves the job and its publication alive. Endpoint
    shutdown resolves unfinished futures with Owner_stopped even if a reserved
    worker never entered. No deadline or status polling is introduced. *)
val load_result : sw:Eio.Switch.t -> t -> (D.t,error) result
(** Await the original digest, then fully open/verify that exact result using
    original captured storage and the known digest. Reader resources belong to
    this observer's Switch, independently of the publisher. *)
val cancel : t -> (R.record,error) result
(** Schedule original-source durable cancellation in the endpoint lifetime,
    then observe its result. Cancelling this observer does not abort an entered
    cancellation request. Concurrent callers share the in-flight request; a
    later explicit request performs a fresh original-source validation.

    Busy startup waits for this job's actual startup future before reconciling
    cancellation; it never polls a lock or blocks another job. Missing authority
    sends no signal. Only the original native supervisor may kill its tree.
    A successful return proves durable intent and, if present, an original
    kill request; it does not prove physical settlement or complete output. *)
