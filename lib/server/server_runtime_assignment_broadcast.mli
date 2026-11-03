(** Says which roster rows a new runtime catalogue moved (RFC-0481 §3.2).

    A roster row shows the Keeper's runtime id: its [[runtime.assignments]]
    entry, or the default route when it has none. The loaded runtime state is
    replaced whole on every publication (startup, reload, an assignment
    transaction, a rollback), and each one moves {!Runtime.catalogue_revision}.

    [install ~sw ~base_path] forks a fiber that waits for each publication
    without polling and compares the routes before and after. A changed
    default route moves every unassigned row, so it sends
    {!Keeper_row_broadcast.roster_changed}; otherwise each Keeper whose
    assignment appeared, disappeared or changed gets
    {!Keeper_row_broadcast.changed}. A publication that moves no route sends
    nothing. The signals go to [base_path]'s observers. *)

type routes =
  { assignments : (string * string) list
  ; default_route : string
  }

type announcement =
  | Every_row
  | Rows of string list

val announcement : before:routes -> after:routes -> announcement

val install : sw:Eio.Switch.t -> base_path:string -> unit
