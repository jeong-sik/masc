# Antigravity keychain prompts

Observed on 2026-09-30, before this fix, from the running MASC server and
existing macOS security logs. No credential contents were printed, and no
operator keychain, credential, configuration or runtime process was changed.

- Runtime binary: `c112b2030652a5a25360f5d5322f8dc6da99c598`.
- Runtime root confirmed by `/health?full=1`: the operator's `me/.masc`.
- macOS security log window: 17:15–18:15 KST.
- 15 ACL-bearing `displaying keychain prompt for .../masc(62751)` records
  name the `gemini` item and `/usr/bin/security` as the trusted application.
  Another 15 summary rows duplicate those occurrences; they are not 30 dialogs.
- The active `gayo-yoga-leader`, `glossary-maniac` and `msx-retro-mania`
  generation pointers, keychains and mode-0600 credential files exist.
  Their CLI logs record authentication success at 18:02:34, 18:05:20 and
  18:10:14 KST respectively.

The managed-generation admission path calls `check_managed_keychain`, then
`Apple_keychain.read`, then `SecItemCopyMatching`. The native reader sets
`kSecUseAuthenticationUIFail`, but the observed file-keychain ACL still raises
confirmation UI. The relevant source files match the running binary's commit.

The fix disables file-keychain interaction around the native operation and
restores the prior setting. The setting is process-global, so read and clear
share one native mutex, acquired after releasing the OCaml runtime lock.
Failure to disable interaction prevents the query. Locked/ACL-protected reads
keep the existing `Unavailable` result; principal comparison remains intact.

The `Apple keychain` workflow builds the actual OCaml/C library and exercises
disposable macOS keychains: allowed, ACL-denied, missing, locked, clear,
previously-disabled interaction and concurrent domains. It also inspects
securityd logs for prompts attributed to the test process. Production prompt
absence still requires deployment and a subsequent observation window; the
source change alone is not that evidence. Because headless runners can already
refuse prompts, a second, instrumented copy of the production C stub checks
that interaction is disabled at the actual Security read/delete boundary and
then calls the real APIs. The uninstrumented fixture coverage is retained.

API references:

- [Apple Security source: interaction setting](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_keychain/lib/SecKeychain.cpp)
- [Apple keychain access control lists](https://developer.apple.com/documentation/security/access-control-lists)
