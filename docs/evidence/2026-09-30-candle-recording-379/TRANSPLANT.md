# Canonical-parent transplant

The adjacent artifacts cover the historical probe-based head only. They are preserved unchanged and are not current-head evidence. The repaired PR is based on #40004 and requires new PR-check and targeted-test runs.

The feature scenarios retain unpublished and publication-busy Snapshot/PayoutOwed recording, resumed payout, confirmation retries, reopen/drop, and worker restart/replay. The test uses canonical Candle event variants and injects only appraiser model decisions.
