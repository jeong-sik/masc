# Web Browser verified-commit notification integration

Original #41191 head: `5f8c3c6b5cd0cdfa4d1896b073d9e377f009c0ad`.
Actual published parent #41187: `db39b4637939cfe1172590db485426b788e2417a`.
Tested source tree before this evidence addition: `52176ed3631ace5da733e4d27f2d40d5b4705abe`.
The real parent merge was clean. The original Browser source, authority/CAS
checks, and draft ownership are retained. This response adds the parent's shared
`announceRuntimeTomlCommitted(authority)` after the owned receipt has passed
path, submitted-text and source-revision checks and after `announceRuntimeTomlWritten`.
It runs before awaited consumer refresh. It does not resume model setup.

Three new component regressions mount actual Settings and an actual Browser
activity panel, submit through the real Browser session, hold the typed save
receipt, and hold follow-up refresh. They cover a mounted producer, an unmounted
producer, and an unmounted producer whose follow-up refresh fails. They assert
that Settings sees the changed resolved model before follow-up finishes, retains
the verified receipt, uses the original CAS basis, saves once, and does not
resume models. Original authority/ABA/uncertain/CAS/independent-draft tests remain.

The initial regression run failed all three cases before notification: the receipt
arrived but Settings retained its old reading (`red-tests.log`). After that run,
the unused resume transport spy was explicitly stubbed to prevent an unintended
network request if a future regression calls it; the assertion still requires
zero resume calls. No assertion was removed to obtain GREEN.

Final execution: **224 tests in six focused suites PASS**, TypeScript PASS,
scoped ESLint PASS. Commands and final source/artifact hashes are in checks.json.
This is actual component/session code with mocked HTTP boundaries, not a real
server save or Browser execution. No native source/build files differ from the
published parent; no native build was needed or run. No browser rerun, full suite,
CI, live configuration change, push, or deployment was performed. Historical
browser screenshots/fixtures under dashboard/evidence/2026-10-05-web-browser-activity
remain original-author evidence and do not attest this integrated source tree.

The separately advanced #41194 Settings implementation is not part of this
response. Its parent integration must preserve this shared commit notification.
