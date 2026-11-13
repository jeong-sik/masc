### Fixed

- `masc_run_init` and the run that `masc_run_get` creates for a task without
  one now take the same `run.json` lock as `masc_run_plan`. A second init that
  ran beside a plan update could be undone by that update while still
  reporting success, and a get could replace a run another caller had just
  created and planned (#44757).
