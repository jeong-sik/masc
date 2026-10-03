# Runtime provider field validation

The native baseline accepted `model_set` and `model-sets` while silently omitting a model that the intended shared set would have added. The repaired production `Runtime_toml` parser rejects both at their exact provider paths. The correctly spelled `model-set` still combines shared models with explicit bindings. The repository runtime document's nine provider tables still parse.

The parser implementation and interface were compiled with OCaml 5.5.1 in isolated temporary directories and linked with cached dependencies. The exact probe, output and source/binary hashes are retained here. This checks parsing, not provider activation or a full candidate build.

`test_runtime_toml_namespace` adds the explicit-binding typo regression. `test_runtime_account_declaration` now expects the same parser refusal for an unknown nested provider `notes` table, retaining its separate inline-layout refusal. Those full suites remain unrun. Independent source review checked the parser's consumed field set and found that test-contract update; it was corrected without accepting unknown metadata fields.
