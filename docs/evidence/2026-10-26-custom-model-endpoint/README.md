# Explicit custom model endpoints — #27898

## Contract and production change

The high-level contract uses provider:model or custom:model@url. Before this repair, omitting @url silently selected CUSTOM_LLM_BASE_URL or the local discovery default. The same label therefore named a different destination according to process state. This is a remaining ambient endpoint inference in the original issue, independent of the provider-identity correction in parent #45980.

Custom selection now returns a closed typed Result with Missing_endpoint, Empty_model or Invalid_endpoint. The model and an absolute HTTP(S) URL are required; the endpoint is never supplied by environment/discovery. Provider_kind_resolver classifies the parsed custom model/URL and Runtime_model_string builds the config from that same result. The duplicate custom parse and obsolete private split helper are removed. Registered-provider selection, auto/default model selection and request policy freezing remain separate.

Uri's compatibility parser is intentionally forgiving: its of_string uses prefix consumption, its public grammar accepts arbitrary path octets, and numeric port conversion can silently overflow to None. The repair uses full Angstrom parsing, a URI character/percent-escape envelope, and a narrow lossless authority/port check. Parsing the isolated raw authority must yield an empty path and the same host/userinfo/port as the full URL; suffixes cannot be reinterpreted as paths. Explicit ports survive conversion and use the TCP destination range1–65535. Valid leading zeros, IPv6 and userinfo are not rejected by whole-URL textual equality. The URL's path/query bytes remain in the config.

Angstrom is declared directly in runtime-model Dune and root package metadata; it was already pinned0.16.1 in masc.opam.locked through existing dependencies. URI4.4 public Parser and installed source were read directly. No regex or provider-name policy inference is added.

## Public scenarios and execution history

All runs select only test/test_runtime_model_label_binding. Three parent cases retain provider identity/context/tool policy and final serialized required-tool behavior. New cases cover missing endpoint with and without an ambient variable, invalid model/HTTP endpoint, malformed syntax, port authority, authority suffixes, and explicit model/URL through the final Common HTTP serializer. They use temporary fixture environment values and restore prior values without logging them. No provider request is sent.

- Baseline3894446330521bf73b90468c0894da4afc918ecb, run40203916694:7 actual cases,4 PASS/3 FAIL (missing, ambient, invalid). The invalid case stopped at empty endpoint; later invalid shapes and the kind-resolver assertion in the failed ambient case were unreached.
- Intermediate5a09c49d5db555cd4a1784fd2695425bb3f1c521, run40203991264:7 PASS. Review found missing malformed authority/port coverage; this result does not certify final strictness.
- Strengthenedaf2f83980fbd56c3c18d4393e259859c2d48241f, run40204275389:8 actual,7 PASS/1 FAIL at malformed endpoint. Later shapes in that case were unreached.
- c15c31e78ba0d7f6a23b5a4afdb7a82733d6e9d3, run40204438569:8 actual,7 PASS/1 FAIL. Full Angstrom consumption alone did not make Uri's internal compatibility grammar strict.
- d4c032e9db854ff515a78940717f7135c8c9142a, run40204597697:9 actual,7 PASS/2 FAIL (malformed and ports). The port case stopped at numeric overflow; later range/positive controls were unreached there.
- f5bdfdad22ea439021d941a6257df24cf969993c, run40204639333:9 actual,8 PASS/1 FAIL (malformed path/escape). Port negative and positive controls reached.
- 3a16b0a868c4daf412546846da901bcc0fef878b, run40204778406:9 PASS. Adversarial follow-up found malformed authority suffixes that Uri could absorb as paths; this is an intermediate result.
- Regression-only156bfb74980ffafdaa2b02a78d4b2e4d861763f9 adds that tenth case; run40205068137 was confirmed in progress at the latest boundary. Corrected source5a267962cfc33270e378c7f19e0eaf25e7dc7f29 requests run40205095471; its outcome was not yet observed. Actual final results will be recorded separately.

Retained selected checkout/assertion/summary lines and raw SHA/size distinguish every result. Current-source syntax and whitespace pass; those do not establish execution. Ten source/fixture/dependency-file hashes are retained. No local Dune/typecheck/full build, full regression, installed runtime, provider HTTP, deployment or whole-issue completion claim.

PR #45987 is a child of #45980. gh stack init adopted the child with its parent branch as base; submit reported native stacks disabled and REST stack:null was observed. Neither source reviews nor these selected cases approve the full parent chain or establish merge. #27898 remains OPEN for the original catalog/manifest/binding consolidation and other high-level auto/default selection requirements.

## Actual final authority repair

[Regression-only run40205068137](https://github.com/jeong-sik/masc/actions/runs/40205068137) actually ran10 cases at156bfb74980ffafdaa2b02a78d4b2e4d861763f9:9 PASS/1 FAIL. The new authority case failed on the multiple-@ endpoint before its later bracket suffix assertions. It did not certify those unreached negative controls.

[Final run40205095471](https://github.com/jeong-sik/masc/actions/runs/40205095471) checked out exactly5a267962cfc33270e378c7f19e0eaf25e7dc7f29 and completed SUCCESS with **10 actual cases**:3 parent provider-authority cases plus7 custom endpoint cases. All malformed/port/authority controls, valid IPv6/userinfo/leading-zero/path/query cases, ambient-variable independence and final explicit-model serialization assertions were reached. The current evidence-only head preserves all10 source/fixture/dependency hashes. Intermediate7/9 passes and failed8/9/10-case runs are not added to10 or relabeled as final success.
