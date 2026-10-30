(** One Stagehand runtime inside one Chromium, reached over one
    {!Browser_cdp} connection (RFC-browser-lane-stagehand §3.3–§3.4).

    Calls go one at a time. A call's delivery to the extension is not
    cancelled; when a caller is cancelled while it waits for the reply (the
    lane deadline), the call is abandoned: the extension may still be
    working on it and the protocol has no cancel method. Until its reply
    arrives, the session refuses the model requests the extension sends and
    refuses new calls, and a model answer that was still being computed is
    not delivered, so nothing takes effect after the caller was told the
    outcome is unknown. The reply is awaited for [abandoned_answer_s]: the
    first call after that, with the reply still out, ends the session, so
    an extension stuck on the abandoned call does not refuse calls forever.

    Delivery whose outcome is unknown leaves a separate unsettled barrier:
    the receiver may have started input before throwing. No new call or private
    companion is admitted, including after a late reply or elapsed abandoned
    deadline. The owner must explicitly close or retire the original browser;
    its shutdown must not depend on a successful runtime close call.

    An answer to the extension that cannot be delivered ends the session:
    the extension would wait for it, and the call in flight with it. *)

module Wire = Browser_stagehand_wire

type attach_error =
  | Extension_path of string  (** The extension directory has no real path. *)
  | Load_rejected of Browser_cdp.failure
  | Extension_id_mismatch of { expected : string; loaded : string }
      (** Chrome loaded the extension under another id than the one computed
          before launch, so the allowed origin is wrong. *)
  | Service_worker_absent
  | Malformed_reply of { method_ : string; detail : string }
      (** A CDP reply without the field the next step needs. *)
  | Runtime_not_ready
      (** The runtime's receiver or marker did not appear within [worker_wait_s]. *)
  | Runtime_marker of string
  | Runtime_incompatible of { found : string; supported : int }
  | Init_unanswered of float
      (** [stagehand.init] did not answer within this many seconds of being
          sent. Its effect is unknown. *)
  | Init_failed of call_failure
  | Cdp of Browser_cdp.failure
  | Already_attached  (** {!attach} was already called on this session. *)

and call_failure =
  | Not_attached  (** Refused before any effect. *)
  | Detached  (** The service worker went away. Refused before any effect. *)
  | Connection_gone of string  (** The session ended. Refused before any effect. *)
  | Abandoned_call_pending
      (** Refused before any effect. The abandoned call is still inside its
          [abandoned_answer_s]. *)
  | Delivery_unsettled
      (** Refused before any effect. An earlier delivery may have started
          extension input and its settlement is unconfirmed. The original
          browser must be explicitly closed or retired; a late reply cannot
          remove this barrier. *)
  | Not_delivered of string  (** The message never reached the extension. *)
  | Rejected of Wire.rpc_error  (** The extension answered with an error. *)
  | Lost of string
      (** No answer, or one that could not be read. The call may or may not
          have taken effect. *)

(** What the session reports for the operator's log. *)
type event =
  | Runtime_ready of Wire.marker
      (** The runtime is installed and speaks the supported major; init
          follows. *)
  | Model_request_refused of { reason : string }
  | Model_failed of string  (** The model function raised; the extension was refused. *)
  | Unsupported_request of { method_ : string }
  | Unsupported_notification of { method_ : string }
  | Extension_log of Yojson.Safe.t option
  | Malformed_message of string
  | Unexpected_response of { id : int }
  | Cancelled_call_answered of { method_ : string; rejected : bool }
      (** The reply arrived before the cancelled caller resumed. No call
          remains abandoned; owners must not retire the session for this call. *)
  | Abandoned_call_ended of { method_ : string; rejected : bool }
      (** The reply of a call whose caller had left. *)
  | Abandoned_call_unanswered of { method_ : string; waited_s : float }
      (** A call whose caller had left did not answer within
          [abandoned_answer_s]. The session ends with it. *)
  | Reply_not_delivered of string  (** The session ends with it. *)
  | Malformed_cdp_event of { method_ : string; detail : string }
  | Worker_detached
  | Connection_ended of string

(** Answers one [llm.generate] with its [params]. It runs on its own fiber and
    is cancelled when the call that asked for it ends. *)
type model = Yojson.Safe.t -> (Yojson.Safe.t, Wire.rpc_error) result

type t

(** [create ~sw ~clock ~worker_wait_s ~init_answer_s ~abandoned_answer_s
    ~model ~log] is an unattached session. Fibers that answer the extension
    run on [sw]. [worker_wait_s] bounds the wait for the extension's service
    worker to appear after loading, and then the wait for its runtime to be
    ready. [init_answer_s] bounds [stagehand.init] from its sending to its
    answer. [abandoned_answer_s] bounds the wait for the reply of a call whose
    caller left. No other call has a deadline here. *)
val create :
  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> worker_wait_s:float
  -> init_answer_s:float
  -> abandoned_answer_s:float
  -> model:model
  -> log:(event -> unit)
  -> t

(** Give this as [on_event] to {!Browser_cdp.connect}. *)
val on_cdp_event : t -> Browser_cdp.event -> unit

(** Loads the extension at [extension_dir], finds and attaches to its service
    worker, checks the runtime marker, and sends [stagehand.init] with
    [browser_cdp_url]. Returns the init result. {!call} is refused until
    init answers. A session attaches once: a second attach is
    [Already_attached], and an attach that fails, raises or is cancelled
    ends the session. *)
val attach :
  t -> Browser_cdp.t -> extension_dir:string -> browser_cdp_url:string -> (Yojson.Safe.t, attach_error) result

(** Sends one call once the previous one has ended, and waits for its reply
    with no deadline of its own: the caller bounds it. An attached session with
    an unknown delivery refuses all later calls, including [Wire.Close], with
    [Delivery_unsettled]. The browser owner's explicit close still shuts down
    its original resources. Delivery failures expose safe classifications;
    CDP rejection messages and receiver exception details are not forwarded
    into the call result or session log. *)
val call : t -> Wire.call -> (Yojson.Safe.t, call_failure) result
val quiescent : t -> bool
(** Nonblocking observation: attached, transport alive and no in-flight,
    abandoned or delivery-unsettled Stagehand call. A private companion must
    check this under the backend's page serializer immediately before using the
    original transport; releasing a cancelled public verb's slot alone does not
    establish that its extension input has settled. *)
val with_private_transport : t ->
  (Browser_cdp.t -> worker:Browser_cdp.session_id -> ('a, unit) result) -> ('a, unit) result
(** Trusted callback on the original verified transport and Stagehand worker.
    Requires quiescence; caller holds the backend's page-operation slot.
    No CDP URL, reconnect or alternate session is exposed. *)
