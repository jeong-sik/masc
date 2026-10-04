# Runtime provider field validation

The native baseline accepted `model_set` and `model-sets` while silently omitting a model that the intended shared set would have added. The repaired production `Runtime_toml` parser rejects both at their exact provider paths. The correctly spelled `model-set` still combines shared models with explicit bindings. The repository runtime document's nine provider tables still parse.

The parser implementation and interface were compiled with OCaml 5.5.1 in isolated temporary directories and linked with cached dependencies. The exact probe, output and source/binary hashes are retained here. This checks parsing, not provider activation or a full candidate build.

`test_runtime_toml_namespace` adds the explicit-binding typo regression. `test_runtime_account_declaration` now expects the same parser refusal for an unknown nested provider `notes` table, retaining its separate inline-layout refusal. Those full suites remain unrun. Independent source review checked the parser's consumed field set and found that test-contract update; it was corrected without accepting unknown metadata fields.

## Parent review response propagation

The provider repair is now based on K1 review-response commit
`4b87f3d73ca7212ad0d883a20467bf7b56cef962`. The provider parser and its tests are
unchanged. The native parser probe was rerun with the four newly compiled
configuration modules from that parent, plus this actual Runtime_toml module.
Both typo paths are rejected, valid model-set generates two bindings, and all
nine shipped provider tables are accepted. restacked-candidate.txt and
restacked-sources.json record this combined focused scope. No provider startup
or complete suite execution is implied.

## Current main integration

Historical parser receipts above remain pinned to their original candidates.
Integration against main `6fc062feee7e33a271e09dc155d9feffee923704` exposed a new
consumed provider field, `request-path`, missing from the strict allowed-key
contract. The direct valid-path regression failed before repair with
`providers.first.request-path: unknown key`. The allowed-key list now includes
that field; its original typed HTTP-path decoder remains unchanged, and the
`request_path` typo is still rejected at its exact provider path.

Local focused OCaml 5.5.1 build passed. Namespace 13/13, account declaration
13/13 and runtime validity 144/144 tests passed (170 total). Account declaration
used its declared `MASC_TEST_RUNTIME_SEED=config/runtime.toml` fixture; an initial
manual invocation omitted that variable and failed the seed prerequisite, then
the correctly configured run passed. These results do not prove provider
activation, installed runtime, deployment or full regression qualification.
