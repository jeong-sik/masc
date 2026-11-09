# Librarian catch-up audit metadata

`audit-summary.json` contains selected metadata from the read-only log, owner
journal and running worker investigation on 2026-11-09. It excludes request
bodies, prompts, credentials and private conversations. The report is
[Librarian catch-up audit](../../reports/2026-11-09-librarian-catch-up-audit.md).

The observed runtime commit, log window, counts and worker hash describe their
recorded capture times. They do not establish the latest runtime state or the
completion of an uncertain original request. Logs and owner files were not read
atomically. Raw working captures remain in the ignored paths named in the JSON.

`candidate_integration` describes the earlier v11 candidate at its `recorded_at`
time. `candidate_integration_after_50641` records the later source integration:
main already uses v11, so the required pending fields use v12. These are source
metadata, not installed-server, successful-build, Memory-commit or ACK evidence.
