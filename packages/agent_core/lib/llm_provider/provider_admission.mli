(** Per-endpoint admission of concurrent provider requests.

    A provider account enforces a concurrency allowance and rejects excess
    in-flight requests (e.g. ollama.com returns HTTP 429 with body
    [{"error":"too many concurrent requests"}]). When a consumer declares
    [max_concurrent_requests] on a {!Provider_config.t}, every completion
    dispatch for that endpoint identity acquires a permit from a process-wide
    {!Slot_scheduler}, waiting while the endpoint is saturated instead of
    dispatching a request the provider will reject.

    Identity is [(kind, base_url, api-key identity)] — the unit a provider
    accounts concurrency against. Configs with different API keys are
    different accounts and are admitted independently.

    No declaration ([max_concurrent_requests = None]) means no admission:
    dispatch behavior is unchanged. AGENT_CORE never selects a limit from provider
    kind, URL, model, or process environment — the consumer declares it
    (declaration-over-probing, the same contract as [connect_timeout_s]).

    Waiting for a permit is not pre-dispatch denial: no request is refused or
    dropped. Waiters are granted in arrival order unless the endpoint also
    declares [admission_priority_run_limit]; then a request whose
    [admission_class] is [Priority] is granted ahead of [Standard] ones, up to
    that many in a row while a [Standard] request waits. Retry policy remains
    the consumer's responsibility.

    Registry decisions are pure immutable transitions. Scheduler creation,
    diagnostics, snapshots, and permit waiting are performed after leaving
    the registry's short process-wide critical section.

    @since 0.216.0 *)

(** [with_admission ~config f] runs [f] under the endpoint's concurrency
    permit when [config.max_concurrent_requests] is declared, and directly
    otherwise. A waiting request queues as [config.admission_class] (one
    shared queue when the endpoint declares no run limit); cancellation
    while waiting does not leak a permit (see {!Slot_scheduler.with_permit}).

    Two configs naming the same endpoint identity with different allowances
    ([max_concurrent_requests] or [admission_priority_run_limit]) raise
    [Invalid_argument]. Neither declaration outranks the other, so
    honouring the one that dispatched first made the effective limit a
    function of runtime order. The raise happens before the permit is taken,
    so no provider request goes out under a limit its caller did not
    declare. *)
val with_admission : config:Provider_config.t -> (unit -> 'a) -> 'a

(** {2 Queued requests}

    A request that finds every permit of its endpoint held joins the queue.
    When that wait ends, the request reports one {!wait} to the observer the
    consumer installed. A request granted a permit at once reports nothing,
    so the reports are exactly the requests that met a full endpoint. *)

(** How a wait ended. [Wait_expired] comes only from a bounded wait
    ({!with_admission_until} and its variants). A cancelled wait reports
    nothing. *)
type wait_outcome = Slot_scheduler.wait_end =
  | Wait_granted
  | Wait_expired

type wait =
  { kind : string  (** {!Provider_config.string_of_provider_kind} *)
  ; provider_id : string option  (** The config's [provider_id], as declared. *)
  ; model_id : string
  ; admission_class : Admission_class.t
  ; waited_ms : float option
      (** From joining the queue to [outcome]: on the bounded wait's clock,
          otherwise the monotonic clock. [None] when no clock could be read. *)
  ; outcome : wait_outcome
  }

(** Install ([Some]) or remove ([None]) the process-wide observer queued
    requests report to. With none installed, nothing is timed. The observer
    runs on the requesting fiber when the wait ends: a granted request
    reports before it is sent. It must not block. A raise from it fails that
    request but leaves no permit held. *)
val set_wait_observer : (wait -> unit) option -> unit

(** The allowance this process already admits for [config]'s endpoint
    identity, when [config] declares a different one: [authoritative] is the
    admitted allowance and [declared] is [config]'s. The registry keeps an
    identity's first allowance while the process runs, so {!with_admission}
    raises for such a config until the process restarts. [None] when
    [config] declares no [max_concurrent_requests], when nothing has been
    admitted for the identity yet, or when the two agree. It installs
    nothing. *)
val admitted_allowance_change
  :  config:Provider_config.t
  -> Provider_admission_state.conflict option

(** One line: the endpoint identity (URL sanitized for logs), the admitted
    allowance and the declared one. *)
val admitted_allowance_change_to_string : Provider_admission_state.conflict -> string

(** {!Slot_scheduler.permit_wait}: the caller's cell the bounded waits
    below write as a wait begins and ends. An unbounded [with_admission]
    writes nothing, so a caller that stands its own watchdog down while
    [Waiting_for_permit] never does so for a wait nothing else ends. *)
type permit_wait = Slot_scheduler.permit_wait =
  | Before_any_wait
  | Waiting_for_permit
  | Wait_settled_at of float

(** [with_admission] whose wait for a permit ends at [deadline_at] on
    [clock]. [Error `Permit_wait_expired] means the endpoint stayed saturated
    until the deadline and [f] never ran; the waiter has left its queue. A
    permit granted in the same instant the deadline passed is the caller's
    and [f] runs with it. Without a declaration there is no wait and [f]
    runs at once. [f] itself runs without this deadline, so a caller that
    bounds the whole call arms what is left of it around [f]. *)
val with_admission_until
  :  ?wait:permit_wait Atomic.t
  -> clock:_ Eio.Time.clock
  -> deadline_at:float
  -> config:Provider_config.t
  -> (unit -> 'a)
  -> ('a, [> `Permit_wait_expired ]) result

(** Why a call under {!with_admission_and_work_until} ended before its work
    did. *)
type deadline_expiry =
  | Permit_wait_expired  (** the endpoint stayed saturated until the deadline *)
  | Permit_granted_as_deadline_passed
      (** the permit arrived as the deadline passed; the work never started
          and the permit went straight back *)
  | Work_expired  (** the work ran under what the wait left and outran it *)

(** [with_admission_and_work_until ~clock ~deadline_at ~config f] is one
    deadline over the permit wait and the work under it: the wait ends at
    [deadline_at] as {!with_admission_until} does, and [f] then runs under
    what the wait left, cancelled at [deadline_at]. The caller names the
    phase each expiry is: the first two are queueing, the third is the work.
    The work's own narrower bounds still arm inside it. *)
val with_admission_and_work_until
  :  ?wait:permit_wait Atomic.t
  -> clock:_ Eio.Time.clock
  -> deadline_at:float
  -> config:Provider_config.t
  -> (unit -> 'a)
  -> ('a, deadline_expiry) result

(** Opens the shared permit-wait and work deadline [timeout_s] seconds from
    now on the explicitly supplied [clock]. *)
val with_admission_and_work_for
  :  ?wait:permit_wait Atomic.t
  -> clock:_ Eio.Time.clock
  -> timeout_s:float
  -> config:Provider_config.t
  -> (unit -> 'a)
  -> ('a, deadline_expiry) result

(** Point-in-time scheduler snapshot for [config]'s endpoint identity, or
    [None] when no dispatch has declared admission for it yet.
    Diagnostics only. *)
val snapshot_for : config:Provider_config.t -> Slot_scheduler.snapshot option
