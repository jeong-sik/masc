(** Multi-domain OCaml 5.5 + Eio topology ([Ui], [Io], [Worker]).

    All domains use the 4M-word tuned minor heap ({!Minor_heap.Tuned}) so
    steady-state UI rendering, persistent SSE + HTTP I/O on [Io], and JSON /
    diff offload on the bounded multi-domain [Worker] pool minimize
    stop-the-world minor collection pauses. *)

type role =
  | Ui
  | Io
  | Worker

val minor_heap : role -> Minor_heap.t
val use_ui_heap : unit -> unit
(** Apply the [Ui] minor-heap configuration on the calling (main UI) domain. *)

val domain_mgr_for :
  role -> _ Eio.Domain_manager.t -> Eio.Domain_manager.ty Eio.Resource.t
(** Wrap [mgr] so domains spawned through it start on [minor_heap role]. *)

val start_worker_pool :
  sw:Eio.Switch.t -> _ Eio.Domain_manager.t -> Domain_pool.t
(** Start a bounded multi-domain (2..4) CPU/offload {!Domain_pool.t} tuned for
    [Worker] so one large JSON decode cannot head-of-line block other replies. *)
