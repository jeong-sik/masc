# Native account selection retained through execution

Issue: [#27898](https://github.com/jeong-sik/masc/issues/27898).
This unit follows explicit JSON/TOML provider admission. The original startup,
real-account execution and whole-product acceptance requirements remain open.

Native execution records previously retained an optional declaration. A missing
declaration was resolved for quota scope during materialization, then resolved
again for the child process, verification and continuation fingerprints. Changing
HOME, the client's configuration-directory variable or credentials between these
operations could dispatch a different context under the original quota scope.

The [executed regression-only baseline](../evidence/2026-11-02-native-account-selection-baseline/README.md)
at `74740cfe683856b85ceb12bee2b572ebdeae5c4f` reproduces all six inherited-selection
failures. Its two explicit-directory isolation controls pass. This result is the
targeted Test workflow, not a real native vendor turn or full regression result.

`Runtime_official_account` now owns an opaque, client-typed selected context.
Its constructor observes the environment once, derives the home and selection
mode, validates the declaration and applies the existing client-specific
credential filter. Callers cannot certify arbitrary bytes or provenance as an
admitted context. It has no JSON or pretty-print projection and returns copied
environment arrays. Reload comparison is private and ignores environment-entry
order while retaining selected values and selection mode.

Materialized native execution records require the captured context. All execution,
probe and usage consumers pass it explicitly. The verifier's private Codex home
is a separate process store derived from the captured source. Its environment
reapplies explicit credential filtering without re-reading ambient credentials.
Claude retains its distinct inherited-HOME account-file behavior and its existing
relative-HOME admission difference from Codex. Setup/display boundaries use the
current selection and do not certify an executable context.

The first WIP audit found that reading only root Codex credential declarations
could disagree with the verifier's legacy inline-profile flattening. Current
official documentation, fetched on 2026-11-02, establishes that Codex 0.134.0 and
later use separate profile files selected by `--profile` and have retired both
inline profile tables and the root profile selector. The installed CLI reports
0.166.0. MASC's bridge does not select that flag. The repair removes legacy
flattening and rejects those retired fields, so they cannot select one connection
for verification and another for execution. It preserves root `env_key` and
`env_http_headers` declarations, whose meaning is confirmed by the
[official reference](https://learn.chatgpt.com/docs/config-file/config-reference).
See also [official profile configuration](https://learn.chatgpt.com/docs/config-file/config-advanced#profiles).
No provider call, login or native session was made to obtain these observations.

The candidate suite has 27 registered source cases. Besides the original eight
scenarios, it covers environment-copy protection, direct-call timing, captured
Claude credential diagnosis, Codex private-store filtering and declared custom
credential values, retired-profile rejection, conflicting direct homes, missing
or empty HOME rejection, relative paths, reload identity and sealed carrier
admission. The first complete source review also found a tuple/Result mismatch
in the Claude auth probe and an empty-HOME Codex fallback; both are corrected
before requesting another full review. The original scenarios now
use the typed API, and additional cases change the fixture source. A later
candidate result must not be presented as an identical-fixture before/after pair.

Local checks are source parsing, dependency inspection and whitespace checks.
They do not establish typechecking or executed behavior. Independent source
review and any candidate Test result must name the immutable candidate head.
The context freezes selection and environment values, not changing credential
files, keychains, external helper output or the actual vendor account subject.
No issue is closed by this unit. The maintained behavior guide is
[Native account selection](../guides/native-account-selection.md).
