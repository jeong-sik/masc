(** Tells roster readers which Keepers' shown provider rest moved
    (RFC-0481 §3.2, §3.7).

    A roster row shows [runtime_path_rest]: whether the Keeper's walk is
    serving or resting, on which runtime, and when a resting walk releases.
    It moves when one of the six rest-record writers runs
    ({!Runtime_path_rest_signal}) and when a dated rest ends, with no write.

    [install ~sw ~clock ~config] installs the rest-record observer, which only
    wakes a fiber forked on [sw]. On each wake the fiber recomputes every
    listed Keeper's shown rest, as the row draws it, and sends
    {!Keeper_row_broadcast.changed} for each Keeper whose value moved. Between
    wakes it waits for the next record, or until the earliest dated release on
    any Keeper's walk, whichever comes first; it keeps no timer per Keeper. A
    failed recomputation is logged and the previous values are kept, so the
    fiber never fails its switch. *)

val install :
  sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> config:Workspace.config -> unit
