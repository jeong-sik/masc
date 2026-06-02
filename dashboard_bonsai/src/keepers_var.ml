(** Module-level Bonsai.Expert.Var holding the current keepers response.

    Written externally by [Keepers_fetch.run]; read reactively by the four
    views that depend on it (focus card, roster, swimlane, ctx pressure
    chart). Using an [Expert.Var] for the same reason as [Logs_var] — it is
    the documented escape hatch for driving incremental computation from a
    [Fut]-based async source. *)

let var : Keepers_types.response Bonsai.Expert.Var.t =
  Bonsai.Expert.Var.create Keepers_types.fixture
;;
