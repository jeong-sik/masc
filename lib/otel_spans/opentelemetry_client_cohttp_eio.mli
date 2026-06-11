(** Opentelemetry_client_cohttp_eio — Eio-native OTel
    exporter (cohttp-eio backend) wrapped behind a tiny
    pinned surface.

    The .ml is intentionally private-heavy: the bulk of it implements the
    full {!Opentelemetry.Collector.BACKEND} module
    (Httpc client, Batch / Signal helpers, custom emitter pipeline).
    External callers get only backend
    lifecycle entry points plus the small tick-health accessors that
    {!Otel_spans} surfaces in [/health]. Pinning that minimal surface lets the
    BACKEND machinery evolve internally without contract churn.

    Internal helpers stay private at this boundary
    (the [OT] / [Signal] / [Batch] aliases, the
    [( let@ )] / [spf] helpers, [set_headers] /
    [get_headers], the [error] type, the
    [n_errors] / [n_dropped] counters, [report_err_],
    the {!Httpc} module, the {!EMITTER} module type,
    [mk_emitter], the {!Backend} functor, [create_backend], [setup_],
    [with_setup]).

    Library [Opentelemetry.GC_metrics] sampling is intentionally absent:
    process.runtime.ocaml.gc.* duplicated the masc_gc_* gauges exported
    through Otel_metric_store. *)

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

val tick_degraded : unit -> bool
(** [true] once the exporter tick fiber has stopped after
    [Eio.Mutex.Poisoned]. The backend must be restarted to clear this state. *)

val last_tick_poisoned_error : unit -> string option
(** Last poison cause captured by the tick fiber, if any. *)

val reset_tick_health : unit -> unit
(** Clear tick degraded state before installing a fresh backend. *)

val remove_backend : unit -> unit
(** Uninstalls the active backend (counterpart to
    {!setup}).  Calls [OT.Collector.remove_backend
    ~on_done:ignore ()] under the hood — flush completion
    is intentionally not awaited so shutdown stays
    bounded. *)
