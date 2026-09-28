(** Guest relay session for collab rooms (RFC-0471 stack 6).

    Dials the relay over ws/wss, hellos, and folds host frames through
    {!Collab_guest_join} into UI events. All failures are closed
    variants: dial/TLS/handshake at connect time, capability and
    liveness at send time, close codes as events. *)

type connect_error =
  | Dial_failed of string
  | Tls_failed of string
  | Handshake_failed of string

val connect_error_to_string : connect_error -> string

type send_error =
  | View_only
  | Not_connected of string

val send_error_to_string : send_error -> string

type session_event =
  | Frame_event of Collab_guest_join.event
  | Transport_closed of {
      code : int;
      reason : string;
    }
      (** The socket closed: a relay close code (4001/4004/4009/4029, a
          room-closed bye, or a plain EOF mapped to 1006), never silent. *)

type handle

val connect
  :  sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> target:Collab_guest_join.target
  -> label:string option
  -> on_event:(session_event -> unit)
  -> (handle, connect_error) result
(** [connect ~sw ~env ~target ~label ~on_event] dials the relay,
    hellos (with the write token iff the link is control), and drives
    the join: every host frame folds through the assembler and each
    resulting event is delivered to [on_event] from the reader fiber.
    [on_event] must not raise; a raise fails the session. The session
    lives on [sw] and ends with {!close} or the socket. *)

val capability : handle -> Collab_link.capability

val send_prompt : handle -> string -> (unit, send_error) result
(** [send_prompt handle text] queues a guest prompt. Control links
    only: view guests get [View_only] without touching the socket. *)

val send_abort : handle -> (unit, send_error) result
(** [send_abort handle] aborts the current operation. Control only. *)

val fetch_transcript : handle -> req_id:int -> max_bytes:int -> (unit, send_error) result
(** [fetch_transcript handle ~req_id ~max_bytes] asks for scrollback.
    View-safe: both capabilities may call it. *)

val close : handle -> unit
(** [close handle] ends the session: idempotent, never raises, never
    blocks. In-flight [on_event] calls run to completion. *)
