### Internal

- The stop flag of an authorization JSONL file (`Authz_jsonl_file.Make`) is an
  `Atomic.t`, like the `current` and `probe` of the zone that
  `Authz_zone.read` reads beside it outside the zone. Every read of the flag
  already ran on the domain of the zone, so nothing raced and no behavior
  changes; a read made on another domain now gets a whole value (#51170,
  #PENDING).
