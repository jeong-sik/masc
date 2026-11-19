(** The domains a TUI process runs, and the minor heap each collects on.

    The TUI is a client: one domain draws, one sends requests, one decodes.
    {!minor_heap} is the one table of which heap each collects on. The code
    that starts each domain reads its own row: {!use_ui_heap} on the main
    domain, [Masc_tui_io_domain.start] and {!start_worker_pool}. None of
    them takes a heap from its caller, so no call site chooses a role. A
    domain the TUI starts any other way keeps the runtime's heap. *)

type t =
  | Ui  (** The main domain: reads keys and draws frames. *)
  | Io  (** [Masc_tui_io_domain]: sends requests and reads their answers. *)
  | Worker
      (** The one-domain [Domain_pool]: decodes answers, reads local files and
          searches a chat. *)

val minor_heap : t -> Minor_heap.t

val use_ui_heap : unit -> unit
(** Gives the calling domain, the TUI's main domain, the heap of [Ui]. Call
    it before the TUI allocates for its work. *)

val start_worker_pool : sw:Eio.Switch.t -> _ Eio.Domain_manager.t -> Domain_pool.t
(** [start_worker_pool ~sw dm] starts the TUI's one worker domain through
    [dm], on the heap of [Worker]. It lives as long as [sw]. *)
