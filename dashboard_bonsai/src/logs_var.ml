(** Module-level Bonsai.Expert.Var holding the current logs response.

    The Var is an external mutation point: [Logs_fetch.run ()] writes to it
    from outside Bonsai's effect graph, and [Logs_view.component] reads it
    reactively through [Bonsai.Expert.Var.value]. Using an Expert.Var is
    documented as the escape hatch for wiring non-Bonsai asynchronous
    sources (here: brr's [Fut]-based Fetch API) into the incremental
    computation.

    Initial value is [Logs_types.fixture]; it is replaced on the first
    successful fetch. *)

let var : Logs_types.response Bonsai.Expert.Var.t =
  Bonsai.Expert.Var.create Logs_types.fixture
;;
