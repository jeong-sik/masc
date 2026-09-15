(** Per-endpoint admission of concurrent provider requests.

    A provider account enforces a concurrency allowance and rejects excess
    in-flight requests (e.g. ollama.com returns HTTP 429 with body
    [{"error":"too many concurrent requests"}]). When a consumer declares
    [max_concurrent_requests] on a {!Provider_config.t}, every completion
    dispatch for that endpoint identity acquires a permit from a process-wide
    fair FIFO {!Slot_scheduler}, waiting while the endpoint is saturated
    instead of dispatching a request the provider will reject.

    Identity is [(kind, base_url, api-key identity)] — the unit a provider
    accounts concurrency against. Configs with different API keys are
    different accounts and are admitted independently.

    No declaration ([max_concurrent_requests = None]) means no admission:
    dispatch behavior is unchanged. AGENT_CORE never selects a limit from provider
    kind, URL, model, or process environment — the consumer declares it
    (declaration-over-probing, the same contract as [connect_timeout_s]).

    Waiting for a permit is not pre-dispatch denial: no request is refused,
    reordered across the FIFO, or dropped. Retry policy remains the
    consumer's responsibility.

    Registry decisions are pure immutable transitions. Scheduler creation,
    diagnostics, snapshots, and permit waiting are performed after leaving
    the registry's short process-wide critical section.

    @since 0.216.0 *)

(** [with_admission ~config f] runs [f] under the endpoint's concurrency
    permit when [config.max_concurrent_requests] is declared, and directly
    otherwise. Waiting joins a FIFO; cancellation while waiting does not
    leak a permit (see {!Slot_scheduler.with_permit}).

    Two configs naming the same endpoint identity with different allowances
    raise [Invalid_argument]. Neither declaration outranks the other, so
    honouring the one that dispatched first made the effective limit a
    function of runtime order. The raise happens before the permit is taken,
    so no provider request goes out under a limit its caller did not
    declare. *)
val with_admission : config:Provider_config.t -> (unit -> 'a) -> 'a

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
    until the deadline and [f] never ran; the waiter has left the FIFO. A
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

(** Point-in-time scheduler snapshot for [config]'s endpoint identity, or
    [None] when no dispatch has declared admission for it yet.
    Diagnostics only. *)
val snapshot_for : config:Provider_config.t -> Slot_scheduler.snapshot option
