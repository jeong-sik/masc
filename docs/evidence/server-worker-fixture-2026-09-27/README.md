# Execution worker fixture smoke

One local macOS plumbing run used the installed-file snapshot whose embedded
source declaration is `97ed4b9f508727944bdec361dd4d3e271d1a510a` and server SHA-256
is `732abb40ac65f8df793481bcf92260dd48fb1e0ebad1f1edef155946110df5fb`.
Artifact and run IDs are null. This is not the live server image, the task-index
candidate, Linux execution, a before/after comparison or 0.1 ms proof.

The fixture seeded 25 ordinary active-agent records, 816 multilingual Todo
tasks, and requested gzip for two cycles per phase. The independent validator
accepted all 54 HTTP receipts, including ten timed requests and all 25 workers
in the prime and two cold projections. Every original warm body equals its
cold body. Worker records remain unchanged; their zero ownership counts and
quiet attention rows are checked against the all-Todo workload. The two final
backlog copies contain 820 tasks at revision 46 from initial revision 1 and
are byte-identical. Server exit was zero and reaped; the model stub stopped
after one discovery GET and no POST. No Keeper fibers were launched.

The full response receipts, synthetic inputs and final persisted records,
server log, projected health and cleanup remain here. `files.json` checks the
stored files; `redaction.json` records original and decoded public hashes.
Owned workspace, installed-snapshot and host paths are normalized. Original
body hashes and byte counts describe original private response text; separate
published hashes describe normalized text. Timings and wire sizes are original.
The validator ran against original receipts before publication. Only four
health groups are retained, as declared per file in the redaction record.

The 16 synthetic validator tests (17 subtests), Python syntax, workflow lint
and source whitespace checks passed. They validate evidence rejection paths;
this smoke establishes actual fixture plumbing only. The pending Linux
comparison has separate source/artifact identities and acceptance evidence.
