# Selected runtime provider probe

Bounded repair [#47127](https://github.com/jeong-sik/masc/pull/47127) for
[#27898](https://github.com/jeong-sik/masc/issues/27898), against
`71eab08bb9a8040371fd9927a7f9d211fbc813d3`.

The public dashboard probe accepts retained `Runtime_instance` values, but its
private header builder reread their Env/File declarations. It could observe a
different credential, report missing authentication after deleting a file that
the retained runtime had already loaded, or send a request despite the
runtime's captured requirement being unavailable. It also reconstructed the
auth scheme and non-auth headers instead of using the selected execution.

The probe now uses `Runtime_instance.validate_dispatch_credential` and the
selected `Provider_config` auth scheme/key/headers. Its separate Env/File
loader and declaration-header reconstruction are deleted. Missing required
credentials, including an undeclared required key, are refused before GET.
`credential_required` projects captured HTTP admission; keyless/Unknown
runtime behavior is preserved. `auth_kind` remains the declared reference
label, while `auth_present` observes the selected request headers.

Fresh credential selection stays in materialization/discovery. Native Vertex
auth and official-client skips, endpoint selection, provider grouping and
background-cache behavior retain their existing boundaries.

## Executions

All runs use ref `fix/dashboard-selected-credential-probe-20261101` and the
explicitly selected suites recorded in `manifest.json`.

| Test execution | Exact head | Result |
|---|---|---|
| [Baseline 41277170061](https://github.com/jeong-sik/masc/actions/runs/41277170061) | `b8ace335c2a3d6975598cdbe110a7f4d940cf8b8` | FAILURE: actual82 PASS/7 FAIL in provider/auth89 |
| [Candidate 41277380572](https://github.com/jeong-sik/masc/actions/runs/41277380572) | `79a67ae11076e2dc7c493f3b77b565c9a0d2f3ec` | SUCCESS: actual151 PASS/0 FAIL, provider/auth89 plus dashboard-cache62 |
| [Nonblocking 41277488215](https://github.com/jeong-sik/masc/actions/runs/41277488215) | `79a67ae11076e2dc7c493f3b77b565c9a0d2f3ec` | SUCCESS: actual9 PASS/0 FAIL, direct probe/cache/switch consumer |

Baseline production is identical to the parent. Its seven intended negative
cases fail: changed Env sends a different key; cleared Env, selected fallback
alias and removed File suppress the expected GET; missing required credentials
and missing selection authority still perform GET; a selected static Bearer
scheme is replaced by the codec's default auth header. The two new keyless and
Unknown controls and the prior80 cases pass.

The scheme/header case stops at its first scheme assertion in baseline, so
baseline does not establish that its later non-auth header assertions were
reached. Later alias-label and required-field assertions also follow their
earlier failing assertions. Candidate reaches all assertions, including the
selected non-auth header, omitted declaration header, declared alias label and
required/present controls. Secret headers are compared through boolean
assertions and are not serialized into failure output.

The entire provider/auth test file is byte-identical between baseline and
candidate; size and digest are recorded. Source manifests record17 inputs and
four source-tree identities at the executed candidate. They are not exhaustive
build dependency manifests. `manifest.json` keeps each execution's exact
head/ref/status and separate raw/selected digests. Raw logs are retained under
ignored `artifacts/issues-oldest-20261101/dashboard-selected-probe/`.

The cache62 suite is an additional cache check. The separately selected
nonblocking9 suite directly exercises public probe fan-out under a server
switch, preserves row order, propagates callback failure without failing the
root switch, and retains background-cache behavior. These are controlled
fixture/callback tests; counts from separate runs are not added or presented
as a full regression run.

## Review and remaining scope

Independent adversarial and response SOURCE PASS found no P0–P2 at
`79a67ae11076e2dc7c493f3b77b565c9a0d2f3ec`, canonical complete diff
`4256cf01e3f00df3917cef6d7e19ae046161b163e9503fa43daa0ee2ae94b719`.
This does not certify a future evidence head or establish formal non-author
GitHub approval.

One representative per provider is still probed and projected onto that
provider's model rows. This establishes representative reachability; mixed
old/fresh selected accounts under the same provider ID are not independently
validated. Endpoint overrides, official-client reasoning and a single atomic
catalog-construction transaction remain outside this repair. Whole-stack
integration, installed runtime, real upstream provider traffic, deployment and
full issue acceptance remain separate. The issue stays open.
