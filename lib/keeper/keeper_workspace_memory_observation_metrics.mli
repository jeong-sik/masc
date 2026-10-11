val record : keeper_name:string -> Workspace_memory_ledger.observation -> unit
(** Emit per-turn gauges for the workspace memory briefing summary byte size
    (labeled by briefing status) and the classified ledger claim count.
    Observation only: no size cap or gate is applied. [Missing] and
    [Unavailable] ledger observations emit nothing — a zero-size briefing is
    not a growth signal worth a series. *)
