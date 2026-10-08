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
    the registry's short process-wide critical section. {!publish} is the
    exception: it changes a published identity's scheduler and wakes its
    newly granted waiters inside that section, so the registry and the
    scheduler change together.

    @since 0.216.0 *)

(** [with_admission ~config f] runs [f] under the endpoint's concurrency
    permit when [config.max_concurrent_requests] is declared, and directly
    otherwise. A waiting request queues as [config.admission_class] (one
    shared queue when the endpoint declares no run limit); cancellation
    while waiting does not leak a permit (see {!Slot_scheduler.with_permit}).

    On an identity whose allowance was published ({!publish}), the request
    runs under the published allowance, whatever [config] declares. On an
    unpublished identity, two configs with different allowances
    ([max_concurrent_requests] or [admission_priority_run_limit]) raise
    [Invalid_argument]: neither declaration outranks the other, and taking
    the first one admitted would let runtime order decide the limit. The
    raise happens before the permit is taken, so no provider request goes
    out under a limit its caller did not declare. *)
val with_admission : config:Provider_config.t -> (unit -> 'a) -> 'a

(** {2 Published allowances}

    A consumer that knows its whole configuration publishes one allowance
    per endpoint identity. A published allowance governs that identity
    while the process runs: publishing a new one reconfigures the identity's
    scheduler in place ({!Slot_scheduler.reconfigure}), and a request built
    from an older config is admitted under the published allowance instead
    of raising. An identity never published keeps the rule above. *)

(** Configs that name one endpoint identity with more than one allowance;
    each declaration is the caller's label with what it declared.
    [base_url] is sanitized for logs. *)
type allowance_disagreement =
  { kind : string
  ; base_url : string
  ; declarations : (string * Provider_admission_state.allowance) list
  }

(** One agreed allowance per endpoint identity, ready to publish. *)
type published_allowances

val allowances_of_configs
  :  (string * Provider_config.t) list
  -> (published_allowances, allowance_disagreement list) result
(** The allowances [configs] declare, one per endpoint identity, or every
    identity whose configs disagree. A config without
    [max_concurrent_requests] declares none. Each config carries the
    caller's label, which a disagreement names. *)

val publish : published_allowances -> unit
(** Make each allowance its identity's allowance: a new identity gets a
    scheduler, and an existing one is reconfigured when its allowance
    changed. Identities left out are kept as they are. It does not need an
    Eio fiber. *)

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

(** Install the process-wide observer queued requests report to, replacing
    any installed before, and return the function that removes it. That
    function removes only this installation: after a later install it does
    nothing. With none installed, nothing is timed. The observer runs on
    the requesting fiber when the wait ends: a granted request reports
    before it is sent. It must not wait on I/O; taking an Eio mutex briefly,
    as an event bus publish does, is fine. A raise from it fails that
    request but leaves no permit held. *)
val install_wait_observer : (wait -> unit) -> unit -> unit


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
