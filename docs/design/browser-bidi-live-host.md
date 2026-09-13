# Attached Firefox BiDi peer

`masc-browser-host --bidi-url ws://127.0.0.1:9222/session` opts into a
Firefox Remote Agent that the operator explicitly enabled. Without this option
the executable continues using WebExtension native messaging stdin/stdout.
The endpoint must be loopback; MASC does not start Firefox, copy a profile,
change preferences, or obtain application tokens.

The BiDi connection owns its opaque context to integer tab mapping. IDs are not
recycled during the client lifetime and are never joined to extension IDs or
URLs. Tab visibility and Firefox version are observed, not inferred from index.
Unsupported verbs fail explicitly. Fixed repository scripts provide DOM reads,
scenes, document references, and semantic interactions; command arguments are
JSON data, never supplied JavaScript.

Screenshot coordinate input uses the existing document/viewport guard followed
by BiDi pointer or wheel actions. This is not an atomic snapshot/input
transaction: the operator can still change the page after validation. There is
no write replay. An unknown outcome stops this live client. Reads and interactions
share the existing host command deadline; connection setup has that same bound.
Protected pointer-release cleanup can additionally run up to one transport
deadline after the outer command deadline. A timeout is not an instantaneous
release guarantee.
Closing the socket does not issue browser.close or browsingContext.close.

This initial peer rejects includeHtml (the source-document helper has no caller
cap), and does not implement page.elements, live activate_tab, uploads,
download collection, or the extension's navigation commit barrier. A successful
follow receipt does not guarantee application content is ready; existing guarded
read recovery remains necessary. A BiDi session enables browser-wide automation
and must not be exposed beyond loopback.

Validation: `test_browser_bidi_peer` exercises opaque identity and closed verbs.
`python3 test/test_browser_bidi_host.py HOST FIREFOX` uses an owned temporary
profile and actual Firefox to exercise native HTTP poll/result, screenshot,
trusted drag, stale viewport rejection, and two identical-URL contexts.
The latter requires the CI-built host and Firefox; no local build is needed.

Protocol references: [Mozilla direct connection](https://developer.mozilla.org/en-US/docs/Web/WebDriver/How_to/Create_BiDi_connection),
[BiDi input](https://developer.mozilla.org/en-US/docs/Web/WebDriver/Reference/BiDi/Modules/input/performActions),
[Remote Agent security](https://firefox-source-docs.mozilla.org/remote/Security.html).
