# Native Page code, app-state wait and browser fetch

The production workflow JavaScript was executed by installed Ego against two
owned local HTTP fixtures in continuing Space **27**, Page `p1`. Space 24 was
missing; the user explicitly approved creating this replacement. Existing MASC
and operator Spaces were not adopted. The continuing Goal's Space remains open.

`proof.json` contains the exact requests, results, fixture observations and
production JavaScript SHA-256
`b5dd9c020aebf641bfd453e716fd4ff0998470c95e084d2b563e9649f9d7351f`.
`page-sdk.png` shows the controlled fixture text; it has no private website data.

The successful five-step workflow verified:

1. Page callback with JSON data, Korean/emoji/quote content and no Node `process`.
2. Native app-state polling with explicit SDK timeout/polling values.
3. Native browser fetch: one POST, exact body/header, status 201.
4. Application state returned as data; a result's `dialog` field is not mistaken
   for a native JavaScript dialog.
5. JSON `__proto__` remains an own data property with an ordinary object
   prototype. Argument JSON cannot become executable expression syntax.

The CORS fixture received exactly one GET while the browser refused its response.
The failed workflow retained possible effects and did not execute its next step.
A predicate timeout likewise retained possible effects and skipped its next step.
Neither was retried.

Executed checks:

- `node --test test/test_browser_ego_workflow.cjs`: 14 cases passed.
- `bash scripts/check-browser-native-workflow-codec.sh`: actual codecs/interfaces,
  5 cases passed with warnings as errors; only library-name aliases are supplied.
- `node scripts/probe-browser-ego-page-code.mjs <ego-browser> <output> 27`:
  production workflow JS on real installed Ego, owned local fixtures.
- `bash scripts/check-browser-native-workflow-codec.sh --page-proof <proof.json>`:
  the actual OCaml decoder binds success, CORS failure and predicate timeout to
  their exact requests and preserves progress/effect flags.
- Tool TOML parsed; all 19 method enum entries and the nested fetch option schema
  were inspected. SDK inventory contains each of the 74 installed-help entries
  exactly once. These inventory checks are documentation evidence, not feature
  or full-SDK acceptance tests.

The native SDK rejects even an explicit `undefined` second argument for a string
`page.evaluate` expression. The bridge therefore sends one Page expression;
function arguments are parsed as JSON inside the browser. It never evaluates
caller source in Node or the host.

Limits: no full OCaml host/TUI build, installed candidate, actual Keeper tool
dispatch or MASC UI verification. Fetch `saveAs` still needs download-broker
integration. Native evaluation safety-timeout metadata beyond the message is not
yet retained. Other SDK, Space, selection, recovery and native Ego read-visibility
gaps remain in [the complete inventory](../../guides/ego-sdk-coverage.md). This
evidence does not complete `goal-ego-native-full-20261026`.
