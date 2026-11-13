### Fixed

- `deployment_preflight_helper.exe validate-stores` reads each Keeper's tool
  outbox (`<base-path>/.masc/keepers/<keeper>/official-client-runtime/undelivered-tools/`)
  and prints `keeper tool outbox receipts rows=<n> refused=<n>`. A receipt
  this build cannot read stops the install and the first one is named with
  its path and cause, for example `invalid tool outbox arguments` for a
  receipt written before #51429. The check did not read this store, so such
  an install passed and every request of that Keeper failed after the start.
  It reads each file with the read `Keeper_client_tool_outbox.load` applies
  (new `Keeper_client_tool_outbox.inspect_committed`, new
  `Keeper_durable_store.Id.Keeper_tool_outbox`), takes no producer lease, and
  changes or removes no file (#51587) (#PENDING).
