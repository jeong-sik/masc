(** Measured write attribution: catalog URLs own codebase identity; Git owns
    the checkout root and origin. No directory name carries repository identity. *)

val resolve :
  base_dir:string -> file_path:string -> Agent_observation.file_attribution
(** Inspect the actual checkout afresh using one shared Git inspection budget.
    A remote origin must match a registered canonical URL. A local origin is
    resolved from the measured checkout root and must share Git identity with
    a registered local checkout, including its linked worktrees. Conflicting
    catalog identities and unavailable observations remain typed [Unaddressed]
    facts. The path is
    relative to the actual checkout; every measured checkout carries its root
    as projection metadata. Eio cancellation propagates. *)
