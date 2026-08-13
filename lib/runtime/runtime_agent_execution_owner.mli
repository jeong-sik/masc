(** Process-wide owner of Agent Core's application-lifetime execution runtime.

    The server composition root creates and installs exactly one owner under
    its root switch.  Keeper call sites may later obtain the shared runtime to
    create one fresh execution store per Agent API call; they must not create a
    runtime inside a turn or provider retry. *)

type t

type install_error = Already_installed

type availability =
  | Available of t
  | Unavailable

val create
  :  sw:Eio.Switch.t
  -> domain_mgr:_ Eio.Domain_manager.t
  -> domain_count:int
  -> (t, Agent_core.Error.t) result
(** Create the application-lifetime runtime.  [sw] must be the process owner
    switch rather than a request, turn, or provider-attempt switch. *)

val install : sw:Eio.Switch.t -> t -> (unit, install_error) result
(** Install the sole process owner.  The exact installation is released when
    [sw] closes, so a later application lifetime in the same test process may
    install a new owner. *)

val current : unit -> availability
(** Return the installed owner without inventing an inline or per-turn
    fallback. *)

val execution_runtime : t -> Agent_core.Agent.execution_runtime
(** Project the owned capability for construction of caller-owned execution
    stores.  Store directory and locator lifecycle remain the caller's
    responsibility. *)
