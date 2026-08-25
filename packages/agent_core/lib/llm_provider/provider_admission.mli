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

(** Point-in-time scheduler snapshot for [config]'s endpoint identity, or
    [None] when no dispatch has declared admission for it yet.
    Diagnostics only. *)
val snapshot_for : config:Provider_config.t -> Slot_scheduler.snapshot option
