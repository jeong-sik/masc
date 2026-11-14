### Fixed

- `masc-keeper-capability-probe`, `masc-lane-cli-probe`, `masc-fusion-run` and
  `masc runtime-probe` read runtime.toml against the catalog the operator
  names in `AGENT_CORE_MODEL_CATALOG`. They used to judge it against the
  embedded catalog, so a model row only the named catalog carries was refused
  at runtime init while the server admitted it (#49351, #PENDING).
- A standalone executable given an `AGENT_CORE_MODEL_CATALOG` file that does
  not load stops with an error that names the file, before it reads
  runtime.toml (#49351, #PENDING).

### Internal

- Catalog selection and the runtime.toml read of every standalone executable
  go through `Runtime_model_catalog_boot`; the selection moved there from
  `Server_runtime_bootstrap` so executables that do not link the server reach
  it (#49351, #PENDING).
