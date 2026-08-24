val current : string
(** Build version projected from the linked dune-build-info metadata, or
    ["dev"] for an unversioned build. Anything reporting a version outward
    reads it here; a literal elsewhere drifts from `dune-project` silently. *)
