val install : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> config:Workspace.config -> unit
(** Announce [keeper_costs] when a row or day file the Keeper cost window
    keeps leaves its default window ({!Dashboard_http_keeper_feeds.keeper_costs_next_change}).
    The fiber forked on [sw] sleeps until the earliest such instant and wakes
    early when a read keeps new rows; it keeps no timer per row. *)
