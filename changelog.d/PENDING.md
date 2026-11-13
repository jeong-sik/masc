### Internal

- `scripts/harness/workload/keeper_multi_collaboration_acceptance.py` passes
  `pyright` and `ruff format --check`. `pyrightconfig.json` resolves
  `scripts/lib` for everything under `scripts/`, the way those scripts extend
  `sys.path` when they run, which also clears the unresolved-import error in
  fifteen other scripts. No harness behavior changes (#47072, #PENDING).
