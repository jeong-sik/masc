### Internal

- The dashboard's Korean labels for a receipt's `operator_disposition_reason`
  are keyed by a closed list of the reasons the server writes
  (`OPERATOR_DISPOSITION_REASONS` in `fsm-hub-types.ts`), so a missing or
  extra label fails tsc. A new fixture,
  `dashboard/src/api/fixtures/receipt-operator-disposition-reasons.json`, is
  checked against that list by vitest and against every
  `Keeper_execution_receipt.operator_disposition_reason` by
  `test_keeper_trust_disposition_reason`. The labels and the fallback for an
  unknown reason do not change (#43117, #PENDING).
