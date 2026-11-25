(** Declarative GET SSE subscription hub running on {!Io_domain}.

    Manages at most 2 persistent streams ({!Stream_spec.Observer} and
    {!Stream_spec.Fleet}) plus at most 1 view-scoped GET stream (model metrics,
    tool series, or system logs; POST-only keeper chat streaming runs via
    {!Http_client.post_stream}). Each stream runs in its own child [Eio.Switch]
    on {!Io_domain}, validates replay cursors via {!Sse_wire} /
    {!Wire_observer}, resets reconnect backoff after live healthy sessions,
    fences stale events from cancelled generations, cleans up active entries on
    [409 workspace_mismatch], and runs a sibling staleness watchdog emitting
    {!Masc_tui_core.Health.source_freshness}. *)

open Masc_tui_core
open Masc_tui_protocol

module Stream_spec : sig
  type kind =
    | Observer
    | Fleet
    | Model_metrics
    | Tool_metrics_series
    | Logs of { since_seq : int option }

  type t = {
    kind : kind;
    stale_after_s : float;
    idle_timeout_s : float;
  }

  val id : kind -> string
  val path : kind -> string
  val is_persistent : kind -> bool
  val equal_kind : kind -> kind -> bool
  val equal : t -> t -> bool

  val default_observer : t
  val default_fleet : t
  val model_metrics : t
  val tool_metrics_series : t
  val logs : ?since_seq:int -> unit -> t
end

type sync_diff = {
  to_start : Stream_spec.t list;
  to_stop : Stream_spec.kind list;
  kept : Stream_spec.kind list;
}

val max_persistent_streams : int
(** [2] ([Observer] + [Fleet]). *)

val max_view_scoped_streams : int
(** [1]. *)

val validate_desired : Stream_spec.t list -> (Stream_spec.t list, string) result
(** Deduplicate desired stream specs and enforce at most 2 persistent streams
    and at most 1 view-scoped stream. *)

val diff_streams :
  active:Stream_spec.t list -> desired:Stream_spec.t list -> sync_diff
(** Pure subscription diff between currently [active] and [desired] streams. *)

val reconnect_delay_s : attempt:int -> jitter_unit:float -> float
(** Exponential reconnect delay ([0.5s -> 1s -> 2s -> 4s -> max 10s]) with
    [+/-20%] jitter where [jitter_unit] is clamped to [[-1.0; 1.0]]. *)

val next_reconnect_attempt : prev_attempt:int -> reached_live:bool -> int
(** Reset retry attempt counter to [1] after a connection reached healthy live
    state; otherwise increment [prev_attempt]. *)

type handshake_outcome =
  | Handshake_ok of Wire_observer.handshake_result
  | Handshake_retry_without_cursor of {
      stale_cursor : Sse_wire.observer_cursor;
      reason : string;
    }
  | Handshake_invalid of string

val evaluate_observer_handshake :
  cursor:Sse_wire.observer_cursor option ->
  headers:(string * string) list ->
  handshake_outcome

type hub_event =
  | Freshness of {
      stream : Stream_spec.kind;
      freshness : Health.source_freshness;
    }
  | Observer_handshake of Wire_observer.handshake_result
  | Observer_delivery of Wire_observer.delivery
  | Fleet_event of Wire_fleet.fleet_stream_event
  | Raw_frame of { stream : Stream_spec.kind; frame : Sse_wire.frame }

type t

val create :
  io:Io_domain.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  endpoint:Http_client.endpoint ->
  t

val update_endpoint : t -> Http_client.endpoint -> unit
(** Update the target endpoint / workspace guard headers for subsequent stream
    connections. *)

val sync_streams :
  t -> on_event:(hub_event -> unit) -> Stream_spec.t list -> (sync_diff, string) result
(** Declaratively reconcile active streams against [desired]. Validates stream
    caps, fences and cancels removed streams, and spawns newly requested streams
    on {!Io_domain}. Each new stream keeps its own [on_event] through reconnect
    and unsubscribe so callers can capture the stream's workspace epoch. *)

val active_streams : t -> Stream_spec.t list
val shutdown : t -> unit
(** Fence and cancel all active streams and emit {!Health.Disconnected}
    freshness. *)
