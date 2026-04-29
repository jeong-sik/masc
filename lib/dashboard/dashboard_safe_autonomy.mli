(** Dashboard_safe_autonomy — operator safe-autonomy
    dashboard surface.

    Single-entry boundary.  External callers (the
    dashboard HTTP route + the safe-autonomy regression
    test) reach exactly {!json}; everything else stays
    private.

    Internal helpers stay private at this boundary
    (~55 internal lets + types — per-keeper risk
    classifiers, mutation-budget aggregators, gate
    evaluators, evidence-coverage projectors, severity
    ranking helpers, every JSON sub-renderer
    consumed only inside {!json}). *)

val json : config:Coord.config -> unit -> Yojson.Safe.t
(** Renders the safe-autonomy dashboard envelope:
    per-keeper risk + gate + mutation-budget projection
    folded over [Keeper_types.keeper_names config], plus
    the rolled-up evidence-coverage summary. *)
