(** One Stagehand runtime inside one Chromium, reached over one
    {!Browser_cdp} connection (RFC-browser-lane-stagehand §3.3–§3.4).

    Calls go one at a time. When a caller is cancelled while its call is out
    (the lane deadline), the call is abandoned: the extension may still be
    working on it and the protocol has no cancel method. Until its reply
    arrives, the session refuses the model requests the extension sends and
    refuses new calls, and a model answer that was still being computed is
    not delivered, so nothing takes effect after the caller was told the
    outcome is unknown. *)

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
  | Runtime_marker of string
  | Runtime_incompatible of { found : string; supported : int }
  | Init_failed of call_failure
  | Cdp of Browser_cdp.failure

and call_failure =
  | Not_attached  (** Refused before any effect. *)
  | Detached  (** The service worker went away. Refused before any effect. *)
  | Connection_gone of string  (** The session ended. Refused before any effect. *)
  | Abandoned_call_pending  (** Refused before any effect. *)
  | Not_delivered of string  (** The message never reached the extension. *)
  | Rejected of Wire.rpc_error  (** The extension answered with an error. *)
  | Lost of string  (** No answer. The call may or may not have taken effect. *)

(** What the session reports for the operator's log. *)
type event =
  | Model_request_refused of { reason : string }
  | Model_failed of string  (** The model function raised; the extension was refused. *)
  | Unsupported_request of { method_ : string }
  | Unsupported_notification of { method_ : string }
  | Extension_log of Yojson.Safe.t option
  | Malformed_message of string
  | Unexpected_response of { id : int }
  | Abandoned_call_ended of { method_ : string; rejected : bool }
      (** The reply of a call whose caller had left. *)
  | Reply_not_delivered of string
  | Malformed_cdp_event of { method_ : string; detail : string }
  | Worker_detached
  | Connection_ended of string

(** Answers one [llm.generate] with its [params]. It runs on its own fiber and
    is cancelled when the call that asked for it ends. *)
type model = Yojson.Safe.t -> (Yojson.Safe.t, Wire.rpc_error) result

type t

(** [create ~sw ~clock ~worker_wait_s ~model ~log] is an unattached session.
    Fibers that answer the extension run on [sw]. [worker_wait_s] bounds the
    wait for the extension's service worker to appear after loading. *)
val create :
  sw:Eio.Switch.t
  -> clock:_ Eio.Time.clock
  -> worker_wait_s:float
  -> model:model
  -> log:(event -> unit)
  -> t

(** Give this as [on_event] to {!Browser_cdp.connect}. *)
val on_cdp_event : t -> Browser_cdp.event -> unit

(** Loads the extension at [extension_dir], finds and attaches to its service
    worker, checks the runtime marker, and calls [stagehand.init] with
    [browser_cdp_url]. Returns the init result. Until init answers, only init
    may be called; if attach fails, the session is over. *)
val attach :
  t -> Browser_cdp.t -> extension_dir:string -> browser_cdp_url:string -> (Yojson.Safe.t, attach_error) result

val call : t -> Wire.call -> (Yojson.Safe.t, call_failure) result
