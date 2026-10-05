# Merge preflight review response — 2026-10-04

Native stack #41118 still contains ten PRs targeting main: #41104, #41106,
#41107, #41108, #41109, #41110, #41113, #41115, #41116, and #41117.
The user authorized merging this stack. Merge admission still requires current
independent GitHub approval for every included PR; source checks do not replace it.

This response addresses 15 further inline findings (one P1, fourteen P2) that
arrived during merge preflight, after the previous response. The integrated
source checked before this evidence-only commit is
`7e1f669b92cafbe5480a73cdad6d4cface87926b`.

| PR | Corrected behavior |
| --- | --- |
| #41106 | Copy preserves unchanged Ollama `num-ctx`; temperature uses a round-trip-safe representation; workspace withdrawal clears model rows, and edit/copy require the current readable source and projection. |
| #41107 | Disabled providers remain disabled. A validated new account can use the old connection as a client template without enabling it. HTTP request paths survive generated connection IDs, including Responses codec selection. Terminal setup resolves against parsed providers under the revision lock, retaining an explicitly selected existing connection and recognizing effective default native account homes. |
| #41108 | Saved activation recovery reconciles receipt runtime IDs to their configured account owner. Failed activation keeps its receipt when `n` or `e` is pressed; retry does not repeat login. |
| #41113 | Malformed and schema-invalid decision rows produce explicit incomplete/unavailable history rather than a successful empty reading. |
| #41116 | Runtime rows retain the stable Usage account identity decoded from the same response, independently of ordinal quota scopes or later catalogue refreshes. Enter details always include Account and Connection/provider ID. |
| #41117 | Runtime choices show exact connection IDs. Replacing an account clears choices across all group members. Group labels show reported email or operator labels with an explicit unknown-email state. Removal preview, progress and receipt describe the selected provider connection. |

The earlier #41110 follow-up also moved the catalogue-read-scope scenario out of
the default keyboard walk into its focused test entry and runtest registration.
Rebase resolutions preserve the model jump guard, workspace withdrawal, saved
activation IDs, stable account label helper, and both sets of test registrations.

## Verification and limits

On the integrated source SHA above:

- Six dashboard suites: **100 passed**; TypeScript `tsc --noEmit`: passed.
- Installer suite: **100 passed, 28 skipped** (128 total); the skips require a
  native test binary. They are not successful native checks.
- OCaml syntax: **57 implementations and 26 interfaces** parsed; Python syntax:
  **13 files** parsed. `git diff --check main...HEAD`: passed.

Focused native executions before integration checked 17 model-copy/source-authority
assertions, two saved-activation recovery scenarios, four history presentation
cases, and 20 setup identity/request-path assertions. The setup harness uses the
complete production setup-spec implementation and interface, actual adapter/home
normalization excerpts, and real JSON/URI/hash/TOML libraries; infrastructure
schema/registry types are stubbed. These results do not establish integrated
HTTP dispatch, the complete decision-log producer, or whole-program type safety.

The focused changes received independent agent source review. Integration readers
checked the preserved interfaces and conflict resolutions; authors also checked
their own integrated changes. Agent source review is not a guarded GitHub approval.

The shared prebuilt native dependency cache is absent. No local Dune/full build
was run. Newly authored native/HTTP and PTY regressions were not executed against
a rebuilt server/TUI. Browser E2E was not run. The live server, configuration,
and TUI binary were not deployed or restarted during this merge response.

The earlier minimal manual Actions run 37183489014 succeeded on the older
`74654854dab3c08543d208c2837bc85f01b9e1ce`; it does not certify this source.
Any new manual check result must be read from its actual run and SHA.
