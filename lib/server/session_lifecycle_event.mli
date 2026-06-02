(** Session lifecycle typed events (RFC-0099).

    Published on the existing [Event_bus.Custom ("session_lifecycle",
    json)] channel. Dashboard surfaces consume from there. Closed sum;
    adding a new variant requires RFC-level discussion (same discipline
    as {!Mcp_error_code}).

    This module is {b wire-inert} at PR-2 — only the variant + JSON
    encoding land. PR-3+ wire the publish calls from the SSE eviction
    and lifecycle sites in {!Server_mcp_transport_http_sse}. *)

type transport = SSE | WS | GRPC | WebRTC

type evict_reason =
  | Cap_exceeded
      (** oldest-eviction triggered by [max_clients] cap. *)
  | Idle_timeout
      (** [cleanup_stale] crossed [MASC_TRANSPORT_IDLE_EVICT_SEC]. *)
  | Backpressure
      (** mailbox-full beyond drain grace, or {!Fd_accountant} pressure
          escalation (RFC-0101 §3.6, 5 s sustained). *)
  | Policy_revoked
      (** auth / quota / admin action terminated the session. *)

type close_reason =
  | Client_disconnected
  | Server_shutdown
  | Server_error of string
  | Evicted of evict_reason
      (** mirror frame written after an [Evict] transition; the close
          event echoes the eviction reason for log-trail completeness. *)

type t =
  | Open of {
      transport : transport ;
      session_id : string ;
      origin : string ;
    }
  | Upgrade of {
      transport_from : transport ;
      transport_to : transport ;
      session_id : string ;
    }
      (** transport upgrade within the same session (e.g. POST /mcp
          chunked-JSON → SSE on long-running dispatch — RFC-0100 §3.2). *)
  | Resume of {
      transport : transport ;
      session_id : string ;
      last_event_id : string option ;
      replayed : int ;
          (** number of frames the ring-buffer replayed past
              [last_event_id]. *)
    }
  | Evict of {
      transport : transport ;
      session_id : string ;
      reason : evict_reason ;
    }
      (** server-policy termination. {b Always} paired with a
          subsequent {!Close} carrying [Evicted reason] for log-trail
          completeness. *)
  | Close of {
      transport : transport ;
      session_id : string ;
      reason : close_reason ;
    }

(** {1 Wire encoding} *)

val transport_to_string : transport -> string
val transport_of_string : string -> transport option

val evict_reason_to_string : evict_reason -> string
val evict_reason_of_string : string -> evict_reason option

val close_reason_kind : close_reason -> string
(** Short label for the close-reason variant; the [Server_error _]
    payload travels in a separate [detail] field of the JSON encoding. *)

val to_yojson : t -> Yojson.Safe.t
(** Stable JSON encoding suitable for
    [Event_bus.Custom ("session_lifecycle", json)]. The shape is pinned
    by {!val:bus_topic} so dashboards can pattern-match a single topic
    name. *)

val of_yojson : Yojson.Safe.t -> (t, string) result

val bus_topic : string
(** Canonical [Event_bus.Custom] topic name. *)

val pp : Format.formatter -> t -> unit
(** Pretty-printer for tests and operator diagnostics. *)

(** {1 Publisher injection (PR-3)}

    The transport layer ({!Server_mcp_transport_http}, AGUI, etc.)
    cannot reach into the running {!Agent_sdk.Event_bus} directly —
    the bus handle lives behind {!Server_bootstrap_loops}. PR-3
    introduces a publisher hook so transport-side eviction sites can
    emit events without taking a hard dependency on bus plumbing. *)

val publish : t -> unit
(** [publish evt] forwards [evt] to the currently-installed
    publisher. No-op when no publisher is installed (identity
    default). Never raises; a publisher that raises is logged and
    swallowed so a failing observer cannot kill the transport
    eviction path. *)

val set_publisher : (t -> unit) -> unit
(** [set_publisher p] installs [p] as the publisher. Subsequent
    {!publish} calls invoke [p]. Idempotent / overwriting — the most
    recently set publisher wins. Intended to be called once at server
    bootstrap. *)

val reset_publisher : unit -> unit
(** [reset_publisher ()] restores the no-op default. Test-only. *)

val is_publisher_installed : unit -> bool
(** [is_publisher_installed ()] returns true iff a non-no-op
    publisher is currently installed. Observability only — not a
    synchronization primitive. *)
