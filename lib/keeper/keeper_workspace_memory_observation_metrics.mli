val record : Workspace_memory_ledger.observation -> unit
(** Set the workspace gauges from one ledger observation: the classified
    claim count, and the byte size of the published briefing body when the
    observation read one ([Current] or [Stale]). A [Missing] or unreadable
    briefing leaves the size gauge at the last body measured, and a missing
    or unavailable ledger sets nothing. Neither gauge has labels: both values
    belong to the workspace. *)
