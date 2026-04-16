(** Client-declared per-endpoint capacity for providers that do not
    expose a slot/capacity probe (ollama HTTP, CLI transports, etc.).

    [Cascade_throttle] is Discovery-driven and currently only speaks
    to llama-server via [/slots].  Ollama on port 11434 has no slot
    concept, but users nonetheless want at most one concurrent call
    so two keepers don't trash the GPU.  This module is the MASC-side
    semaphore: a declared [max_concurrent], an atomic active counter,
    and a [capacity] query that returns the same [capacity_info]
    record so [Cascade_strategy.signal_ctx.capacity] can consult a
    single uniform view.

    The counter is maintained by explicit [try_acquire] / release
    pairs at the cascade call site.  No timeout, no queueing, no
    blocking — if no slot is free, [try_acquire] returns [None] and
    the strategy's capacity filter will have already skipped this
    endpoint in its ordering.  Defense-in-depth: both the filter and
    the acquire check the same counter, so a race between filter and
    acquire simply yields a [None] that the cascade treats as
    [Slot_full] and tries the next candidate.

    @since 0.9.6 *)

(** {1 Registration} *)

val register : url:string -> max_concurrent:int -> unit
(** Register a client-declared capacity for [url].  Idempotent:
    re-registering the same [url] with the same [max_concurrent] is a
    no-op; changing [max_concurrent] updates the cap and preserves
    the current active count.  Caller is responsible for passing
    [max_concurrent >= 1]; values [<= 0] are silently clamped to 1
    to avoid starvation.

    Typical callers:
    - module init parses [MASC_CLIENT_CAPACITY]
    - [auto_register_for_candidates] auto-registers ollama URLs *)

val registered_urls : unit -> string list
(** Snapshot of currently-registered URLs.  Test helper. *)

val unregister_all : unit -> unit
(** Remove every registration.  Test helper. *)

(** {1 Auto-registration} *)

val auto_register_for_candidates :
  base_urls:string list ->
  unit
(** For each base URL that looks like an ollama HTTP endpoint
    (heuristic: host/port contains [:11434]) and is not yet
    registered, register it with the default ollama concurrency
    (env [MASC_OLLAMA_MAX_CONCURRENT], fallback [1]).

    Idempotent.  Safe to call on every cascade attempt; already-
    registered URLs are left alone. *)

val auto_register_ollama_with_override :
  base_urls:string list ->
  max_concurrent:int ->
  unit
(** Like {!auto_register_for_candidates} but with an explicit
    [max_concurrent] that overrides the env default.  Used by the
    per-cascade [<name>_ollama_max_concurrent] field.

    Idempotent and only touches URLs that look like ollama and are
    not already registered. *)

val auto_register_cli_for_candidates :
  capacity_keys:string list ->
  unit
(** For each capacity key that looks like a CLI sentinel
    (heuristic: starts with [cli:]) and is not yet registered,
    register it with the default CLI concurrency
    (env [MASC_CLI_MAX_CONCURRENT], fallback [1]).

    Idempotent.  CLI providers (Claude_code / Gemini_cli / Codex_cli)
    have an empty [base_url] so the cascade caller derives a
    sentinel like [cli:claude_code] for capacity key purposes;
    registering that sentinel here gives the strategy a uniform
    [signal_ctx.capacity] view across HTTP and CLI providers.

    @since 0.9.8 *)

val auto_register_cli_with_override :
  capacity_keys:string list ->
  max_concurrent:int ->
  unit
(** Like {!auto_register_cli_for_candidates} but with an explicit
    [max_concurrent] that overrides the env default.  Used by the
    per-cascade [<name>_cli_max_concurrent] field.

    Idempotent and only touches keys that look like CLI sentinels
    and are not already registered.

    @since 0.9.8 *)

(** {1 Capacity query} *)

val capacity : string -> Cascade_throttle.capacity_info option
(** [capacity url] returns the current [Cascade_throttle.capacity_info]
    for a client-declared URL.  Returns [None] if [url] was never
    registered.  The [source] field is always
    [Llm_provider.Provider_throttle.Fallback] (no Discovery input).

    The [process_active] and [process_available] values reflect the
    atomic counter; [total] = registered [max_concurrent];
    [process_queue_length] is always 0 (no queueing in Phase 1). *)

(** {1 Acquire / release} *)

type release = unit -> unit
(** Idempotent release thunk.  Calling it twice is safe; the second
    call is a no-op. *)

val try_acquire : string -> release option
(** Non-blocking acquire.  Returns [Some release] when a slot was
    obtained and the caller is now responsible for calling [release]
    exactly once (via [Fun.protect], [Eio.Switch.on_release], or
    explicit control flow).  Returns [None] when:
    - [url] is not registered → unlimited, no counter maintained
      (caller should treat [None] as "no client cap, go ahead");
    - [url] is registered and [process_available = 0] → slot full,
      caller should treat [None] as [Slot_full] and try another
      candidate.

    Disambiguate these two [None] cases via {!capacity}: if
    [capacity url = None] the URL is unregistered; otherwise it is
    full. *)

val is_registered : string -> bool
(** [is_registered url] is [true] iff [url] has a declared capacity.
    Convenience for the caller's [try_acquire] disambiguation. *)
