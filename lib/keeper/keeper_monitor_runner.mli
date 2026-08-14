(** RFC-0379 monitor runner: a server fiber that observes registered monitor
    conditions and enqueues a [Monitor_fired] wake when one crosses its edge.

    The runner is the only observer. It keeps each monitor's baseline in
    memory only — the first observation after boot establishes a baseline and
    never fires — probes with adaptive intervals (2s while the watched edge
    has not arrived, 10s while resting), and lets [Monitor_domain.decide]
    make every fire decision. *)

val sweep_interval_sec : float
val probe_timeout_sec : float
val unmet_probe_interval_sec : float
val met_probe_interval_sec : float

val run :
  net:'a Eio.Net.t ->
  clock:'b Eio.Time.clock ->
  base_path:string ->
  unit ->
  unit
(** Loops until the enclosing switch is cancelled. Store errors and probe
    failures are logged and retried on the next sweep; only
    [Eio.Cancel.Cancelled] escapes. *)
