(** The domains a TUI process runs, and the minor heap each collects on.

    The TUI is a client: one domain draws, one sends requests, one decodes.
    Each domain names its heap where it starts ({!Minor_heap}), from this
    table, so none of them takes the server's heap because a library chose
    it. A new domain gets a constructor here, and the compiler asks for its
    heap. *)

type t =
  | Ui  (** The main domain: reads keys and draws frames. *)
  | Io  (** {!Masc_tui_io_domain}: sends requests and reads their answers. *)
  | Worker
      (** The one-domain [Domain_pool]: decodes answers, reads local files and
          searches a chat. *)

val minor_heap : t -> Minor_heap.t
