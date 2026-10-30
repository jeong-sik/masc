(** Pure HTTP projection of an exact-run registry's immutable startup observation.
    No filesystem, replay, payload read or cleanup is performed. This is not an
    online retention census, eligibility decision or compaction receipt. *)
val to_json : Exact_lane_run_registry.startup_observation -> Yojson.Safe.t
