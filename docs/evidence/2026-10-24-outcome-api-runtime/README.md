# Actual Task approval and outcome metrics

This isolated API experiment used server source
`7501aec032012869d8b979e0d14e1a9a9464ace7` on port 62470. Its server entry's
ZIP CRC, artifact manifest SHA-256 and embedded commit were verified. The
test reused the previously verified support bundle from `dca2013e`; the
upstream library and Python provenance matched. This is a server test, not
full new package installation or production deployment.

An external test actor created an independent Task, claimed and started it,
then ran the pinned Node image with network disabled, a read-only filesystem
and UID/GID 65534. The actual process returned exit 0 and `4\n` for `2+2`.
The actor submitted the result. The test operator read the immutable submitted
evidence through the authenticated evidence endpoint and issued a controlled
operator-proxy approval bound to the exact verification ID. This is not an
independent LLM verdict or a person's Goal confirmation.

The authoritative Task reread is `done`, with no Goal association. The
subsequent real `masc_agent_fitness` response reports
`task_lifecycle_success=1`, `outcome_basis="task_lifecycle"`, and
`external_acceptance={"kind":"unobserved","completed_tasks":1}`. Its
completion fact does not increment or confirm the separate Goal.

The immediate first fitness query returned null metrics. Task metric recording
is asynchronous: the retained file was written after that query. A later API
reread returns the stored metric above. The experiment does not establish the
earliest read visibility time or a persistence latency bound; it does establish
that the observation was persisted rather than lost. Receipts preserve both
queries. No retry of Task creation or approval was performed.

`manifest.json` binds the retained API and process receipts by hash. The native
metric plan/reader/provider follow-up run
[40082520098](https://github.com/jeong-sik/masc/actions/runs/40082520098)
passed all four selected suites at source
`b9bba3d4b416e269ff1d586f17f81e55c09ad8b3`. The earlier 29-suite run remains
26 pass and 3 fail at its own source. Neither run is full regression evidence.
Actual dashboard consumer rendering was subsequently captured in [the isolated browser experiment](../2026-10-24-outcome-dashboard-runtime/README.md); its real API, module-opened dialog and development-proxy scope are recorded separately.
