# Installed Dashboard digest scheduling

Observed serving source: `533296db987ad10a6e7b3be990788378e07d7462`.
Candidate base: `0920933e057f231f71a221e1823e266fc96eb1f4`.

The installed macOS bundle receipt is 1,363,674 bytes. A Dashboard asset load
checks its binding before and after reading the asset. Each binding check reads
and hashes the receipt. Health reads index.html and .build-stamp, so those reads
alone hash 5,454,696 receipt bytes per health response. File reads already use
Fs_compat's system thread boundary; the following Digestif computation was inline
on the HTTP fiber.

A five-second macOS sample beginning 2026-10-21T02:10:45.647+09:00 recorded
2,966 main-thread observations, including 2,018 below Digestif SHA-256 update.
Some resolved branches include health, Installed_dashboard and check_digest;
the largest branch has truncated callers. These counts are neither individual
hash durations nor proof that all SHA work belongs to this module. The sample
also overlaps startup maintenance and concurrent clients.

This change submits immutable digest inputs to the existing CPU pool. Receipt
reads, digest comparisons, asset validation, root/binary identity checks and
their ordering remain. Startup before the pool, raw non-Eio callers and calls
already on a worker retain the shared pool's inline policy. No digest cache or
additional pool is introduced. Hashing work is moved, not eliminated; pool
contention can still delay a caller.

The existing integrity cases remain, with additional real-pool coverage for
receipt/asset damage, symlinks, pointer changes, a single worker and a raw domain.
Changed ML files passed syntax parsing and the diff passed whitespace checks.
Native linkage/test execution and installed candidate performance remain pending.
