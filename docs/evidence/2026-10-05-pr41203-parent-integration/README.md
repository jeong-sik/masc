# Web machine activity parent integration (before review response)

This is the initial 263-test integration record. The later known-refusal repair and final 264-test result are recorded in [review-response evidence](../2026-10-05-pr41203-known-refusal/README.md).

Published #41201 parent bfe316005dabbf71a45316ec1b64a70aa8db9931 merged cleanly into original #41203 a48463a674d43ac4658488eb44f234baa9399756. Every own dashboard/src file is byte-identical to the original reviewed feature. The parent brings current authority, raw-save rejection, inventory and compact-quit repairs; those changes are preserved.

On this combined source, 263 tests across five suites passed: machine parser, machine activity panel, lane inventory, Settings and raw TOML editor. Full dashboard TypeScript and scoped lint of the own machine/inventory changes passed. Commands and raw logs are pinned in checks.json; frozen-lockfile installation changed no tracked dependency file. No source repair was needed after the clean merge.

Root reviewed the original product/parser/session/UI and tests, verified its 18 source and 18 historical artifact hashes, then checked the integrated source and direct shared consumers. Original 134-test and synthetic Chromium screenshots/scenarios remain historical in dashboard/evidence/2026-10-05-web-machine-activity. Chromium was not rerun here. Parent native/PTY evidence belongs to the parent; this unit does not claim new native, backend/emulator, full CI, deployment, release or Terminal-Bench execution.
