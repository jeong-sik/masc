(** Session-owned preparation of the existing workspace bearer. The installer
    runs on a child of the UI switch, on the same Eio domain. Its existing
    filesystem/mint-lock implementation owns physical I/O and durable effects.
    This controller does not mint, move token storage, or grant authority.
    Create/start/status/take belong to the session domain. HTTP consumers on
    other Eio domains may await the published immutable promise. *)

type purpose = Initial | Workspace_retry
type request = private {
  purpose : purpose;
  base_path : string;
  host : string;
  port : int;
  started_ns : int64;
}
type outcome =
  | Observed of Masc_tui_credential.outcome
  | Not_started of string
  | Unobserved of string
type completion = private {
  request : request;
  worker_started_ns : int64 option;
  observed_ns : int64;
  outcome : outcome;
}
type status =
  | Not_requested
  | Preparing of request
  | Awaiting_ui of completion
  | Settled
type t

val create : unit -> t
val status : t -> status
val initial_settled : t -> bool
(** Initial preparation has been consumed by the UI, including failure or
    unavailable execution. This is UI consumption, not proof of a usable bearer
    or workspace/write authority. *)
val await_initial : t -> unit
(** Wait only for the initial installer's observed outcome, including refusal,
    unavailable execution or interruption. HTTP workers use this prerequisite
    before constructing their first request; they do not wait for UI draining
    or terminal probing. It grants no authentication or workspace authority. *)
val await_current : t -> unit
(** An HTTP consumer waits for an already admitted install before reading its
    bearer. Unrequested preparation does not start work. Observed completion
    releases this dependency before UI consumption, including on failure. *)
val start :
  t -> sw:Eio.Switch.t option -> purpose:purpose ->
  base_path:string -> host:string -> port:int ->
  install:(unit -> Masc_tui_credential.outcome) -> request option
(** Start once, or share the active/unconsumed preparation. A retry is admitted
    only after initial settlement. [None] means no new job. No switch publishes
    Not_started without running inline. The original completion is retained
    before any UI drain; it never waits for shared-mailbox space. *)
val take_completed : t -> completion option
(** UI-domain consumption releases this job. Cancellation of an entered
    installer retains Unobserved and re-raises; it does not prove a mint failed
    or undo a durable credential. There is no automatic replay or deadline.
    Switch exit still waits for the installer's actual protected I/O/lock
    settlement; making input independent does not bound shutdown. *)
