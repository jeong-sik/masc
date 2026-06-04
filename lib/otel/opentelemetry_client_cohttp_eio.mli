(** Opentelemetry_client_cohttp_eio — Eio-native OTel
    exporter (cohttp-eio backend) wrapped behind a tiny
    pinned surface.

    The .ml is 475 lines: the bulk of it implements the
    full {!Opentelemetry.Collector.BACKEND} module
    (Httpc client, Batch / Signal helpers, GC metrics
    sampler, custom emitter pipeline).  External callers
    reach exactly three entry points — [Config], [setup],
    and [remove_backend] — through {!Otel_spans.start} and
    {!Otel_spans.shutdown}.  Pinning that minimal surface
    lets the BACKEND machinery evolve internally without
    contract churn.

    Internal helpers stay private at this boundary
    (the [OT] / [Signal] / [Batch] aliases, the
    [( let@ )] / [spf] helpers, [set_headers] /
    [get_headers], the GC-metric atomics
    [needs_gc_metrics] / [last_gc_metrics] /
    [timeout_gc_metrics], the {!GC_metrics} sub-module,
    [sample_gc_metrics_if_needed], [error] type, the
    [n_errors] / [n_dropped] counters, [report_err_],
    the {!Httpc} module, the {!EMITTER} module type,
    [mk_emitter], the {!Backend} functor, [create_backend],
    [setup_], [with_setup]). *)

module Config : sig
  type t
  (** Opaque config record built by {!make}.  Holds the
      OTLP endpoint URL plus the rest of the OTel
      collector knobs (resource attributes, headers,
      timeout, batch size).  All env-driven defaults are
      sourced via [Opentelemetry_client.Config.Env]. *)

  val make :
    ?debug:bool ->
    ?url:string ->
    ?url_traces:string ->
    ?url_metrics:string ->
    ?url_logs:string ->
    ?batch_traces:int option ->
    ?batch_metrics:int option ->
    ?batch_logs:int option ->
    ?headers:(string * string) list ->
    ?batch_timeout_ms:int ->
    ?self_trace:bool ->
    unit ->
    t
  (** OTel curry-builder.  Every field is optional with an
      [OTEL_*] env-derived default; the most common call
      shape is [Config.make ~url:endpoint ()] to override
      only the OTLP collector URL.  The trailing [unit] is
      mandatory because the upstream env-builder uses the
      [(unit -> t) Opentelemetry_client.Config.make]
      pattern (see Opentelemetry_client.Config). *)
end

val setup :
  ?stop:bool Atomic.t ->
  ?config:Config.t ->
  ?enable:bool ->
  sw:Eio.Switch.t ->
  Eio_unix.Stdenv.base ->
  unit
(** Installs the Eio-native OTel backend under the given
    switch.  [stop] is an optional cancellation flag the
    emitter polls; [config] defaults to a fresh
    {!Config.make} from env; [enable] (default [true])
    short-circuits the install when set to [false] so
    callers can keep a single boot path while toggling
    OTel via configuration. *)

val remove_backend : unit -> unit
(** Uninstalls the active backend (counterpart to
    {!setup}).  Calls [OT.Collector.remove_backend
    ~on_done:ignore ()] under the hood — flush completion
    is intentionally not awaited so shutdown stays
    bounded. *)
