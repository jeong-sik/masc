(** One Chrome DevTools Protocol connection over a loopback websocket
    (RFC-browser-lane-stagehand §3.3).

    Unlike {!Browser_bidi_peer.with_connection}, the connection outlives any
    single call: it is owned by the switch it was opened on, and CDP events are
    the point of it, not noise. [Runtime.bindingCalled] carries every message
    the Stagehand extension sends to the host. The socket runs under a daemon
    of the owner's switch, so the owner's work finishing, or the connection
    ending, closes it without waiting for Chrome to close its end.

    [t] is confined to one Eio domain: [command], [receive], and [lost]
    mutate the same pending-command table and must not be called from
    different domains. Fibers on that domain may interleave. *)

type session_id = string
(** A flat-mode CDP session ([Target.attachToTarget] with [flatten: true]). *)

type target_kind =
  | Page
  | Service_worker
  | Other_kind of string  (** Any other CDP target type, kept by name. *)

type target_info = { target_id : string; kind : target_kind; url : string }

(** One CDP [TargetInfo] object, as [Target.getTargets] lists it and
    [Target.targetCreated] carries it. *)
val target_info_of_json : Yojson.Safe.t -> (target_info, string) result

type event =
  | Binding_called of { session : session_id option; name : string; payload : string }
  | Target_created of target_info
  | Target_detached of { session : session_id }
  | Target_destroyed of { target_id : string }
  | Malformed_event of { method_ : string; detail : string }
      (** A CDP event this module decodes, whose params did not decode. *)
  | Unobserved of { method_ : string }
      (** A CDP event this module has no reader for. *)
  | Connection_ended of { reason : string }
      (** Sent once, when the connection ends; nothing follows it. *)

type failure =
  | Command_rejected of { code : int; message : string }
      (** The browser answered the command with an error. *)
  | Connection_lost of string
      (** No answer: the connection ended or the command deadline passed. The
          command may or may not have taken effect. *)

(** {1 Wire} *)

type envelope =
  | Reply of { id : int; result : (Yojson.Safe.t, int * string) result }
  | Event of { method_ : string; session : session_id option; params : Yojson.Safe.t option }
      (** CDP omits [params] for an event that has none. *)

(** One inbound text frame. [Error] for anything that is neither a reply nor an
    event. *)
val decode : string -> (envelope, string) result

val encode_command : id:int -> ?session:session_id -> string -> Yojson.Safe.t -> string

(** [event_of ~method_ ~session params] reads the events this module names.
    One of them without [params] is malformed. *)
val event_of : method_:string -> session:session_id option -> Yojson.Safe.t option -> event

(** {1 Connection} *)

type t

(** A connection over [send]. Frames the transport receives go to {!receive};
    the transport ending goes to {!lost}, which calls [close] once so the
    transport can let go. A command still without a reply after
    [command_deadline_s], or whose caller is cancelled while it is out, ends
    the connection, because a later command would be written behind one whose
    outcome is unknown. A failed [send] also ends the connection and settles
    every pending command as [Connection_lost]. Cancellation during [send]
    ends the connection and is re-raised. [on_event] runs on whichever fiber
    delivered the frame or ended the connection (the reader, a deadline, a
    cancelled caller, the owner's release) and must not block. In particular,
    calling [command] from [on_event] would wait for a reply that the reader
    cannot receive until [on_event] returns. Fork a separate fiber instead. *)
val create :
  send:(string -> unit)
  -> close:(unit -> unit)
  -> clock:_ Eio.Time.clock
  -> command_deadline_s:float
  -> on_event:(event -> unit)
  -> t

val receive : t -> string -> unit

(** Ends the connection: every waiting command returns [Connection_lost],
    every later one returns it without writing, and [on_event] receives
    [Connection_ended]. The first reason is kept. *)
val lost : t -> string -> unit

(** [None] while the connection is open. *)
val lost_reason : t -> string option

(** [command t ?session method_ params] writes one command and waits for its
    reply. *)
val command :
  t -> ?session:session_id -> string -> Yojson.Safe.t -> (Yojson.Safe.t, failure) result

(** [connect ~sw ~net ~clock ~url ...] opens [url], which must be a loopback
    [ws://] URL with an explicit port, and drives it on [sw]. No [Origin]
    header is sent. *)
val connect :
  sw:Eio.Switch.t
  -> net:[> `Generic ] Eio.Net.ty Eio.Resource.t
  -> clock:_ Eio.Time.clock
  -> url:string
  -> max_message:int
  -> command_deadline_s:float
  -> on_event:(event -> unit)
  -> (t, string) result
