(** Firefox native messaging host. stdout belongs exclusively to the framed
    protocol; operational diagnostics must never include tokens or page data.

    The host polls the server for commands, forwards each to the extension
    as one native frame, and posts the reply back. Its waits are bounded --
    the HTTP round trip, the extension's reply, a BiDi command -- and each
    bound keeps what arrived as it closed: the extension aborts a command at
    the very [deadlineMs] the host sent it, so its reply and the host's own
    timer land together by design, and a reply that lands so must stand as
    the reply. *)

(** The verbs the server may forward; the BiDi peer's own. *)
type verb = Masc.Browser_bidi_peer.verb =
  | Browser_info | Tabs_list | Page_read | Page_elements | Page_capture | Page_scene | Page_interact

type command = { id : string; verb : verb; args : Yojson.Safe.t }

(** How one exchange with the extension ended. [Replied] carries the reply
    envelope, the extension's own or the host's failure for it; a frame the
    host could not write within the window is [Write_timed_out], and ends
    the host. *)
type exchange = Replied of Yojson.Safe.t | Write_timed_out

(** The window the host gives the extension for one command, in seconds; the
    command carries it as [deadlineMs]. *)
val extension_timeout_sec : float

(** The one pending exchange of the serial host: at most one command awaits
    a reply at a time. *)
type pending

val no_pending : unit -> pending

(** [forward ~clock ~stdout pending command] writes [command] as one native
    frame to [stdout] and waits for its reply, delivered through {!settle},
    for at most {!extension_timeout_sec}. A reply that lands as the window
    closes is the reply; a window that closes with no reply is
    [Replied (failure "extension reply timed out")]; a window that closes
    while the frame is still being written is [Write_timed_out]. *)
val forward
  :  clock:_ Eio.Time.clock
  -> stdout:_ Eio.Flow.sink
  -> pending
  -> command
  -> exchange

(** [settle pending reply] decodes a reply frame from the extension and,
    when its id is the pending command's, resolves that exchange with the
    reply envelope; a reply for any other id is dropped. [Error] is a frame
    that is not a reply. *)
val settle : pending -> Yojson.Safe.t -> (unit, string) result

type config

(** Resolves the server origin, the lane token file and a fresh client id
    from the command line and the workspace's connection file. *)
val resolve_config
  :  base_path:string option
  -> server:string option
  -> token_file:string option
  -> (config, string) result

(** The native-messaging host: polls the server, forwards commands to the
    extension over stdout, reads replies from stdin. Returns when stdin
    reaches EOF or the poll loop stops; the string is why. *)
val run : Eio_unix.Stdenv.base -> config -> (unit, string) result

(** The BiDi host: the same poll loop with commands dispatched to a loopback
    Firefox BiDi endpoint at [url] instead of the extension. *)
val run_bidi : Eio_unix.Stdenv.base -> config -> string -> (unit, string) result

module For_testing : sig
  (** A transport step under its deadline: the step's outcome when it
      finished, even as the deadline passed; [None] only when it had not. *)
  val within : clock:_ Eio.Time.clock -> float -> (unit -> 'a) -> 'a option
end
