### Fixed

- The Keeper trust snapshot names each runtime blocker by its own class.
  `heartbeat_failures`, `turn_failures`, `provider_runtime_error`,
  `official_client_recovery_required`, `turn_configuration_error`,
  `exception` and `operator_interrupt` used to all show as
  `unknown_runtime_blocker` in `disposition_reason` (and in
  `attention_reason` when the status bridge gave none), so an operator
  could not tell which blocker it was. The `unknown_runtime_blocker` value
  is no longer written, and the dashboard labels these reasons with the
  blocker class labels (#43018) (#PENDING).
