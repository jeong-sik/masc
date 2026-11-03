(** Says that every roster row may have moved when the runtime catalogue is
    published (RFC-0481 §3.2).

    A row's runtime id comes from the Keeper's [[runtime.assignments]] entry
    or the default route, and its provider rest walks the whole catalogue: a
    lane's candidates, the runtimes and their bindings. A publication
    (startup, reload, setup-required, an assignment transaction, a rollback)
    can move any of these, so each one sends
    {!Keeper_row_broadcast.roster_changed} and no route is compared. Nothing
    is read from the catalogue, so an empty or setup-required catalogue cannot
    stop the fiber.

    [install ~sw ~base_path] forks a fiber on [sw] that waits for each
    publication without polling. Publications that land together send one
    signal. The runtime state belongs to the process; the signal goes to
    [base_path]'s observers only. *)

val install : sw:Eio.Switch.t -> base_path:string -> unit
